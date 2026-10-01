import { test, expect } from '../fixtures/test.js';
import { getHealth } from '../helpers/api.js';
import { isolatedCampaignId, telemetry } from '../helpers/test-data.js';
import type { TelemetryResult } from '../helpers/types.js';

test.describe('Telemetry analysis and persistence @api @telemetry @regression', () => {
  test('healthy telemetry is accepted and returns the implemented analysis fields @smoke', async ({ api }) => {
    const payload = telemetry({ campaign_id: isolatedCampaignId() });
    const response = await api.post('/api/v2/telemetry', { data: payload });
    expect(response.status()).toBe(200);
    const body = await response.json() as TelemetryResult;
    expect(body).toMatchObject({ status: 'HEALTHY', efficiency_score: 100, utilization_percent: 40, alerts: [] });
    expect(typeof body.historical_drop_baseline).toBe('number');
    expect(typeof body.observed_at).toBe('number');
    expect(body).not.toHaveProperty('persist_warning');
  });

  test('drop anomaly, queue saturation and paused-agent ratio use actual thresholds', async ({ api }) => {
    const campaignId = isolatedCampaignId();
    const payload = telemetry({
      campaign_id: campaignId,
      agents_logged_in: 5,
      agents_in_call: 2,
      agents_waiting: 0,
      agents_paused: 3,
      calls_in_queue: 4,
      drop_percent: 3.1,
    });
    const response = await api.post('/api/v2/telemetry', { data: payload });
    expect(response.status()).toBe(200);
    const result = await response.json() as TelemetryResult;
    expect(result.status).toBe('ACTION_REQUIRED');
    expect(result.alerts.map(alert => alert.type)).toEqual(expect.arrayContaining([
      'DROP_ANOMALY', 'QUEUE_SATURATION', 'PAUSED_AGENT_RATIO',
    ]));
    expect(result.alerts.every(alert => ['WARNING', 'CRITICAL'].includes(alert.severity))).toBe(true);
    expect(result.utilization_percent).toBe(40);
  });

  test('strict drop and paused-ratio thresholds do not alert at exactly three percent or forty percent', async ({ api }) => {
    const payload = telemetry({
      campaign_id: isolatedCampaignId(),
      agents_logged_in: 5,
      agents_in_call: 0,
      agents_waiting: 2,
      agents_paused: 2,
      calls_in_queue: 0,
      drop_percent: 3,
    });
    const response = await api.post('/api/v2/telemetry', { data: payload });
    expect(response.status()).toBe(200);
    const result = await response.json() as TelemetryResult;
    expect(result.status).toBe('HEALTHY');
    expect(result.alerts).toEqual([]);
  });

  test('zero logged-in agents have zero utilization and avoid division-by-zero failures', async ({ api }) => {
    const response = await api.post('/api/v2/telemetry', {
      data: telemetry({
        campaign_id: isolatedCampaignId(),
        agents_logged_in: 0,
        agents_in_call: 0,
        agents_waiting: 0,
        agents_paused: 0,
      }),
    });
    expect(response.status()).toBe(200);
    expect(await response.json()).toMatchObject({ utilization_percent: 0 });
  });

  test('persisted telemetry is visible in recent snapshots and campaign summary', async ({ api }) => {
    const campaignId = isolatedCampaignId();
    const payload = telemetry({
      campaign_id: campaignId,
      source_url: 'https://vicidial.test/qa/persisted-snapshot',
      calls_in_queue: 3,
      drop_percent: 1.25,
    });
    const sent = await api.post('/api/v2/telemetry', { data: payload });
    expect(sent.status()).toBe(200);
    expect(await sent.json()).not.toHaveProperty('persist_warning');

    const [recent, summary] = await Promise.all([
      api.get('/api/v2/telemetry/recent?limit=100'),
      api.get(`/api/v2/campaigns/${campaignId}/summary`),
    ]);
    expect(recent.status()).toBe(200);
    expect(summary.status()).toBe(200);
    const snapshots = await recent.json() as { items: Array<Record<string, unknown>> };
    expect(snapshots.items.some(item => item.source_url === payload.source_url && item.campaign_id === campaignId)).toBe(true);
    expect(await summary.json()).toMatchObject({ campaign_id: campaignId, samples: 1, avg_drop_percent: 1.25, avg_queue: 3 });
  });

  test('invalid UUIDs, negative counters, missing required fields and malformed timestamps return 422 @security', async ({ api }) => {
    const invalidUuid = await api.post('/api/v2/telemetry', { data: telemetry({ tenant_id: 'tenant-1' }) });
    const negative = await api.post('/api/v2/telemetry', { data: telemetry({ agents_waiting: -1 }) });
    const badTimestamp = await api.post('/api/v2/telemetry', { data: telemetry({ timestamp: 'not-a-date' }) });
    const missing = await api.post('/api/v2/telemetry', { data: { timestamp: '2025-01-01T00:00:00Z' } });
    expect(invalidUuid.status()).toBe(422);
    expect(negative.status()).toBe(422);
    expect(badTimestamp.status()).toBe(422);
    expect(missing.status()).toBe(422);
  });

  test('malformed JSON is rejected and the API remains available @security', async ({ api }) => {
    const response = await api.post('/api/v2/telemetry', { data: '{', headers: { 'content-type': 'application/json' } });
    expect(response.status()).toBe(422);
    expect((await getHealth(api)).status).toBe('ok');
  });

  test('invalid campaign summary identifier is rejected as a GUID validation error @security', async ({ api }) => {
    const response = await api.get('/api/v2/campaigns/not-a-guid/summary');
    expect(response.status()).toBe(422);
    expect((await response.json()).detail).toContain('campaign_id must be a GUID');
  });
});

test.describe('Client usage logging endpoint @api @regression', () => {
  test('accepts the frontend action/result payload and rejects a missing action', async ({ api }) => {
    const accepted = await api.post('/api/v2/client-log', {
      data: { action: 'qa_test_action', detail: { tab: 'overview' }, result: { ok: true } },
    });
    const invalid = await api.post('/api/v2/client-log', { data: { detail: 'no action' } });
    expect(accepted.status()).toBe(200);
    expect(await accepted.json()).toEqual({ ok: true });
    expect(invalid.status()).toBe(422);
  });
});
