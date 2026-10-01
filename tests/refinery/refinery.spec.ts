import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test, expect } from '../fixtures/test.js';
import { API_URL, phoneFingerprint } from '../helpers/api.js';
import { phones } from '../helpers/test-data.js';

const rustSource = readFileSync(path.resolve('refinery/src/main.rs'), 'utf8');
const pythonSource = readFileSync(path.resolve('api/app.py'), 'utf8');
const rustURL = process.env.RUST_REFINERY_URL;

test.describe('Refinery implementation contracts @refinery @regression', () => {
  test('source exposes only the implemented Rust health, single and batch routes', () => {
    expect(rustSource).toContain('.route("/health", get(health))');
    expect(rustSource).toContain('.route("/v2/refine", post(refine))');
    expect(rustSource).toContain('.route("/v2/refine/batch", post(refine_batch))');
    expect(rustSource).toContain('fn normalize_us_phone');
    expect(rustSource).toContain('fn fingerprint');
    expect(rustSource).toContain('F_DUPLICATE');
    expect(rustSource).toContain('F_DNC');
    expect(pythonSource).toContain('@app.post("/api/v2/refine")');
    expect(pythonSource).toContain('def normalize_us_phone');
    expect(pythonSource).toContain('req.suppressed_hashes');
  });

  test('Python inline refinement emits a deterministic SHA-256 and same canonical phone', async ({ request }) => {
    const url = new URL('/api/v2/refine', API_URL).toString();
    const response = await request.post(url, { data: { phone: phones.formatted } });
    expect(response.status()).toBe(200);
    expect(await response.json()).toMatchObject({
      normalized_phone: phones.e164,
      fingerprint: phoneFingerprint(phones.e164),
      flags: 0,
      decision: 'PASS',
    });
  });

  test('optional Rust service passes representative batch normalization and within-batch dedupe parity', async ({ request }) => {
    test.skip(!rustURL, 'Rust integration is optional; set RUST_REFINERY_URL or start it with PW_START_RUST=1 and Cargo installed.');
    const health = await request.get(new URL('/health', rustURL).toString());
    expect(health.status()).toBe(200);
    expect(await health.text()).toBe('ok');

    const syntheticSuffix = String(Number.parseInt(randomUUID().replaceAll('-', '').slice(0, 8), 16) % 100).padStart(2, '0');
    const canonical = `+141555501${syntheticSuffix}`;
    const rust = await request.post(new URL('/v2/refine/batch', rustURL).toString(), {
      data: {
        records: [
          { lead_id: 'qa-rust-1', phone: canonical },
          { lead_id: 'qa-rust-2', phone: canonical.slice(2) },
          { lead_id: 'qa-rust-3', phone: '12345' },
        ],
      },
    });
    expect(rust.status()).toBe(200);
    const result = await rust.json() as { results: Array<Record<string, unknown>> };
    expect(result.results).toHaveLength(3);
    expect(result.results.map(row => row.normalized_phone)).toEqual([canonical, canonical, null]);
    expect(result.results.map(row => row.decision)).toEqual(['PASS', 'DUPLICATE', 'INVALID']);

    const python = await request.post(new URL('/api/v2/refine', API_URL).toString(), {
      data: { phone: canonical },
    });
    const pythonResult = await python.json();
    expect(pythonResult.normalized_phone).toBe(result.results[0].normalized_phone);
    expect(pythonResult.decision).toBe(result.results[0].decision);
  });
});
