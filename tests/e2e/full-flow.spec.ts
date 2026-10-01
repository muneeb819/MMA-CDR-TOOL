import { test, expect } from '../fixtures/test.js';
import { fixture } from '../helpers/files.js';
import { getHealth } from '../helpers/api.js';
import { querySqlite, sqliteDatabaseAvailable } from '../helpers/database.js';
import { chromiumSkipReason, chromiumUnavailable } from '../helpers/browser-availability.js';

test.describe('Scrub to decision and VICIdial telemetry workflow @e2e @smoke @regression @scrubber @phone-extraction @refinery @scoring @telemetry', () => {
  test.skip(chromiumUnavailable, chromiumSkipReason);

  test('UI upload → extraction/staging → refine → score → telemetry → dashboard @smoke', async ({ page, api }) => {
    await page.goto('/');
    await expect(page.getByText('MMA-CDR TOOL', { exact: true }).first()).toBeVisible();
    await expect(page.getByText(/LIVE · sqlite/i)).toBeVisible();

    await page.getByRole('button', { name: 'Scrubber Upload' }).click();
    await page.getByLabel('Phone list file').setInputFiles({
      name: 'phones.csv',
      mimeType: 'text/csv',
      buffer: fixture('phones.csv'),
    });
    await page.getByRole('button', { name: 'Upload & Extract' }).click();
    const uploadResult = page.getByTestId('upload-result');
    await expect(uploadResult).toContainText('"ok": true');
    await expect(uploadResult).toContainText('"phone_candidates": 3');
    const uploadBody = JSON.parse(await uploadResult.innerText()) as { upload_batch_id: string };

    await page.getByRole('button', { name: 'Refine & Score' }).click();
    await page.getByLabel('Phone number').fill('+1 (415) 555-0132');
    await page.getByRole('button', { name: 'Refine + Score' }).click();
    const refineResult = page.getByTestId('refine-result');
    await expect(refineResult).toContainText('"decision": "PASS"');
    await expect(refineResult).toContainText('"decision": "CALL"');
    await expect(refineResult).toContainText('"normalized_phone": "+14155550132"');

    await page.getByRole('button', { name: 'Telemetry' }).click();
    await page.getByRole('button', { name: 'Analyze + Persist' }).click();
    const telemetryResult = page.getByTestId('telemetry-result');
    await expect(telemetryResult).toContainText('"status": "ACTION_REQUIRED"');
    await expect(telemetryResult).toContainText('DROP_ANOMALY');
    await expect(telemetryResult).toContainText('QUEUE_SATURATION');

    const health = await getHealth(api);
    if (health.database === 'sqlite' && sqliteDatabaseAvailable()) {
      const staged = querySqlite('SELECT normalized_phone, parse_status FROM raw_records WHERE upload_batch_id = ?', [uploadBody.upload_batch_id]);
      expect(staged).toHaveLength(3);
      expect(staged.map(row => row.normalized_phone)).toContain('+14155550132');
      expect(staged.every(row => row.parse_status === 'EXTRACTED')).toBe(true);
      const decisions = querySqlite('SELECT decision_code FROM decisions WHERE phone = ?', ['+14155550132']);
      expect(decisions.some(row => row.decision_code === 'CALL')).toBe(true);
      const snapshots = querySqlite('SELECT telemetry_id FROM telemetry_snapshots WHERE source_url = ?', ['https://vicidial.local/agc/vicidial.php']);
      expect(snapshots.length).toBeGreaterThan(0);
    } else {
      test.info().annotations.push({ type: 'database-check', description: 'Direct SQLite assertions unavailable for the configured external database; API response checks completed.' });
    }

    await page.getByRole('button', { name: 'Overview' }).click();
    await expect(page.getByText('Recent uploads')).toBeVisible();
    await expect(page.getByText('phones.csv', { exact: false })).toBeVisible();
    await expect(page.getByText('Recent telemetry')).toBeVisible();

    await page.getByRole('button', { name: 'Database / SSMS' }).click();
    await expect(page.getByText('SSMS setup (authoritative)')).toBeVisible();
    await expect(page.getByText('processing_jobs', { exact: true })).toBeVisible();
  });
});
