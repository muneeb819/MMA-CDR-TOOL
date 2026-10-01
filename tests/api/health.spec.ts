import { test, expect } from '../fixtures/test.js';
import { getHealth } from '../helpers/api.js';

 test.describe('Health and discovery @api @regression', () => {
  test('database health endpoint returns the service contract @smoke', async ({ api }) => {
    const health = await getHealth(api);
    expect(health).toMatchObject({ status: 'ok', version: '3.0.0' });
    expect(['sqlite', 'sqlserver']).toContain(health.database);
  });

  test('FastAPI OpenAPI describes the checked-in MMA-CDR routes, not stale product routes @regression', async ({ api }) => {
    const response = await api.get('/openapi.json');
    expect(response.status()).toBe(200);
    const openapi = await response.json() as { info: { title: string }; paths: Record<string, unknown> };
    expect(openapi.info.title).toBe('MMA-CDR TOOL API');
    for (const route of [
      '/health',
      '/api/v2/client-log',
      '/api/v2/telemetry',
      '/api/v2/telemetry/recent',
      '/api/v2/uploads/recent',
      '/api/v2/refine',
      '/api/v2/score',
      '/api/v2/scrubber/upload',
      '/api/v2/campaigns/{campaign_id}/summary',
    ]) {
      expect(openapi.paths, `Expected actual API route ${route}`).toHaveProperty(route);
    }
    expect(openapi.paths).not.toHaveProperty('/api/products');
  });

  test('recent-list query limits are clamped to the implemented range @api', async ({ api }) => {
    const lower = await api.get('/api/v2/uploads/recent?limit=0');
    const upper = await api.get('/api/v2/telemetry/recent?limit=1000');
    expect(lower.status()).toBe(200);
    expect(upper.status()).toBe(200);
    const lowerBody = await lower.json() as { items: unknown[] };
    const upperBody = await upper.json() as { items: unknown[] };
    expect(lowerBody.items.length).toBeLessThanOrEqual(1);
    expect(upperBody.items.length).toBeLessThanOrEqual(100);
  });

  test('unsupported methods and unknown routes return exact framework status codes @security', async ({ api }) => {
    expect((await api.put('/health')).status()).toBe(405);
    expect((await api.get('/api/v2/does-not-exist')).status()).toBe(404);
  });
});
