"""MMA-CDR TOOL database layer.

Primary: Microsoft SQL Server via SQLAlchemy + pyodbc (SSMS script in database/mma-cdr-sqlserver.sql).
Fallback: local SQLite ./mma-cdr.db for dev/demo when SQL Server is unreachable.
"""
from __future__ import annotations
import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote_plus

USE_SQLITE = os.getenv("MMA_CDR_USE_SQLITE", "").lower() in ("1", "true", "yes")
SQLITE_PATH = Path(os.getenv("MMA_CDR_SQLITE_PATH", "./mma-cdr.db"))

_engine = None
_backend = "unknown"


def _sqlserver_url() -> str:
    explicit = os.getenv("SQLSERVER_CONNECTION_STRING", "").strip()
    if explicit:
        if explicit.startswith("mssql"):
            return explicit
        return "mssql+pyodbc:///?odbc_connect=" + quote_plus(explicit)
    driver = os.getenv("SQLSERVER_DRIVER", "ODBC Driver 18 for SQL Server")
    host = os.getenv("SQLSERVER_HOST", "localhost")
    port = os.getenv("SQLSERVER_PORT", "1433")
    database = os.getenv("SQLSERVER_DATABASE", "CDR_Intelligence")
    user = os.getenv("SQLSERVER_USER", "")
    password = os.getenv("SQLSERVER_PASSWORD", "")
    encrypt = os.getenv("SQLSERVER_ENCRYPT", "no")
    trust = os.getenv("SQLSERVER_TRUST_SERVER_CERTIFICATE", "yes")
    if user:
        odbc = f"DRIVER={{{driver}}};SERVER={host},{port};DATABASE={database};UID={user};PWD={password};Encrypt={encrypt};TrustServerCertificate={trust};"
    else:
        odbc = f"DRIVER={{{driver}}};SERVER={host},{port};DATABASE={database};Trusted_Connection=yes;Encrypt={encrypt};TrustServerCertificate={trust};"
    return "mssql+pyodbc:///?odbc_connect=" + quote_plus(odbc)


def get_engine():
    global _engine, _backend
    if _engine is not None:
        return _engine, _backend
    if not USE_SQLITE:
        try:
            from sqlalchemy import create_engine
            url = _sqlserver_url()
            eng = create_engine(
                url,
                pool_pre_ping=True,
                pool_recycle=int(os.getenv("SQLSERVER_POOL_RECYCLE", "1800")),
                pool_size=int(os.getenv("SQLSERVER_POOL_SIZE", "5")),
                max_overflow=int(os.getenv("SQLSERVER_MAX_OVERFLOW", "10")),
                fast_executemany=True,
                connect_args={"timeout": 5},
            )
            with eng.connect() as c:
                c.exec_driver_sql("SELECT 1")
            _engine = eng
            _backend = "sqlserver"
            return _engine, _backend
        except Exception:
            pass
    _engine = _init_sqlite()
    _backend = "sqlite"
    return _engine, _backend


