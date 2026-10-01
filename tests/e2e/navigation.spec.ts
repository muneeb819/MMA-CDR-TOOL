import { test, expect } from '../fixtures/test.js';
import { captureBrowserDiagnostics } from '../helpers/browser-diagnostics.js';
import { chromiumSkipReason, chromiumUnavailable } from '../helpers/browser-availability.js';

const navigation = [
  { label: 'Overview', content: 'Scrub lists. Score leads.' },
  { label: 'Scrubber Upload', content: 'Universal scrubber upload' },
  { label: 'Refine & Score', content: 'Normalize · Fingerprint · Score' },
  { label: 'Telemetry', content: 'Send telemetry frame' },
  { label: 'Database / SSMS', content: 'SSMS setup (authoritative)' },
];

test.describe('MMA-CDR TOOL user interface @e2e @regression', () => {
  test.skip(chromiumUnavailable, chromiumSkipReason);

  test('loads the branded app in live mode and navigates all actual tabs @smoke', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByText('MMA-CDR TOOL', { exact: true }).first()).toBeVisible();
    await expect(page.getByText(/LIVE · sqlite/i)).toBeVisible();

    for (const item of navigation) {
      await page.getByRole('button', { name: item.label }).click();
      await expect(page.getByText(item.content, { exact: false }).first()).toBeVisible();
    }
  });

  test('navigation and primary controls remain discoverable in a mobile viewport @smoke', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByText('MMA-CDR TOOL', { exact: true }).first()).toBeVisible();
    const scrubberTab = page.getByRole('button', { name: 'Scrubber Upload' });
    await scrubberTab.scrollIntoViewIfNeeded();
    await scrubberTab.click();
    await expect(page.getByLabel('Phone list file')).toBeVisible();
    await expect(page.getByPlaceholder('Tenant GUID')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Upload & Extract' })).toBeVisible();

    const refineTab = page.getByRole('button', { name: 'Refine & Score' });
    await refineTab.scrollIntoViewIfNeeded();
    await refineTab.click();
    await expect(page.getByLabel('Phone number')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Refine + Score' })).toBeVisible();
  });

  test('all visible buttons have accessible names and keyboard focus reaches navigation', async ({ page }) => {
    await page.goto('/');
    const buttons = await page.getByRole('button').all();
    expect(buttons.length).toBeGreaterThanOrEqual(7);
    for (const button of buttons) {
      const accessibleName = await button.getAttribute('aria-label') || (await button.innerText()).trim();
      expect(accessibleName.length).toBeGreaterThan(0);
    }
    await page.keyboard.press('Tab');
    await expect(page.locator(':focus')).toBeVisible();
  });

  test('page has no uncaught exceptions, console errors or failed critical requests @regression', async ({ page }) => {
    const diagnostics = captureBrowserDiagnostics(page);
    await page.goto('/');
    await expect(page.getByText('MMA-CDR TOOL', { exact: true }).first()).toBeVisible();
    await page.getByRole('button', { name: 'Scrubber Upload' }).click();
    await expect(page.getByRole('button', { name: 'Upload & Extract' })).toBeEnabled();
    await page.getByRole('button', { name: 'Telemetry' }).click();
    await expect(page.getByRole('button', { name: 'Analyze + Persist' })).toBeVisible();
    await expect(page.getByText(/LIVE · sqlite/i)).toBeVisible();
    expect(diagnostics.consoleErrors).toEqual([]);
    expect(diagnostics.pageErrors).toEqual([]);
    expect(diagnostics.failedCriticalRequests).toEqual([]);
  });
});
