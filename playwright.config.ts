import { existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium, defineConfig, devices } from '@playwright/test';

const root = path.dirname(fileURLToPath(import.meta.url));
const chromiumInstalled = existsSync(chromium.executablePath());
if (chromiumInstalled) delete process.env.PW_CHROMIUM_UNAVAILABLE;
else process.env.PW_CHROMIUM_UNAVAILABLE = '1';
const apiBaseURL = stripTrailingSlash(process.env.API_URL || 'http://127.0.0.1:8000');
const frontendBaseURL = stripTrailingSlash(process.env.BASE_URL || 'http://127.0.0.1:5173');
const apiPort = new URL(apiBaseURL).port || '8000';
const frontendPort = new URL(frontendBaseURL).port || '5173';
const sqlitePath = path.resolve(
  process.env.MMA_CDR_SQLITE_PATH || path.join(root, 'test-results', `mma-cdr-playwright-${process.pid}.sqlite`),
);
const artifactsDir = path.resolve(root, 'test-results');
type LocalWebServer = {
  command: string;
  url: string;
  name: string;
  timeout: number;
  reuseExistingServer: boolean;
  env: Record<string, string>;
};

const localTargets = isLoopback(apiBaseURL) && isLoopback(frontendBaseURL);
if (!localTargets && process.env.PW_START_SERVERS !== '0') {
  throw new Error('Non-loopback QA targets require PW_START_SERVERS=0 so the runner never starts a local service against them.');
}
if (!localTargets && process.env.QA_ALLOW_REMOTE_TARGET !== '1') {
  throw new Error('Remote QA targets are disabled by default. Set QA_ALLOW_REMOTE_TARGET=1 only for a dedicated non-production test environment.');
}
const reuseExistingServer = process.env.PW_REUSE_EXISTING === '1';
const startLocalServices = process.env.PW_START_SERVERS === '1'
  || (process.env.PW_START_SERVERS !== '0' && localTargets);
const python = pythonCommand();

// Keep defaults available to test fixtures and the startup scripts. These are
// synthetic test identifiers, not credentials or production tenant data.
process.env.API_URL = apiBaseURL;
process.env.BASE_URL = frontendBaseURL;
process.env.TEST_TENANT_ID ||= '00000000-0000-0000-0000-000000000001';
process.env.TEST_CAMPAIGN_ID ||= '22222222-2222-4222-8222-222222222222';
if (startLocalServices) {
  process.env.MMA_CDR_USE_SQLITE = '1';
  process.env.MMA_CDR_SQLITE_PATH = sqlitePath;
  process.env.MAX_UPLOAD_MB ||= '8';
  process.env.WSS_ALLOWED_ORIGINS ||= '*';
  process.env.API_PORT = apiPort;
  process.env.FRONTEND_PORT = frontendPort;
}

mkdirSync(artifactsDir, { recursive: true });

const webServer: LocalWebServer[] = startLocalServices
  ? [
      {
        command: 'node tests/setup/start-api.mjs',
        url: `${apiBaseURL}/health`,
        name: 'MMA-CDR API (isolated SQLite)',
        timeout: 120_000,
        reuseExistingServer,
        env: {
          API_HOST: '0.0.0.0',
          API_PORT: apiPort,
          PYTHON: python,
          MMA_CDR_USE_SQLITE: '1',
          MMA_CDR_SQLITE_PATH: sqlitePath,
          MAX_UPLOAD_MB: process.env.MAX_UPLOAD_MB || '8',
          WSS_ALLOWED_ORIGINS: process.env.WSS_ALLOWED_ORIGINS || '*',
          TEST_TENANT_ID: process.env.TEST_TENANT_ID!,
          TEST_CAMPAIGN_ID: process.env.TEST_CAMPAIGN_ID!,
        },
      },
      {
        command: `npm run dev -- --host 0.0.0.0 --port ${frontendPort} --strictPort`,
        url: frontendBaseURL,
        name: 'MMA-CDR frontend',
        timeout: 120_000,
        reuseExistingServer,
        env: {
          API_PROXY_TARGET: process.env.API_PROXY_TARGET || apiBaseURL,
          VITE_API_URL: process.env.VITE_API_URL || '',
          FRONTEND_PORT: frontendPort,
        },
      },
    ]
  : [];

if (process.env.PW_START_RUST === '1') {
  if (!commandExists('cargo')) {
    throw new Error('PW_START_RUST=1 requires Rust/Cargo. Install Rust or provide RUST_REFINERY_URL.');
  }
  process.env.RUST_REFINERY_URL ||= 'http://127.0.0.1:9100';
  webServer.push({
    command: 'cargo run --manifest-path refinery/Cargo.toml',
    url: `${stripTrailingSlash(process.env.RUST_REFINERY_URL)}/health`,
    name: 'Rust refinery',
    timeout: 300_000,
    reuseExistingServer,
    env: process.env as Record<string, string>,
  });
}

export default defineConfig({
  testDir: './tests',
  testMatch: /.*\.spec\.ts/,
  globalSetup: './tests/setup/global-setup.ts',
  globalTeardown: './tests/setup/global-teardown.ts',
  timeout: 45_000,
  expect: { timeout: 7_000 },
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  workers: process.env.PW_WORKERS ? Number(process.env.PW_WORKERS) : (process.env.CI ? 2 : 1),
  outputDir: path.join(artifactsDir, 'playwright'),
  reporter: [
    ['list'],
    ['html', { outputFolder: path.join(root, 'playwright-report'), open: 'never' }],
    ['json', { outputFile: path.join(artifactsDir, 'results.json') }],
    ['junit', { outputFile: path.join(artifactsDir, 'junit.xml') }],
    ['./tests/reporters/qa-summary-reporter.mjs'],
  ],
  use: {
    baseURL: frontendBaseURL,
    actionTimeout: 10_000,
    navigationTimeout: 20_000,
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    trace: 'retain-on-failure',
    ignoreHTTPSErrors: false,
  },
  projects: [
    {
      name: 'api',
      testMatch: /tests\/(?:api|database|refinery|extension)\/.*\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'e2e-desktop',
      testMatch: /tests\/e2e\/.*\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'e2e-mobile',
      testMatch: /tests\/e2e\/.*\.spec\.ts/,
      use: { ...devices['Pixel 7'] },
    },
  ],
  webServer,
});

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

function isLoopback(value: string): boolean {
  const host = new URL(value).hostname.toLowerCase();
  return host === 'localhost' || host === '127.0.0.1' || host === '::1';
}

function pythonCommand(): string {
  if (process.env.PYTHON) return process.env.PYTHON;
  const candidates = process.platform === 'win32'
    ? [path.join(root, '.venv', 'Scripts', 'python.exe')]
    : [path.join(root, '.venv', 'bin', 'python')];
  return candidates.find(candidate => existsSync(candidate)) || (process.platform === 'win32' ? 'python' : 'python3');
}

function commandExists(command: string): boolean {
  const pathValue = process.env.PATH || '';
  return pathValue.split(path.delimiter).some(directory => existsSync(path.join(directory, command))
    || (process.platform === 'win32' && existsSync(path.join(directory, `${command}.exe`))));
}
