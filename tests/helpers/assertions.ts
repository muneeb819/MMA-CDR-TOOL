import { expect, type APIResponse } from '@playwright/test';
import type { ScoreResponse } from './types.js';

export async function assertApiSuccess(response: APIResponse, status = 200): Promise<void> {
  expect(response.status(), await response.text()).toBe(status);
  expect(response.headers()['content-type']).toContain('application/json');
}

export async function assertApiError(response: APIResponse, status: number): Promise<Record<string, unknown>> {
  expect(response.status()).toBe(status);
  const body = await response.json() as Record<string, unknown>;
  expect(body).toHaveProperty('detail');
  return body;
}

export function assertDecision(result: ScoreResponse, decision: ScoreResponse['decision']): void {
  expect(result.decision).toBe(decision);
  expect(result.quality_score).toBeGreaterThanOrEqual(0);
  expect(result.quality_score).toBeLessThanOrEqual(100);
  expect(result.contactability_score).toBeGreaterThanOrEqual(0);
  expect(result.contactability_score).toBeLessThanOrEqual(100);
  expect(result.risk_score).toBeGreaterThanOrEqual(0);
  expect(result.risk_score).toBeLessThanOrEqual(100);
  expect(result.reasons.length).toBeGreaterThan(0);
  expect(result.ruleset_version).toBeTruthy();
  expect(result.model_version).toBeTruthy();
}
