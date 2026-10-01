import { randomUUID } from 'node:crypto';
import { test, expect } from '../fixtures/test.js';
import { getHealth, uploadFile } from '../helpers/api.js';
import { fixture } from '../helpers/files.js';
import { querySqlite, sqliteDatabaseAvailable, sqliteUniqueRollbackProbe } from '../helpers/database.js';

test.describe('SQLite development fallback @database @regression', () => {
  test('health reports the active fallback and its actual isolated schema', async ({ api }) => {
    const health = await getHealth(api);
    test.skip(health.database !== 'sqlite' || !sqliteDatabaseAvailable(), 'SQLite-specific contract requires a reachable SQLite test database.');

    const tables = querySqlite<{ name: string }>("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map(row => row.name);
    expect(tables).toEqual(['alerts', 'campaigns', 'decisions', 'raw_records', 'telemetry_snapshots', 'tenants', 'upload_batches']);
    const batchColumns = querySqlite<{ name: string; type: string; notnull: number }>('PRAGMA table_info(upload_batches)');
    expect(batchColumns.map(column => column.name)).toEqual(expect.arrayContaining([
      'upload_batch_id', 'tenant_id', 'original_file_name', 'file_size_bytes', 'sha256_hex', 'status', 'extracted_phone_count',
    ]));
    expect(batchColumns.find(column => column.name === 'file_size_bytes')).toMatchObject({ type: 'INTEGER', notnull: 1 });

    // The current fallback is intentionally smaller than the authoritative SQL Server schema.
    expect(tables).not.toContain('upload_files');
    expect(tables).not.toContain('phone_numbers');
  });

  test('upload persists extracted rows and associates them with its batch', async ({ api }) => {
    const health = await getHealth(api);
    test.skip(health.database !== 'sqlite' || !sqliteDatabaseAvailable(), 'Direct SQLite assertions require the isolated SQLite fallback.');
    const { response, body } = await uploadFile(api, 'sqlite-stage.csv', fixture('phones.csv'));
    expect(response.status()).toBe(200);
    const batches = querySqlite('SELECT status, total_records, extracted_phone_count FROM upload_batches WHERE upload_batch_id = ?', [body.upload_batch_id]);
    const rows = querySqlite('SELECT raw_text, normalized_phone, parse_status FROM raw_records WHERE upload_batch_id = ? ORDER BY source_row_number', [body.upload_batch_id]);
    expect(batches).toEqual([{ status: 'COMPLETED', total_records: 4, extracted_phone_count: 3 }]);
    expect(rows).toHaveLength(3);
    expect(rows.map(row => row.normalized_phone)).toEqual(['+14155550132', '+12125550111', '+13105550123']);
    expect(rows.every(row => row.parse_status === 'EXTRACTED')).toBe(true);
  });

  test('scoring and telemetry side effects are persisted in their SQLite tables', async ({ api }) => {
    const health = await getHealth(api);
    test.skip(health.database !== 'sqlite' || !sqliteDatabaseAvailable(), 'Direct SQLite assertions require the isolated SQLite fallback.');
    const syntheticSuffix = String(Number.parseInt(randomUUID().replaceAll('-', '').slice(0, 8), 16) % 100).padStart(2, '0');
    const syntheticPhone = `+141555501${syntheticSuffix}`;
    const scoreResponse = await api.post('/api/v2/score', { data: { phone: syntheticPhone, reachable: true } });
    expect(scoreResponse.status()).toBe(200);
    const score = await scoreResponse.json();
    const decision = querySqlite('SELECT decision_code, phone, ruleset_version FROM decisions WHERE phone = ? ORDER BY decision_id DESC LIMIT 1', [syntheticPhone]);
    expect(decision[0]).toMatchObject({ decision_code: 'CALL', phone: syntheticPhone, ruleset_version: '2.0.0' });
    expect(score.decision).toBe(decision[0].decision_code);

    const campaignId = randomUUID();
    const telemetryResponse = await api.post('/api/v2/telemetry', {
      data: {
        timestamp: '2025-01-15T12:00:00Z', tenant_id: process.env.TEST_TENANT_ID,
        campaign_id: campaignId, source_url: 'https://vicidial.test/sqlite-persistence',
        agents_logged_in: 4, agents_in_call: 1, agents_waiting: 0, agents_paused: 3,
        calls_in_queue: 2, drop_percent: 4.5,
      },
    });
    expect(telemetryResponse.status()).toBe(200);
    expect((await telemetryResponse.json()).persist_warning).toBeUndefined();
    const snapshot = querySqlite('SELECT campaign_id, drop_percent FROM telemetry_snapshots WHERE campaign_id = ?', [campaignId]);
    const alerts = querySqlite('SELECT alert_type FROM alerts WHERE campaign_id = ?', [campaignId]);
    expect(snapshot).toEqual([{ campaign_id: campaignId, drop_percent: 4.5 }]);
    expect(alerts.map(row => row.alert_type)).toEqual(expect.arrayContaining(['DROP_ANOMALY', 'QUEUE_SATURATION', 'PAUSED_AGENT_RATIO']));
  });

  test('SQLite primary-key/tenant-key constraints reject duplicates and rollback leaves no probe rows', async ({ api }) => {
    const health = await getHealth(api);
    test.skip(health.database !== 'sqlite' || !sqliteDatabaseAvailable(), 'SQLite constraint probe requires the isolated SQLite fallback.');
    const id = randomUUID();
    const key = `qa-rollback-${id}`;
    const outcome = sqliteUniqueRollbackProbe(id, key);
    expect(outcome).toEqual({ duplicateRejected: true, rolledBack: true });
    expect(querySqlite('SELECT tenant_id FROM tenants WHERE tenant_id = ?', [id])).toEqual([]);
  });
});
