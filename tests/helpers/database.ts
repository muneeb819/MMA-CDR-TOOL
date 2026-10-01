import { existsSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import sql from 'mssql';
import type { config as SqlConfig, ConnectionPool } from 'mssql';

export const SQLITE_PATH = path.resolve(process.env.MMA_CDR_SQLITE_PATH || 'test-results/mma-cdr-playwright.sqlite');

export function sqliteDatabaseAvailable(): boolean {
  return existsSync(SQLITE_PATH);
}

export function sqlServerTestConfig(): SqlConfig | null {
  if (process.env.RUN_SQLSERVER_TESTS !== '1') return null;
  const database = process.env.SQLSERVER_TEST_DATABASE || process.env.SQLSERVER_DATABASE;
  const server = process.env.SQLSERVER_HOST;
  const user = process.env.SQLSERVER_USER;
  const password = process.env.SQLSERVER_PASSWORD;
  if (!server || !user || !password || !database) return null;

  // Only a plainly designated test/QA database is allowed. Tests use rolled-back
  // transactions and never provision or delete databases.
  if (!/(?:^test[_-]|[_-](?:test|qa)$)/i.test(database)) {
    throw new Error('SQL Server integration tests are restricted to a dedicated database named with a test/qa suffix (for example mma_cdr_test).');
  }

  return {
    server,
    port: Number(process.env.SQLSERVER_PORT || 1433),
    database,
    user,
    password,
    connectionTimeout: 10_000,
    requestTimeout: 20_000,
    pool: { max: 3, min: 0, idleTimeoutMillis: 10_000 },
    options: {
      encrypt: !['0', 'false', 'no'].includes((process.env.SQLSERVER_ENCRYPT || 'no').toLowerCase()),
      trustServerCertificate: ['1', 'true', 'yes'].includes((process.env.SQLSERVER_TRUST_SERVER_CERTIFICATE || 'yes').toLowerCase()),
      enableArithAbort: true,
    },
  };
}

export function sqlServerIntegrationEnabled(): boolean {
  return Boolean(sqlServerTestConfig());
}

export async function openTestSqlServer(): Promise<ConnectionPool> {
  const config = sqlServerTestConfig();
  if (!config) {
    throw new Error('SQL Server tests are not configured. Set RUN_SQLSERVER_TESTS=1 and dedicated SQLSERVER_* test database values.');
  }
  const pool = new sql.ConnectionPool(config);
  return pool.connect();
}

export type SqliteRow = Record<string, string | number | null | boolean>;

export function sqliteUniqueRollbackProbe(tenantId: string, tenantKey: string): { duplicateRejected: boolean; rolledBack: boolean } {
  if (!sqliteDatabaseAvailable()) throw new Error(`The isolated SQLite test database is not available at ${SQLITE_PATH}.`);
  const python = pythonExecutable();
  const script = `import json, sqlite3, sys\np=json.load(sys.stdin)\nc=sqlite3.connect(p["path"], timeout=10)\nduplicate_rejected=False\nc.execute("BEGIN")\nc.execute("INSERT INTO tenants(tenant_id,tenant_key,name) VALUES(?,?,?)", (p["id"],p["key"],"QA rollback probe"))\ntry:\n c.execute("INSERT INTO tenants(tenant_id,tenant_key,name) VALUES(?,?,?)", (p["id"]+"-duplicate",p["key"],"QA duplicate probe"))\nexcept sqlite3.IntegrityError:\n duplicate_rejected=True\nc.rollback()\nrolled_back=c.execute("SELECT COUNT(*) FROM tenants WHERE tenant_id=? OR tenant_id=?", (p["id"],p["id"]+"-duplicate")).fetchone()[0] == 0\nprint(json.dumps({"duplicateRejected":duplicate_rejected,"rolledBack":rolled_back}))\nc.close()`;
  const result = spawnSync(python, ['-c', script], {
    cwd: process.cwd(), encoding: 'utf8', input: JSON.stringify({ path: SQLITE_PATH, id: tenantId, key: tenantKey }), maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) throw new Error(`SQLite rollback probe failed: ${(result.stderr || result.error?.message || '').slice(0, 1000)}`);
  return JSON.parse(result.stdout) as { duplicateRejected: boolean; rolledBack: boolean };
}

function pythonExecutable(): string {
  if (process.env.PYTHON) return process.env.PYTHON;
  const local = process.platform === 'win32' ? path.resolve('.venv/Scripts/python.exe') : path.resolve('.venv/bin/python');
  if (existsSync(local)) return local;
  return process.platform === 'win32' ? 'python' : 'python3';
}

export function querySqlite<T extends SqliteRow = SqliteRow>(query: string, params: unknown[] = []): T[] {
  if (!sqliteDatabaseAvailable()) {
    throw new Error(`The isolated SQLite test database is not available at ${SQLITE_PATH}.`);
  }
  const normalized = query.trim().toUpperCase();
  if (!(normalized.startsWith('SELECT ') || normalized.startsWith('PRAGMA '))) {
    throw new Error('querySqlite only accepts read-only SELECT or PRAGMA statements.');
  }

  const python = pythonExecutable();
  const script = [
    'import json, sqlite3, sys',
    'payload=json.load(sys.stdin)',
    'conn=sqlite3.connect(payload["path"], timeout=10)',
    'conn.row_factory=sqlite3.Row',
    'rows=[dict(row) for row in conn.execute(payload["query"], payload["params"]).fetchall()]',
    'print(json.dumps(rows, default=str))',
    'conn.close()',
  ].join('; ');
  const result = spawnSync(python, ['-c', script], {
    cwd: process.cwd(),
    encoding: 'utf8',
    input: JSON.stringify({ path: SQLITE_PATH, query, params }),
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const detail = (result.stderr || result.error?.message || 'unknown sqlite helper error').trim().slice(0, 1200);
    throw new Error(`SQLite test query failed: ${detail}`);
  }
  return JSON.parse(result.stdout) as T[];
}