SQLITE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tenants(tenant_id TEXT PRIMARY KEY, tenant_key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS campaigns(campaign_id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, campaign_key TEXT NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS upload_batches(upload_batch_id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, campaign_id TEXT, original_file_name TEXT NOT NULL, detected_extension TEXT, detected_mime_type TEXT, file_size_bytes INTEGER NOT NULL DEFAULT 0, sha256_hex TEXT, status TEXT NOT NULL DEFAULT 'RECEIVED', total_records INTEGER NOT NULL DEFAULT 0, accepted_records INTEGER NOT NULL DEFAULT 0, rejected_records INTEGER NOT NULL DEFAULT 0, extracted_phone_count INTEGER NOT NULL DEFAULT 0, error_message TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')), completed_at TEXT);
CREATE TABLE IF NOT EXISTS raw_records(raw_record_id INTEGER PRIMARY KEY AUTOINCREMENT, upload_batch_id TEXT NOT NULL, source_row_number INTEGER, source_locator TEXT, raw_text TEXT, normalized_phone TEXT, fingerprint_sha256 TEXT, parse_status TEXT NOT NULL DEFAULT 'EXTRACTED', created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS telemetry_snapshots(telemetry_id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id TEXT, campaign_id TEXT, observed_at TEXT NOT NULL, source_url TEXT, agents_logged_in INTEGER NOT NULL DEFAULT 0, agents_in_call INTEGER NOT NULL DEFAULT 0, agents_waiting INTEGER NOT NULL DEFAULT 0, agents_paused INTEGER NOT NULL DEFAULT 0, calls_in_queue INTEGER NOT NULL DEFAULT 0, drop_percent REAL NOT NULL DEFAULT 0, dial_level REAL, raw_payload TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS alerts(alert_id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id TEXT, campaign_id TEXT, telemetry_id INTEGER, severity TEXT NOT NULL, alert_type TEXT NOT NULL, message TEXT NOT NULL, evidence TEXT, status TEXT NOT NULL DEFAULT 'OPEN', created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS decisions(decision_id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id TEXT NOT NULL, campaign_id TEXT, phone TEXT, decision_code TEXT NOT NULL, quality_score REAL, contactability_score REAL, risk_score REAL, confidence REAL, compliance_status TEXT, reasons TEXT, ruleset_version TEXT, model_version TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')));
"""


def _init_sqlite():
    import sqlite3
    SQLITE_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(SQLITE_PATH))
    conn.executescript(SQLITE_SCHEMA)
    conn.execute("INSERT OR IGNORE INTO tenants(tenant_id, tenant_key, name) VALUES('00000000-0000-0000-0000-000000000001','default','Default Tenant')")
    conn.commit()
    conn.close()

    class LiteEngine:
        def begin(self):
            return _LiteConn(str(SQLITE_PATH))
    return LiteEngine()


class _LiteConn:
    def __init__(self, path: str):
        self.path = path
        self.conn = None
    def __enter__(self):
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        return _LiteCursor(self.conn)
    def __exit__(self, *exc):
        try:
            if exc[0] is None:
                self.conn.commit()
            else:
                self.conn.rollback()
        finally:
            self.conn.close()


class _LiteCursor:
    def __init__(self, conn):
        self.conn = conn
        self._rows = []
    def execute(self, sql, params=None):
        q = str(sql).replace(":tenant_id", ":tenant_id")
        # Convert named :param to ?-style is handled by sqlite via dict
        # SQLAlchemy text() objects stringify; do manual replace for text() wrapper
        s = str(sql)
        if "text(" in s or ":tenant_id" in s:
            pass
        # sqlite3 supports :name params directly when sql is str
        cur = self.conn.execute(str(sql) if not hasattr(sql, "text") else sql.text, params or {})
        try:
            rows = cur.fetchall()
            self._rows = [dict(r) for r in rows]
        except Exception:
            self._rows = []
        self._lastrowid = cur.lastrowid
        return self
    def scalar_one(self):
        return self._rows[0][list(self._rows[0].keys())[0]] if self._rows else None
    def mappings(self):
        class M:
            def __init__(self, rows): self.rows = rows
            def one(self): return self.rows[0] if self.rows else {}
            def all(self): return self.rows
        return M(self._rows)


@contextmanager
def db():
    engine, backend = get_engine()
    if backend == "sqlserver":
        with engine.begin() as conn:
            yield conn, backend
    else:
        with engine.begin() as conn:
            yield conn, backend


def ping() -> dict:
    engine, backend = get_engine()
    if backend == "sqlserver":
        with engine.begin() as conn:
            conn.exec_driver_sql("SELECT 1")
        return {"backend": backend, "ok": True}
    else:
        c = sqlite3.connect(str(SQLITE_PATH))
        c.execute("SELECT 1")
        c.close()
        return {"backend": backend, "ok": True}


def backend_name() -> str:
    _, b = get_engine()
    return b
