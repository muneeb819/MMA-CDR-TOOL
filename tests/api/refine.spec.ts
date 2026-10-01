import { test, expect } from '../fixtures/test.js';
import { phoneFingerprint, refinePhone } from '../helpers/api.js';
import type { ScoreResponse } from '../helpers/types.js';
import { assertDecision } from '../helpers/assertions.js';

test.describe('Normalize and refine @api @refinery @regression', () => {
  test('equivalent US formats normalize to the same E.164 and SHA-256 fingerprint @smoke', async ({ api }) => {
    const formatted = await refinePhone(api, '+1 (415) 555-0132');
    const dashed = await refinePhone(api, '415-555-0132');
    expect(formatted.status()).toBe(200);
    expect(dashed.status()).toBe(200);
    const first = await formatted.json();
    const second = await dashed.json();
    expect(first).toMatchObject({ normalized_phone: '+14155550132', decision: 'PASS', flags: 0 });
    expect(second.normalized_phone).toBe(first.normalized_phone);
    expect(second.fingerprint).toBe(first.fingerprint);
    expect(first.fingerprint).toBe(phoneFingerprint('+14155550132'));
  });

  test('same normalized phone has stable fingerprint and different phones do not collide @regression', async ({ api }) => {
    const first = await (await refinePhone(api, '+1 212 555 0111')).json();
    const second = await (await refinePhone(api, '+1 310 555 0123')).json();
    expect(first.fingerprint).toBe(phoneFingerprint('+12125550111'));
    expect(second.fingerprint).toBe(phoneFingerprint('+13105550123'));
    expect(first.fingerprint).not.toBe(second.fingerprint);
  });

  test('only the implemented ten-digit or leading-1 eleven-digit US forms normalize', async ({ api }) => {
    const invalid = await refinePhone(api, '+44 20 7946 0000');
    expect(invalid.status()).toBe(200);
    expect(await invalid.json()).toMatchObject({ normalized_phone: null, decision: 'INVALID', flags: 1 });
  });

  test('client-supplied suppression fingerprint is checked after normalization @suppression @security', async ({ api }) => {
    const hash = phoneFingerprint('+14155550132');
    const response = await refinePhone(api, '415-555-0132', { suppressed_hashes: [hash] });
    expect(response.status()).toBe(200);
    expect(await response.json()).toMatchObject({
      normalized_phone: '+14155550132',
      fingerprint: hash,
      decision: 'SUPPRESS',
      flags: 2,
      reasons: ['Suppression match'],
    });
  });

  test('short duration is a reason signal but does not change the current PASS decision', async ({ api }) => {
    const response = await refinePhone(api, '+14155550132', { duration_seconds: 5 });
    const body = await response.json();
    expect(body.decision).toBe('PASS');
    expect(body.reasons).toContain('Short-duration event; requires disposition-aware interpretation');
  });

  test('missing and incorrectly typed phone fields are rejected by the request schema @security', async ({ api }) => {
    for (const payload of [{}, { phone: 4155550132 }, { phone: null }]) {
      const response = await api.post('/api/v2/refine', { data: payload });
      expect(response.status()).toBe(422);
    }
  });
});

