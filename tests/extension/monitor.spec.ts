import { readFileSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { test, expect } from '../fixtures/test.js';
import { chromiumSkipReason, chromiumUnavailable } from '../helpers/browser-availability.js';

const extensionDir = path.resolve('extension');
const manifest = JSON.parse(readFileSync(path.join(extensionDir, 'manifest.json'), 'utf8')) as {
  manifest_version: number; name: string; permissions: string[]; background: { service_worker: string };
  content_scripts: Array<{ js: string[]; matches: string[] }>;
};

test.describe('VICIdial Chrome monitor contract @regression', () => {
  test('manifest points to the tracked MV3 worker and content script', () => {
    expect(manifest).toMatchObject({ manifest_version: 3, name: 'MMA-CDR TOOL Monitor' });
    expect(manifest.permissions).toContain('storage');
    expect(manifest.background.service_worker).toBe('background.js');
    expect(manifest.content_scripts[0].js).toEqual(['content.js']);
    expect(readFileSync(path.join(extensionDir, manifest.background.service_worker), 'utf8')).toContain('/ws/v2/vici');
  });

  test('content monitor maps VICIdial labels into the API telemetry frame', () => {
    const source = readFileSync(path.join(extensionDir, 'content.js'), 'utf8');
    const sent: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const sandbox = {
      document: {
        title: 'Synthetic VICIdial dashboard',
        body: { innerText: [
          'Agents Logged In: 12', 'Agents In Calls: 8', 'Agents Waiting: 2',
          'Agents Paused: 1', 'Calls In Queue: 5', 'DROP PERCENT: 4.2%',
        ].join('\n') },
      },
      location: { href: 'https://vicidial.test/agc/vicidial.php' },
      window: {},
      chrome: { runtime: { sendMessage: (message: { type: string; payload: Record<string, unknown> }) => sent.push(message) } },
      MutationObserver: class { observe() {} },
      setInterval: () => 1,
      setTimeout: () => 1,
      clearTimeout: () => undefined,
      Date,
      Number,
      console,
    };
    vm.runInNewContext(source, sandbox, { filename: 'extension/content.js', timeout: 1_000 });
    expect(sent).toHaveLength(1);
    expect(sent[0].type).toBe('TELEMETRY');
    expect(sent[0].payload).toMatchObject({
      source_url: 'https://vicidial.test/agc/vicidial.php',
      agents_logged_in: 12,
      agents_in_call: 8,
      agents_waiting: 2,
      agents_paused: 1,
      calls_in_queue: 5,
      drop_percent: 4.2,
      raw: { title: 'Synthetic VICIdial dashboard' },
    });
    expect(typeof sent[0].payload.timestamp).toBe('string');
  });

  test.describe('popup safety @security', () => {
    test.skip(chromiumUnavailable, chromiumSkipReason);

    test('renders untrusted alert text with text nodes rather than HTML', async ({ page }) => {
    const popup = readFileSync(path.join(extensionDir, 'popup.html'), 'utf8');
    await page.addInitScript(() => {
      (window as unknown as { chrome?: unknown; __xssExecuted: boolean }).__xssExecuted = false;
      (window as unknown as { chrome?: unknown }).chrome = {
        runtime: {
          sendMessage: (_message: unknown, callback?: (response: unknown) => void) => callback?.({
            raw: { agents_in_call: 8, calls_in_queue: 5, drop_percent: 4.2 },
            ai_insights: {
              efficiency_score: 55,
              alerts: [{ severity: 'WARNING', message: '<img src=x onerror="window.__xssExecuted=true">' }],
            },
          }),
          onMessage: { addListener: () => undefined },
        },
      };
    });
    await page.setContent(popup);
    await expect(page.locator('#call')).toHaveText('8');
    await expect(page.locator('#alerts')).toContainText('<img src=x onerror="window.__xssExecuted=true">');
    expect(await page.locator('#alerts img').count()).toBe(0);
      expect(await page.evaluate(() => (window as unknown as { __xssExecuted: boolean }).__xssExecuted)).toBe(false);
    });
  });
});
