import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const reportPath = path.join(root, 'test-results', 'qa-summary.md');

try {
  process.stdout.write(await readFile(reportPath, 'utf8'));
} catch (error) {
  if (error?.code === 'ENOENT') {
    console.error('No QA summary exists yet. Run `npm run test:all` to generate test-results/qa-summary.md.');
    process.exitCode = 1;
  } else {
    throw error;
  }
}
