import { performance } from 'node:perf_hooks';
import { test, expect } from '../fixtures/test.js';
import { uploadFile, validTelemetry } from '../helpers/api.js';
import { largeCsv } from '../helpers/files.js';
import { isolatedCampaignId } from '../helpers/test-data.js';

test.describe('Measured ingestion and controlled concurrency @api @performance @regression', () => {
  test('uploads deterministic 10, 100, 1,000, 10,000 and 50,000 row datasets and records timings', async ({ api }) => {
    test.setTimeout(120_000);
    const measurements: Array<{ records: number; bytes: number; duration_ms: number; candidates: number }> = [];
    for (const records of [10, 100, 1_000, 10_000, 50_000]) {
      const content = largeCsv(records);
      const started = performance.now();
      const { response, body } = await uploadFile(api, `large-${records}.csv`, content);
      const duration = Number((performance.now() - started).toFixed(2));
      expect(response.status(), `${records}-row upload error: ${JSON.stringify(body)}`).toBe(200);
      expect(body.phone_candidates).toBe(records);
      measurements.push({ records, bytes: content.byteLength, duration_ms: duration, candidates: body.phone_candidates });
    }
    await test.info().attach('upload-performance.json', {
      body: Buffer.from(JSON.stringify(measurements, null, 2)),
      contentType: 'application/json',
    });
    console.log(`Upload measurements (no fixed timing SLO): ${JSON.stringify(measurements)}`);
    expect(measurements.every(result => result.duration_ms > 0)).toBe(true);
  });

  test('simultaneous uploads, refinements, scores and telemetry do not return uncontrolled server errors', async ({ api }) => {
    test.setTimeout(60_000);
    const uploadJobs = Array.from({ length: 3 }, (_, index) =>
      uploadFile(api, `concurrent-${index}.csv`, largeCsv(40)));
    const scoreJobs = [
      '+14155550132', '+12125550111', '+13105550123',
    ].map(phone => api.post('/api/v2/score', { data: { phone, reachable: true } }));
    const refineJobs = [
      '+1 (415) 555-0132', '212-555-0111', '1 310 555 0123',
    ].map(phone => api.post('/api/v2/refine', { data: { phone } }));
    const telemetryJobs = Array.from({ length: 3 }, (_, index) => api.post('/api/v2/telemetry', {
      data: validTelemetry({ campaign_id: isolatedCampaignId(), source_url: `https://vicidial.test/concurrency/${index}` }),
    }));

    const [uploads, scores, refinements, telemetry] = await Promise.all([
      Promise.all(uploadJobs), Promise.all(scoreJobs), Promise.all(refineJobs), Promise.all(telemetryJobs),
    ]);
    expect(uploads.every(item => item.response.status() === 200 && item.body.ok)).toBe(true);
    expect(scores.map(response => response.status())).toEqual([200, 200, 200]);
    expect(refinements.map(response => response.status())).toEqual([200, 200, 200]);
    expect(telemetry.map(response => response.status())).toEqual([200, 200, 200]);
    const persistedWarnings = await Promise.all(telemetry.map(async response => (await response.json()).persist_warning));
    expect(persistedWarnings).toEqual([undefined, undefined, undefined]);
  });

  test('a controlled parser failure is followed by a successful request (recovery smoke) @smoke', async ({ api }) => {
    const bad = await uploadFile(api, 'broken.json', '{not-json');
    expect(bad.response.status()).toBe(422);
    const recovered = await api.post('/api/v2/refine', { data: { phone: '+14155550132' } });
    expect(recovered.status()).toBe(200);
    expect(await recovered.json()).toMatchObject({ decision: 'PASS', normalized_phone: '+14155550132' });
  });
});
