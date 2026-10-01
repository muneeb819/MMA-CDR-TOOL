import { randomUUID } from 'node:crypto';
import { test, expect } from '../fixtures/test.js';
import { getHealth, TEST_TENANT_ID, uploadFile, validTelemetry } from '../helpers/api.js';
import { isolatedCampaignId } from '../helpers/test-data.js';
import { querySqlite, sqliteDatabaseAvailable } from '../helpers/database.js';

function syntheticTestPhone(): string {
  const entropy = randomUUID().replaceAll('-', '');
  const areaCode = 200 + (Number.parseInt(entropy.slice(0, 4), 16) % 800);
  const line = String(Number.parseInt(entropy.slice(4, 8), 16) % 100).padStart(2, '0');
  return `+1${areaCode}55501${line}`;
}

test.describe('Cross-endpoint workflows @api @workflow @regression', () => {
  test('upload → extracted candidate → refine → score → persisted decision @scrubber @phone-extraction @refinery @scoring @smoke', async ({ api }) => {
    const phone = syntheticTestPhone();
    const campaignId = isolatedCampaignId();
    const csv = `record_id,phone\nqa-synthetic,${phone}\n`;
    const { response: uploadResponse, body: upload } = await uploadFile(api, 'workflow.csv', csv, 'text/csv', { campaignId });
    expect(uploadResponse.status()).toBe(200);
    expect(upload).toMatchObject({ ok: true, parser: 'TEXT_TABLE', phone_candidates: 1, sample: [phone] });

    const refineResponse = await api.post('/api/v2/refine', {
      data: { phone: upload.sample[0] },
    });
    expect(refineResponse.status()).toBe(200);
    expect(await refineResponse.json()).toMatchObject({
      normalized_phone: phone,
      decision: 'PASS',
      flags: 0,
    });

    const scoreResponse = await api.post('/api/v2/score', {
      data: {
        phone: upload.sample[0],
        tenant_id: TEST_TENANT_ID,
        campaign_id: campaignId,
        reachable: true,
        freshness_days: 0,
        attempts: 0,
        answered: 0,
      },
    });
    expect(scoreResponse.status()).toBe(200);
    const score = await scoreResponse.json();
    expect(score).toMatchObject({ decision: 'CALL', normalized_phone: phone, compliance_status: 'PASS' });
    expect(score).not.toHaveProperty('persist_warning');

    const health = await getHealth(api);
    if (health.database === 'sqlite' && sqliteDatabaseAvailable() && process.env.PW_START_SERVERS !== '0') {
      const stagedRows = querySqlite(
        'SELECT normalized_phone, parse_status FROM raw_records WHERE upload_batch_id = ?',
        [upload.upload_batch_id],
      );
      expect(stagedRows).toEqual([{ normalized_phone: phone, parse_status: 'EXTRACTED' }]);
      const persistedDecision = querySqlite(
        'SELECT decision_code, campaign_id FROM decisions WHERE phone = ? ORDER BY decision_id DESC LIMIT 1',
        [phone],
      );
      expect(persistedDecision).toEqual([{ decision_code: 'CALL', campaign_id: campaignId }]);
    } else {
      test.info().annotations.push({
        type: 'database-check',
        description: 'The local isolated SQLite file is unavailable; upload/refine/score response flow completed without direct persistence inspection.',
      });
    }
  });

  test('VICIdial telemetry → alert analysis → persisted snapshot → dashboard reads @telemetry @smoke', async ({ api }) => {
    const campaignId = isolatedCampaignId();
    const sourceUrl = 'https://vicidial.test/agc/vicidial.php?qa=synthetic';
    const response = await api.post('/api/v2/telemetry', {
      data: validTelemetry({
        campaign_id: campaignId,
        source_url: sourceUrl,
        agents_logged_in: 5,
        agents_in_call: 2,
        agents_waiting: 0,
        agents_paused: 3,
        calls_in_queue: 4,
        drop_percent: 4.5,
      }),
    });
    expect(response.status()).toBe(200);
    const analysis = await response.json();
    expect(analysis.status).toBe('ACTION_REQUIRED');
    expect(analysis.alerts.map((alert: { type: string }) => alert.type)).toEqual(expect.arrayContaining([
      'DROP_ANOMALY', 'QUEUE_SATURATION', 'PAUSED_AGENT_RATIO',
    ]));

    const [recentResponse, summaryResponse] = await Promise.all([
      api.get('/api/v2/telemetry/recent?limit=100'),
      api.get(`/api/v2/campaigns/${campaignId}/summary`),
    ]);
    expect(recentResponse.status()).toBe(200);
    expect(summaryResponse.status()).toBe(200);
    const recent = await recentResponse.json() as { items: Array<Record<string, unknown>> };
    expect(recent.items.some(item => item.source_url === sourceUrl && item.campaign_id === campaignId)).toBe(true);
    expect(await summaryResponse.json()).toMatchObject({
      campaign_id: campaignId,
      samples: 1,
      avg_drop_percent: 4.5,
      avg_queue: 4,
    });

    const health = await getHealth(api);
    if (health.database === 'sqlite' && sqliteDatabaseAvailable() && process.env.PW_START_SERVERS !== '0') {
      const persistedAlerts = querySqlite(
        'SELECT alert_type FROM alerts WHERE campaign_id = ? ORDER BY alert_type',
        [campaignId],
      );
      expect(persistedAlerts.map(alert => alert.alert_type)).toEqual([
        'DROP_ANOMALY', 'PAUSED_AGENT_RATIO', 'QUEUE_SATURATION',
      ]);
    } else {
      test.info().annotations.push({
        type: 'database-check',
        description: 'Direct SQLite alert-table inspection is unavailable; telemetry response and dashboard read routes completed.',
      });
    }
  });
});
