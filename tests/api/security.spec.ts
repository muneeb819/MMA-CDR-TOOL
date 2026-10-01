import { test, expect } from '../fixtures/test.js';
import { TEST_TENANT_ID } from '../helpers/api.js';
import { fixture } from '../helpers/files.js';

test.describe('Non-destructive API security checks @api @security @regression', () => {
  test('CORS preflight reflects the configured allowlist (local default is wildcard)', async ({ api }) => {
    const configured = (process.env.WSS_ALLOWED_ORIGINS || '*').split(',').map(value => value.trim());
    const origin = configured.includes('*') ? 'https://qa-origin.invalid' : configured[0];
    const preflight = await api.fetch('/api/v2/score', {
      method: 'OPTIONS',
      headers: {
        Origin: origin,
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'content-type',
      },
    });
    expect(preflight.status()).toBe(200);
    expect(preflight.headers()['access-control-allow-origin']).toBe(origin);
    expect(preflight.headers()['access-control-allow-credentials']).toBe('true');
    // The repository's default WSS_ALLOWED_ORIGINS is '*'; this assertion makes
    // that current policy visible rather than claiming that it is restrictive.
  });

  test('logical field limits reject oversized API values with schema errors', async ({ api }) => {
    const longPhone = await api.post('/api/v2/refine', { data: { phone: '1'.repeat(65) } });
    const longSource = await api.post('/api/v2/telemetry', {
      data: {
        timestamp: '2025-01-15T12:00:00.000Z', source_url: 'x'.repeat(1001),
        agents_logged_in: 0, agents_in_call: 0, agents_waiting: 0, agents_paused: 0,
        calls_in_queue: 0, drop_percent: 0,
      },
    });
    const longAction = await api.post('/api/v2/client-log', { data: { action: 'a'.repeat(101) } });
    expect(longPhone.status()).toBe(422);
    expect(longSource.status()).toBe(422);
    expect(longAction.status()).toBe(422);
  });

  test('upload metadata lengths are bounded by the SQL Server column contract', async ({ api }) => {
    const overlongName = await api.post('/api/v2/scrubber/upload', {
      multipart: {
        file: { name: `${'x'.repeat(513)}.csv`, mimeType: 'text/csv', buffer: fixture('phones.csv') },
        tenant_id: TEST_TENANT_ID,
      },
    });
    const overlongMime = await api.post('/api/v2/scrubber/upload', {
      multipart: {
        file: { name: 'phones.csv', mimeType: `application/${'x'.repeat(250)}`, buffer: fixture('phones.csv') },
        tenant_id: TEST_TENANT_ID,
      },
    });
    expect(overlongName.status()).toBe(422);
    expect((await overlongName.json()).detail).toContain('Filename must be at most 512');
    expect(overlongMime.status()).toBe(422);
    expect((await overlongMime.json()).detail).toContain('MIME type must be at most 255');
  });

  test('malformed multipart content is rejected without an unhandled server failure', async ({ api }) => {
    const response = await api.fetch('/api/v2/scrubber/upload', {
      method: 'POST',
      headers: { 'content-type': 'multipart/form-data' },
      data: 'not-a-valid-multipart-boundary',
    });
    expect([400, 422]).toContain(response.status());
    expect(response.status()).not.toBe(500);
    expect((await api.get('/health')).status()).toBe(200);
  });

  test('CRLF text in a telemetry URL is data and is never copied to response headers @regression', async ({ api }) => {
    const response = await api.post('/api/v2/telemetry', {
      data: {
        timestamp: '2025-01-15T12:00:00Z',
        source_url: 'https://vicidial.test/path\r\nX-Injected: yes',
        agents_logged_in: 0, agents_in_call: 0, agents_waiting: 0, agents_paused: 0,
        calls_in_queue: 0, drop_percent: 0,
      },
    });
    expect(response.status()).toBe(200);
    expect(response.headers()).not.toHaveProperty('x-injected');
  });

  test('SQL-like, Unicode and null-byte inputs remain validation data, not executable SQL', async ({ api }) => {
    const values = ["x'; DROP TABLE leads;--", '☎', '\u0000', '../tenant/0001'];
    for (const tenant_id of values) {
      const response = await api.post('/api/v2/score', { data: { phone: '+14155550132', tenant_id } });
      expect(response.status()).toBe(422);
      expect((await response.json()).detail).toContain('tenant_id must be a GUID');
    }
    expect((await api.get('/health')).status()).toBe(200);
  });
});
