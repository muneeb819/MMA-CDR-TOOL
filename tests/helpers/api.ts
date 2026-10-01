import { createHash } from 'node:crypto';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import type { PhoneUploadResult, TelemetryPayload } from './types.js';

export const API_URL = process.env.API_URL || 'http://127.0.0.1:8000';
export const TEST_TENANT_ID = process.env.TEST_TENANT_ID || '00000000-0000-0000-0000-000000000001';
export const TEST_CAMPAIGN_ID = process.env.TEST_CAMPAIGN_ID || '22222222-2222-4222-8222-222222222222';

export async function getHealth(api: APIRequestContext) {
  const response = await api.get('/health');
  expectStatus(response, 200);
  return response.json() as Promise<{ status: string; version: string; database: string }>;
}

export async function uploadFile(
  api: APIRequestContext,
  filename: string,
  contents: string | Buffer,
  mimeType = mimeFor(filename),
  options: { tenantId?: string; campaignId?: string } = {},
): Promise<{ response: APIResponse; body: PhoneUploadResult }> {
  const response = await api.post('/api/v2/scrubber/upload', {
    multipart: {
      file: {
        name: filename,
        mimeType,
        buffer: Buffer.isBuffer(contents) ? contents : Buffer.from(contents, 'utf8'),
      },
      tenant_id: options.tenantId || TEST_TENANT_ID,
      ...(options.campaignId ? { campaign_id: options.campaignId } : {}),
    },
  });
  return { response, body: await response.json() as PhoneUploadResult };
}

export async function refinePhone(
  api: APIRequestContext,
  phone: string,
  options: Record<string, unknown> = {},
) {
  return api.post('/api/v2/refine', { data: { phone, ...options } });
}

export async function scorePhone(
  api: APIRequestContext,
  phone: string,
  options: Record<string, unknown> = {},
) {
  return api.post('/api/v2/score', { data: { phone, ...options } });
}

export function phoneFingerprint(e164: string): string {
  return createHash('sha256').update(e164, 'utf8').digest('hex');
}

export function validTelemetry(overrides: Partial<TelemetryPayload> = {}): TelemetryPayload {
  return {
    timestamp: '2025-01-15T12:00:00.000Z',
    tenant_id: TEST_TENANT_ID,
    source_url: 'https://vicidial.test/agc/vicidial.php',
    agents_logged_in: 10,
    agents_in_call: 4,
    agents_waiting: 2,
    agents_paused: 1,
    calls_in_queue: 0,
    drop_percent: 0,
    raw: { fixture: 'playwright' },
    ...overrides,
  };
}

export async function expectStatus(response: APIResponse, status: number): Promise<void> {
  if (response.status() !== status) {
    const contentType = response.headers()['content-type'] || '';
    const body = contentType.includes('json') ? JSON.stringify(await response.json()) : await response.text();
    throw new Error(`Expected HTTP ${status}, got ${response.status()}: ${body.slice(0, 1000)}`);
  }
}

export function mimeFor(filename: string): string {
  const ext = filename.toLowerCase().split('.').at(-1);
  const types: Record<string, string> = {
    csv: 'text/csv', tsv: 'text/tab-separated-values', txt: 'text/plain', log: 'text/plain',
    json: 'application/json', jsonl: 'application/x-ndjson', xml: 'application/xml',
    html: 'text/html', htm: 'text/html', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    xls: 'application/vnd.ms-excel', xlsb: 'application/vnd.ms-excel.sheet.binary.macroEnabled.12',
    ods: 'application/vnd.oasis.opendocument.spreadsheet', parquet: 'application/vnd.apache.parquet',
    pdf: 'application/pdf', docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    zip: 'application/zip', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', custom: 'application/octet-stream',
  };
  return types[ext || ''] || 'application/octet-stream';
}
