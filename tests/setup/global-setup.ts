import { request, type FullConfig } from '@playwright/test';
import { openTestSqlServer, sqlServerTestConfig } from '../helpers/database.js';

export default async function globalSetup(_config: FullConfig): Promise<void> {
  const apiURL = process.env.API_URL || 'http://127.0.0.1:8000';
  const frontendURL = process.env.BASE_URL || 'http://127.0.0.1:5173';
  const api = await request.newContext({ timeout: 10_000 });
  try {
    let response;
    try {
      response = await api.get(new URL('/health', apiURL).toString());
    } catch {
      throw new Error(`Required API is unavailable at ${apiURL}/health. Check API_URL or local Playwright webServer startup.`);
    }
    if (!response.ok()) {
      throw new Error(`Required API health check returned HTTP ${response.status()} at ${apiURL}/health.`);
    }
    const health = await response.json() as { status?: string; database?: string; version?: string };
    if (health.status !== 'ok') {
      // Never echo backend exception detail here: database drivers can include connection data.
      throw new Error(`API health is not ready (status=${health.status || 'unknown'}, database=${health.database || 'unknown'}).`);
    }
    console.log(`QA setup: API ready (${health.version || 'unknown'}; database=${health.database || 'unknown'}).`);

    let frontendResponse;
    try {
      frontendResponse = await api.get(frontendURL);
    } catch {
      throw new Error(`Required frontend is unavailable at ${frontendURL}. Check BASE_URL or local Playwright webServer startup.`);
    }
    if (!frontendResponse.ok()) {
      throw new Error(`Required frontend returned HTTP ${frontendResponse.status()} at ${frontendURL}.`);
    }
    const html = await frontendResponse.text();
    if (!html.includes('MMA-CDR TOOL')) {
      throw new Error(`Frontend at ${frontendURL} did not return the MMA-CDR TOOL application shell.`);
    }

    if (process.env.RUN_SQLSERVER_TESTS === '1') {
      const config = sqlServerTestConfig();
      if (!config) {
        throw new Error('RUN_SQLSERVER_TESTS=1 requires SQLSERVER_HOST, SQLSERVER_USER, SQLSERVER_PASSWORD and a dedicated SQLSERVER_TEST_DATABASE (or SQLSERVER_DATABASE ending in _test/_qa).');
      }
      const pool = await openTestSqlServer();
      try {
        const result = await pool.request().query('SELECT DB_NAME() AS database_name');
        console.log(`QA setup: dedicated SQL Server test database ready (${result.recordset[0]?.database_name}).`);
      } finally {
        await pool.close();
      }
    }
  } finally {
    await api.dispose();
  }
}
