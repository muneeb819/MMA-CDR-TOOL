import { test, expect } from '../fixtures/test.js';
import { captureBrowserDiagnostics } from '../helpers/browser-diagnostics.js';
import { chromiumSkipReason, chromiumUnavailable } from '../helpers/browser-availability.js';

test.describe('Frontend failure handling and safe rendering @e2e @security @regression', () => {
  test.skip(chromiumUnavailable, chromiumSkipReason);

  test('API offline mode renders the documented demo state without an uncaught exception', async ({ page }) => {
    const pageErrors: string[] = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    await page.route('**/health', route => route.abort('failed'));
    await page.goto('/');
    await expect(page.getByText('○ DEMO MODE')).toBeVisible();
    await expect(page.getByText(/API offline — running in demo mode/)).toBeVisible();
    expect(pageErrors).toEqual([]);
  });

  test('XSS-like phone input is rendered as text and cannot execute in the React UI', async ({ page }) => {
    const dialogs: string[] = [];
    page.on('dialog', dialog => {
      dialogs.push(dialog.message());
      void dialog.dismiss();
    });
    await page.goto('/');
    await page.getByRole('button', { name: 'Refine & Score' }).click();
    await page.getByLabel('Phone number').fill('<img src=x onerror=alert(1)>');
    await page.getByRole('button', { name: 'Refine + Score' }).click();
    await expect(page.getByTestId('refine-result')).toContainText('INVALID');
    expect(await page.locator('img').count()).toBe(0);
    expect(dialogs).toEqual([]);
  });

  test('browser-facing API calls stay same-origin behind the Vite proxy @security', async ({ page }) => {
    const apiRequests: string[] = [];
    page.on('request', request => {
      if (request.url().includes('/api/') || request.url().endsWith('/health')) apiRequests.push(request.url());
    });
    await page.goto('/');
    await expect(page.getByText(/LIVE · sqlite/i)).toBeVisible();
    expect(apiRequests.length).toBeGreaterThan(0);
    for (const url of apiRequests) {
      expect(new URL(url).origin).toBe(new URL(process.env.BASE_URL || 'http://127.0.0.1:5173').origin);
    }
  });

  test('critical UI actions produce no browser exceptions, console errors or failed API requests @regression', async ({ page }) => {
    const diagnostics = captureBrowserDiagnostics(page);
    await page.goto('/');
    await page.getByRole('button', { name: 'Scrubber Upload' }).click();
    await page.getByRole('button', { name: 'Refine & Score' }).click();
    await page.getByRole('button', { name: 'Telemetry' }).click();
    await expect(page.getByRole('button', { name: 'Analyze + Persist' })).toBeVisible();
    expect(diagnostics.consoleErrors).toEqual([]);
    expect(diagnostics.pageErrors).toEqual([]);
    expect(diagnostics.failedCriticalRequests).toEqual([]);
  });
});
