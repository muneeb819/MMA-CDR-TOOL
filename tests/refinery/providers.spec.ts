import { existsSync } from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { test, expect } from '../fixtures/test.js';

test.describe('Verification provider utility (offline stubs only) @refinery @regression', () => {
  test('MockProvider and WaterfallVerifier preserve provider order, continue on timeout and weight consensus', () => {
    const localPython = process.platform === 'win32' ? path.resolve('.venv/Scripts/python.exe') : path.resolve('.venv/bin/python');
    const python = process.env.PYTHON || (existsSync(localPython) ? localPython : process.platform === 'win32' ? 'python' : 'python3');
    const output = execFileSync(python, ['tests/python/provider_contract.py'], {
      cwd: process.cwd(),
      encoding: 'utf8',
      timeout: 15_000,
      maxBuffer: 1024 * 1024,
    });
    const result = JSON.parse(output) as {
      mock: { provider: string; success: boolean; data: Record<string, unknown>; confidence: number };
      provider_order: string[];
      calls: string[];
      success: boolean[];
      consensus: Record<string, unknown>;
      confidence: number;
    };
    expect(result.mock).toMatchObject({ provider: 'mock', success: true, data: { line_type: 'unknown', reachable: null }, confidence: 0.25 });
    expect(result.provider_order).toEqual(['first', 'timeout', 'last']);
    expect(result.calls).toEqual([
      'first:+14155550132', 'timeout:+14155550132', 'last:+14155550132',
    ]);
    expect(result.success).toEqual([true, false, true]);
    expect(result.consensus).toEqual({ reachable: true, line_type: 'mobile' });
    expect(result.confidence).toBe(0.8);
  });
});
