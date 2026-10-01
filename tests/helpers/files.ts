import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const fixtureDir = path.join(repoRoot, 'tests', 'fixtures');

export function fixture(name: string): Buffer {
  return readFileSync(path.join(fixtureDir, name));
}

export function largeCsv(recordCount: number): Buffer {
  const lines = ['name,phone'];
  for (let index = 1; index <= recordCount; index += 1) {
    lines.push(`Synthetic Test ${index},+14155550132`);
  }
  return Buffer.from(`${lines.join('\n')}\n`, 'utf8');
}

export function csvWithPhones(phones: string[]): Buffer {
  return Buffer.from(['name,phone', ...phones.map((phone, index) => `Synthetic Test ${index + 1},${phone}`)].join('\n') + '\n', 'utf8');
}