test.describe('Lead scoring @api @scoring @regression', () => {
  test('valid reachable fresh lead follows the exact CALL path @smoke', async ({ api }) => {
    const response = await api.post('/api/v2/score', {
      data: { phone: '+1 (415) 555-0132', reachable: true, freshness_days: 0, attempts: 0, answered: 0 },
    });
    expect(response.status()).toBe(200);
    const result = await response.json() as ScoreResponse;
    assertDecision(result, 'CALL');
    expect(result).toMatchObject({ normalized_phone: '+14155550132', quality_score: 100, contactability_score: 75, risk_score: 0, compliance_status: 'PASS' });
    expect(result.fingerprint).toBe(phoneFingerprint('+14155550132'));
  });

  test('invalid numbers follow INVALID and include actual score fields', async ({ api }) => {
    const response = await api.post('/api/v2/score', { data: { phone: '12345' } });
    expect(response.status()).toBe(200);
    const result = await response.json() as ScoreResponse;
    assertDecision(result, 'INVALID');
    expect(result).toMatchObject({ quality_score: 0, contactability_score: 0, risk_score: 0, confidence: 0.99, compliance_status: 'UNKNOWN' });
    expect(result.reasons).toEqual(['Structural phone validation failed']);
  });

  test('freshness uses the implemented strict 180- and 365-day comparisons', async ({ api }) => {
    const at180 = await (await api.post('/api/v2/score', { data: { phone: '+14155550132', reachable: true, freshness_days: 180 } })).json() as ScoreResponse;
    const at181 = await (await api.post('/api/v2/score', { data: { phone: '+12125550111', reachable: true, freshness_days: 181 } })).json() as ScoreResponse;
    const at365 = await (await api.post('/api/v2/score', { data: { phone: '+13105550123', reachable: true, freshness_days: 365 } })).json() as ScoreResponse;
    const at366 = await (await api.post('/api/v2/score', { data: { phone: '+14155550132', reachable: true, freshness_days: 366 } })).json() as ScoreResponse;
    expect([at180.quality_score, at181.quality_score, at365.quality_score, at366.quality_score]).toEqual([100, 85, 85, 70]);
    expect(at181.reasons).toContain('Data is aging');
    expect(at366.reasons).toContain('Data is older than one year');
  });

  test('zero attempts, answered history, unreachable provider, and repeated unanswered attempts use source scoring rules', async ({ api }) => {
    const noHistory = await (await api.post('/api/v2/score', { data: { phone: '+14155550132' } })).json() as ScoreResponse;
    const answered = await (await api.post('/api/v2/score', { data: { phone: '+12125550111', attempts: 1, answered: 1 } })).json() as ScoreResponse;
    const unreachable = await (await api.post('/api/v2/score', { data: { phone: '+13105550123', reachable: false } })).json() as ScoreResponse;
    const repeatNoAnswer = await (await api.post('/api/v2/score', { data: { phone: '+14155550132', attempts: 10, answered: 0 } })).json() as ScoreResponse;
    assertDecision(noHistory, 'REVIEW');
    assertDecision(answered, 'CALL');
    assertDecision(unreachable, 'REVIEW');
    assertDecision(repeatNoAnswer, 'REVIEW');
    expect(answered.contactability_score).toBe(75);
    expect(repeatNoAnswer.reasons).toContain('No successful contacts across repeated historical attempts');
  });

  test('risk signals contribute to risk score and are returned as reasons @security', async ({ api }) => {
    const response = await api.post('/api/v2/score', {
      data: { phone: '+14155550132', reachable: true, risk_signals: ['velocity', 'source-risk', 'disposition'] },
    });
    expect(response.status()).toBe(200);
    const body = await response.json() as ScoreResponse;
    expect(body.risk_score).toBe(36);
    expect(body.reasons).toEqual(expect.arrayContaining([
      'Risk signal: velocity', 'Risk signal: source-risk', 'Risk signal: disposition',
    ]));
  });

  test('malformed JSON, wrong content type, and invalid tenant GUID fail with 422 @security', async ({ api }) => {
    const malformed = await api.post('/api/v2/score', { data: '{', headers: { 'content-type': 'application/json' } });
    const wrongType = await api.post('/api/v2/score', { data: 'phone=4155550132', headers: { 'content-type': 'text/plain' } });
    const invalidTenant = await api.post('/api/v2/score', { data: { phone: '+14155550132', tenant_id: "x'; DROP TABLE leads;--" } });
    expect(malformed.status()).toBe(422);
    expect(wrongType.status()).toBe(422);
    expect(invalidTenant.status()).toBe(422);
    expect((await invalidTenant.json()).detail).toContain('tenant_id must be a GUID');
  });

  test('XSS-like, SQL-like, Unicode, and null-byte phone inputs do not become CALL decisions @security', async ({ api }) => {
    const values = [
      '<img src=x onerror=alert(1)>',
      "' OR 1=1 --",
      '☏ 电话 ٤١٥٥٥٥٠١٣٢',
      '\u0000',
    ];
    for (const phone of values) {
      const response = await api.post('/api/v2/score', { data: { phone } });
      expect(response.status()).toBe(200);
      const result = await response.json() as ScoreResponse;
      expect(result.decision).toBe('INVALID');
    }
  });
});
