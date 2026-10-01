import { randomUUID } from 'node:crypto';
import { TEST_TENANT_ID, TEST_CAMPAIGN_ID } from './api.js';
import type { TelemetryPayload } from './types.js';

export const phones = {
  formatted: '+1 (415) 555-0132',
  e164: '+14155550132',
  second: '+12125550111',
  third: '+13105550123',
  short: '555-0132',
  international: '+442079460000',
  tenantId: TEST_TENANT_ID,
  campaignId: TEST_CAMPAIGN_ID,
};

export function isolatedCampaignId(): string {
  return randomUUID();
}

export function telemetry(overrides: Partial<TelemetryPayload> = {}): TelemetryPayload {
  return {
    timestamp: '2025-01-15T12:00:00.000Z',
    tenant_id: phones.tenantId,
    source_url: 'https://vicidial.test/agc/vicidial.php',
    agents_logged_in: 10,
    agents_in_call: 4,
    agents_waiting: 2,
    agents_paused: 1,
    calls_in_queue: 0,
    drop_percent: 0,
    raw: { source: 'playwright-fixture' },
    ...overrides,
  };
}
