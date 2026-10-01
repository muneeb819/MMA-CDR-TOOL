import { spawn } from 'node:child_process';
import { basename, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const host = process.env.API_HOST || '0.0.0.0';
const port = process.env.API_PORT || '8000';
const sqlitePath = resolve(root, process.env.MMA_CDR_SQLITE_PATH || 'test-results/mma-cdr-playwright.sqlite');
const relativePath = relative(root, sqlitePath).replaceAll('\\', '/');
const safeName = /(?:test|qa)[^/]*\.(?:sqlite|sqlite3|db)$/i.test(basename(sqlitePath));
const safeDirectory = relativePath.startsWith('test-results/') || relativePath.startsWith('tests/.artifacts/');

if (process.env.MMA_CDR_USE_SQLITE !== '1') {
  console.error('Refusing to start the test API without MMA_CDR_USE_SQLITE=1.');
  process.exit(2);
}
if (!safeDirectory && !safeName) {
  console.error('Refusing to use a non-test SQLite path. Set MMA_CDR_SQLITE_PATH to a dedicated test-results or tests/.artifacts database.');
  process.exit(2);
}

const child = spawn(python, ['-m', 'uvicorn', 'api.app:app', '--host', host, '--port', port], {
  cwd: root,
  env: process.env,
  stdio: 'inherit',
});

const forward = signal => {
  if (child.exitCode === null) child.kill(signal);
};
process.on('SIGINT', () => forward('SIGINT'));
process.on('SIGTERM', () => forward('SIGTERM'));
child.on('error', error => {
  console.error(`Unable to start FastAPI with the configured Python interpreter (${python}): ${error.message}`);
  process.exitCode = 1;
});
child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
