"""MMA-CDR TOOL API — hardened FastAPI over SQL Server (primary) + SQLite (dev fallback)."""
import asyncio
import json
import os
import re
import time
import uuid
from collections import defaultdict, deque
from datetime import datetime, timezone
from hashlib import sha256
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .ingestion import extract_phones, sha256_bytes, extension
from .scoring import score_record, HistoricalStats, phone_fingerprint
from .logging_setup import get_logger, log_event

logger = get_logger()

try:
    from sqlalchemy import text as sa_text
    HAS_SA = True
except Exception:
    HAS_SA = False
    def sa_text(s: str):  # minimal shim for sqlite path
        class T:
            def __init__(self, t): self.text = t
            def __str__(self): return self.text
        return T(s)

from . import db as dblib

app = FastAPI(title="MMA-CDR TOOL API", version="3.0.0")
origins = [x.strip() for x in os.getenv("WSS_ALLOWED_ORIGINS", "*").split(",")]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins if origins != ["*"] else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

history: dict[str, deque] = defaultdict(lambda: deque(maxlen=120))
connections: set[WebSocket] = set()
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_MB", "256")) * 1024 * 1024
DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001"

logger.info("MMA-CDR TOOL API starting version=3.0.0")


@app.middleware("http")
async def log_requests(request, call_next):
    started = time.time()
    try:
        response = await call_next(request)
        ms = round((time.time() - started) * 1000, 1)
        log_event("http_request", {"method": request.method, "path": request.url.path,
                                   "query": str(request.url.query)},
                  {"status": response.status_code, "ms": ms})
        return response
    except Exception as exc:
        ms = round((time.time() - started) * 1000, 1)
        log_event("http_error", {"method": request.method, "path": request.url.path},
                  {"error": str(exc)[:500], "ms": ms})
        raise


class ClientLog(BaseModel):
    action: str
    detail: dict | list | str | None = None
    result: dict | list | str | None = None


@app.post("/api/v2/client-log")
async def client_log(entry: ClientLog):
    """Receives a UI click/result from the frontend and appends it to the log file."""
    log_event(f"ui:{entry.action}",
              entry.detail if isinstance(entry.detail, dict) else {"value": entry.detail},
              entry.result if isinstance(entry.result, (dict, str)) else {"value": entry.result})
    return {"ok": True}


class Telemetry(BaseModel):
    timestamp: str
    tenant_id: str | None = None
    campaign_id: str | None = None
    source_url: str
    agents_logged_in: int = Field(ge=0)
    agents_in_call: int = Field(ge=0)
    agents_waiting: int = Field(ge=0)
    agents_paused: int = Field(ge=0)
    calls_in_queue: int = Field(ge=0)
    drop_percent: float = Field(ge=0)
    dial_level: float | None = None
    raw: dict = {}


class RefineRequest(BaseModel):
    phone: str
    lead_id: str | None = None
    duration_seconds: int | None = None
    suppressed_hashes: list[str] = []


class ScoreRequest(BaseModel):
    phone: str
    tenant_id: str | None = None
    campaign_id: str | None = None
    reachable: bool | None = None
    freshness_days: float = 0
    attempts: int = 0
    answered: int = 0
    risk_signals: list[str] = []


def analyze(m: Telemetry):
    key = m.campaign_id or "default"
    h = history[key]
    previous = list(h)
    baseline = sum(x["drop_percent"] for x in previous[-30:]) / max(1, len(previous[-30:]))
    alerts = []
    if m.drop_percent > max(3.0, baseline * 1.8 if previous else 3.0):
        alerts.append({"severity": "CRITICAL", "type": "DROP_ANOMALY",
                       "message": f"Drop {m.drop_percent:.2f}% above baseline {baseline:.2f}%."})
    if m.calls_in_queue > 0 and m.agents_waiting == 0:
        alerts.append({"severity": "WARNING", "type": "QUEUE_SATURATION",
                       "message": f"{m.calls_in_queue} queued, no agents waiting."})
    if m.agents_logged_in and m.agents_paused / m.agents_logged_in > 0.4:
        alerts.append({"severity": "WARNING", "type": "PAUSED_AGENT_RATIO",
                       "message": f"Paused ratio {m.agents_paused / m.agents_logged_in:.1%}."})
    util = (m.agents_in_call / m.agents_logged_in * 100) if m.agents_logged_in else 0
    score = max(0, min(100, 100 - m.drop_percent * 10 - m.calls_in_queue * 2))
    h.append(m.model_dump())
    return {"status": "ACTION_REQUIRED" if alerts else "HEALTHY",
            "efficiency_score": round(score, 1), "utilization_percent": round(util, 1),
            "historical_drop_baseline": round(baseline, 3), "alerts": alerts,
            "observed_at": time.time()}


def _uid(v: str | None):
    return v or None


def _as_uuid(value: str | None, field: str) -> str | None:
    """Strict GUID validation for HTTP endpoints — 422 instead of a SQL 500."""
    if not value:
        return None
    try:
        return str(uuid.UUID(str(value).strip()))
    except ValueError:
        raise HTTPException(status_code=422, detail=f"{field} must be a GUID, got {value!r}")


def _uuid_or_none(value: str | None) -> str | None:
    """Lenient coercion for fire-and-forget paths (WebSocket): bad GUIDs become NULL."""
    if not value:
        return None
    try:
        return str(uuid.UUID(str(value).strip()))
    except ValueError:
        return None


def persist_telemetry(m: Telemetry, result: dict) -> None:
    observed = datetime.fromisoformat(m.timestamp.replace("Z", "+00:00"))
    with dblib.db() as (conn, backend):
        if backend == "sqlserver":
            row = conn.execute(sa_text("""
                INSERT dbo.telemetry_snapshots(tenant_id,campaign_id,observed_at,source_url,agents_logged_in,agents_in_call,agents_waiting,agents_paused,calls_in_queue,drop_percent,dial_level,raw_payload)
                OUTPUT INSERTED.telemetry_id
                VALUES(:tenant_id,:campaign_id,:observed_at,:source_url,:agents_logged_in,:agents_in_call,:agents_waiting,:agents_paused,:calls_in_queue,:drop_percent,:dial_level,:raw_payload)
            """), {"tenant_id": _uuid_or_none(m.tenant_id), "campaign_id": _uuid_or_none(m.campaign_id), "observed_at": observed,
                   "source_url": m.source_url, "agents_logged_in": m.agents_logged_in, "agents_in_call": m.agents_in_call,
                   "agents_waiting": m.agents_waiting, "agents_paused": m.agents_paused, "calls_in_queue": m.calls_in_queue,
                   "drop_percent": m.drop_percent, "dial_level": m.dial_level,
                   "raw_payload": json.dumps({"telemetry": m.model_dump(), "analysis": result})}).scalar_one()
            for a in result["alerts"]:
                conn.execute(sa_text("""INSERT dbo.alerts(tenant_id,campaign_id,telemetry_id,severity,alert_type,message,evidence)
                    VALUES(:tenant_id,:campaign_id,:telemetry_id,:severity,:alert_type,:message,:evidence)"""),
                    {"tenant_id": _uuid_or_none(m.tenant_id), "campaign_id": _uuid_or_none(m.campaign_id), "telemetry_id": row,
                     "severity": a["severity"], "alert_type": a["type"], "message": a["message"], "evidence": json.dumps(result)})
        else:
            cur = conn.execute(sa_text("""INSERT INTO telemetry_snapshots(tenant_id,campaign_id,observed_at,source_url,agents_logged_in,agents_in_call,agents_waiting,agents_paused,calls_in_queue,drop_percent,dial_level,raw_payload)
                VALUES(:tenant_id,:campaign_id,:observed_at,:source_url,:agents_logged_in,:agents_in_call,:agents_waiting,:agents_paused,:calls_in_queue,:drop_percent,:dial_level,:raw_payload)"""),
                {"tenant_id": m.tenant_id, "campaign_id": m.campaign_id, "observed_at": observed.isoformat(), "source_url": m.source_url,
                 "agents_logged_in": m.agents_logged_in, "agents_in_call": m.agents_in_call, "agents_waiting": m.agents_waiting,
                 "agents_paused": m.agents_paused, "calls_in_queue": m.calls_in_queue, "drop_percent": m.drop_percent,
                 "dial_level": m.dial_level, "raw_payload": json.dumps(result)})
            tid = conn._lastrowid if hasattr(conn, "_lastrowid") else 0
            for a in result["alerts"]:
                conn.execute(sa_text("""INSERT INTO alerts(tenant_id,campaign_id,telemetry_id,severity,alert_type,message,evidence)
                    VALUES(:tenant_id,:campaign_id,:telemetry_id,:severity,:alert_type,:message,:evidence)"""),
                    {"tenant_id": m.tenant_id, "campaign_id": m.campaign_id, "telemetry_id": tid,
                     "severity": a["severity"], "alert_type": a["type"], "message": a["message"], "evidence": json.dumps(result)})


US_PHONE_DIGITS = re.compile(r"\D")


def normalize_us_phone(raw: str) -> str | None:
    d = US_PHONE_DIGITS.sub("", raw or "")
    if len(d) == 11 and d.startswith("1"):
        return "+" + d
    if len(d) == 10:
        return "+1" + d
    return None


@app.get("/health")
async def health():
    try:
        info = await asyncio.to_thread(dblib.ping)
        return {"status": "ok", "version": app.version, "database": info["backend"]}
    except Exception as exc:
        return {"status": "degraded", "version": app.version, "database": "unavailable", "error": str(exc)}


@app.post("/api/v2/telemetry")
async def telemetry(m: Telemetry):
    m.tenant_id = _as_uuid(m.tenant_id, "tenant_id")
    m.campaign_id = _as_uuid(m.campaign_id, "campaign_id")
    result = analyze(m)
    try:
        await asyncio.to_thread(persist_telemetry, m, result)
    except Exception as exc:
        result["persist_warning"] = str(exc)[:500]
    log_event("api:telemetry", {"campaign_id": m.campaign_id, "drop": m.drop_percent, "queue": m.calls_in_queue},
              {"status": result.get("status"), "alerts": len(result.get("alerts", []))})
    return result


@app.get("/api/v2/campaigns/{campaign_id}/summary")
async def campaign_summary(campaign_id: str):
    campaign_id = _as_uuid(campaign_id, "campaign_id")
    def q():
        with dblib.db() as (conn, backend):
            if backend == "sqlserver":
                return dict(conn.execute(sa_text("""
                    SELECT COUNT_BIG(*) samples, AVG(CAST(drop_percent AS FLOAT)) avg_drop_percent,
                           AVG(CAST(calls_in_queue AS FLOAT)) avg_queue
                    FROM dbo.telemetry_snapshots WHERE campaign_id=:campaign_id
                """), {"campaign_id": campaign_id}).mappings().one())
            rows = conn.execute(sa_text("SELECT COUNT(*) samples, AVG(drop_percent) avg_drop_percent, AVG(calls_in_queue) avg_queue FROM telemetry_snapshots WHERE campaign_id=:campaign_id"),
                                {"campaign_id": campaign_id}).mappings().all()
            return rows[0] if rows else {"samples": 0, "avg_drop_percent": 0, "avg_queue": 0}
    row = await asyncio.to_thread(q)
    return {"campaign_id": campaign_id, "samples": int(row.get("samples") or 0),
            "avg_drop_percent": round(float(row.get("avg_drop_percent") or 0), 3),
            "avg_queue": round(float(row.get("avg_queue") or 0), 3)}


@app.get("/api/v2/telemetry/recent")
async def telemetry_recent(limit: int = 20):
    limit = max(1, min(100, limit))
    def q():
        with dblib.db() as (conn, backend):
            if backend == "sqlserver":
                rows = conn.execute(sa_text(f"SELECT TOP {limit} * FROM dbo.telemetry_snapshots ORDER BY telemetry_id DESC")).mappings().all()
                return [dict(r) for r in rows]
            rows = conn.execute(sa_text(f"SELECT * FROM telemetry_snapshots ORDER BY telemetry_id DESC LIMIT {limit}")).mappings().all()
            return rows
    return {"items": await asyncio.to_thread(q)}


@app.get("/api/v2/uploads/recent")
async def uploads_recent(limit: int = 20):
    limit = max(1, min(100, limit))
    def q():
        with dblib.db() as (conn, backend):
            if backend == "sqlserver":
                rows = conn.execute(sa_text(f"SELECT TOP {limit} upload_batch_id, tenant_id, original_file_name, detected_extension, file_size_bytes, status, total_records, extracted_phone_count, created_at FROM dbo.upload_batches ORDER BY created_at DESC")).mappings().all()
                return [{**dict(r), "upload_batch_id": str(r["upload_batch_id"])} for r in rows]
            rows = conn.execute(sa_text(f"SELECT * FROM upload_batches ORDER BY created_at DESC LIMIT {limit}")).mappings().all()
            return rows
    return {"items": await asyncio.to_thread(q)}


@app.post("/api/v2/refine")
async def refine(req: RefineRequest):
    e164 = normalize_us_phone(req.phone)
    if not e164:
        return {"phone": req.phone, "normalized_phone": None, "flags": 1, "decision": "INVALID", "reasons": ["Phone normalization failed"]}
    fp = phone_fingerprint(e164)
    if fp in (req.suppressed_hashes or []):
        return {"phone": req.phone, "normalized_phone": e164, "fingerprint": fp, "flags": 2, "decision": "SUPPRESS", "reasons": ["Suppression match"]}
    reasons = []
    if req.duration_seconds is not None and req.duration_seconds < 6:
        reasons.append("Short-duration event; requires disposition-aware interpretation")
    return {"phone": req.phone, "normalized_phone": e164, "fingerprint": fp, "flags": 0, "decision": "PASS", "reasons": reasons or ["No material negative signals"]}


@app.post("/api/v2/score")
async def score(req: ScoreRequest):
    req.tenant_id = _as_uuid(req.tenant_id, "tenant_id") or DEFAULT_TENANT
    req.campaign_id = _as_uuid(req.campaign_id, "campaign_id")
    e164 = normalize_us_phone(req.phone)
    if not e164:
        result = score_record(valid=False, suppressed=False, duplicate=False, reachable=None, freshness_days=req.freshness_days, stats=HistoricalStats())
    else:
        result = score_record(valid=True, suppressed=False, duplicate=False, reachable=req.reachable,
                              freshness_days=req.freshness_days,
                              stats=HistoricalStats(attempts=req.attempts, answered=req.answered),
                              risk_signals=req.risk_signals)
        result["normalized_phone"] = e164
        result["fingerprint"] = phone_fingerprint(e164)
    try:
        with dblib.db() as (conn, backend):
            if backend == "sqlserver":
                conn.execute(sa_text("""INSERT dbo.decisions(tenant_id,campaign_id,decision_code,quality_score,contactability_score,risk_score,confidence,compliance_status,reasons,ruleset_version,model_version)
                    VALUES(:t,:c,:d,:q,:ct,:r,:cf,:cs,:re,:rv,:mv)"""),
                    {"t": req.tenant_id or DEFAULT_TENANT, "c": req.campaign_id, "d": result["decision"], "q": result["quality_score"],
                     "ct": result["contactability_score"], "r": result["risk_score"], "cf": result["confidence"],
                     "cs": result["compliance_status"], "re": "\n".join(result["reasons"]), "rv": result["ruleset_version"], "mv": result["model_version"]})
            else:
                conn.execute(sa_text("""INSERT INTO decisions(tenant_id,campaign_id,phone,decision_code,quality_score,contactability_score,risk_score,confidence,compliance_status,reasons,ruleset_version,model_version)
                    VALUES(:t,:c,:p,:d,:q,:ct,:r,:cf,:cs,:re,:rv,:mv)"""),
                    {"t": req.tenant_id or DEFAULT_TENANT, "c": req.campaign_id, "p": e164 or req.phone, "d": result["decision"], "q": result["quality_score"],
                     "ct": result["contactability_score"], "r": result["risk_score"], "cf": result["confidence"],
                     "cs": result["compliance_status"], "re": "\n".join(result["reasons"]), "rv": result["ruleset_version"], "mv": result["model_version"]})
    except Exception as exc:
        result["persist_warning"] = str(exc)[:500]
    log_event("api:score", {"phone": (e164 or req.phone)[:8] + "***"},
              {"decision": result.get("decision"), "quality": result.get("quality_score")})
    return result


@app.post("/api/v2/scrubber/upload")
async def scrubber_upload(file: UploadFile = File(...), tenant_id: str = Form(DEFAULT_TENANT), campaign_id: str | None = Form(None)):
    tenant_id = _as_uuid(tenant_id, "tenant_id") or DEFAULT_TENANT
    campaign_id = _as_uuid(campaign_id, "campaign_id")
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail=f"File exceeds MAX_UPLOAD_MB")
    name = file.filename or "unnamed"
    digest = sha256_bytes(data)
    ext = extension(name)
    mime = file.content_type or "application/octet-stream"
    batch_id = str(uuid.uuid4())

    def persist_batch():
        with dblib.db() as (conn, backend):
            if backend == "sqlserver":
                bid = conn.execute(sa_text("""
                    INSERT dbo.upload_batches(tenant_id,campaign_id,original_file_name,detected_extension,detected_mime_type,file_size_bytes,sha256_hex,status)
                    OUTPUT INSERTED.upload_batch_id VALUES(:t,:c,:n,:e,:m,:s,:h,:st)"""),
                    {"t": tenant_id, "c": campaign_id or None, "n": name, "e": ext, "m": mime, "s": len(data), "h": digest, "st": "PROCESSING"}).scalar_one()
                return str(bid)
            conn.execute(sa_text("""INSERT INTO upload_batches(upload_batch_id,tenant_id,campaign_id,original_file_name,detected_extension,detected_mime_type,file_size_bytes,sha256_hex,status)
                VALUES(:b,:t,:c,:n,:e,:m,:s,:h,:st)"""),
                {"b": batch_id, "t": tenant_id, "c": campaign_id, "n": name, "e": ext, "m": mime, "s": len(data), "h": digest, "st": "PROCESSING"})
            return batch_id

    batch_id = await asyncio.to_thread(persist_batch)
    try:
        extracted = await asyncio.to_thread(extract_phones, name, data)
        phones: list[str] = extracted["phones"]

        def persist_phones():
            with dblib.db() as (conn, backend):
                for idx, raw_phone in enumerate(phones, 1):
                    fp = sha256(raw_phone.encode()).hexdigest()
                    norm = normalize_us_phone(raw_phone) or raw_phone
                    if backend == "sqlserver":
                        conn.execute(sa_text("""INSERT dbo.raw_records(upload_batch_id,source_row_number,source_locator,raw_text,normalized_phone,fingerprint_sha256,parse_status)
                            VALUES(:b,:r,:l,:t,:p,:f,:s)"""),
                            {"b": batch_id, "r": idx, "l": name, "t": raw_phone, "p": norm, "f": fp, "s": "EXTRACTED"})
                    else:
                        conn.execute(sa_text("""INSERT INTO raw_records(upload_batch_id,source_row_number,source_locator,raw_text,normalized_phone,fingerprint_sha256,parse_status)
                            VALUES(:b,:r,:l,:t,:p,:f,:s)"""),
                            {"b": batch_id, "r": idx, "l": name, "t": raw_phone, "p": norm, "f": fp, "s": "EXTRACTED"})
                if backend == "sqlserver":
                    conn.execute(sa_text("""UPDATE dbo.upload_batches SET status='COMPLETED',total_records=:t,accepted_records=:a,extracted_phone_count=:p,completed_at=SYSUTCDATETIME() WHERE upload_batch_id=:b"""),
                                 {"t": extracted["rows"], "a": len(phones), "p": len(phones), "b": batch_id})
                else:
                    conn.execute(sa_text("""UPDATE upload_batches SET status='COMPLETED',total_records=:t,accepted_records=:a,extracted_phone_count=:p,completed_at=datetime('now') WHERE upload_batch_id=:b"""),
                                 {"t": extracted["rows"], "a": len(phones), "p": len(phones), "b": batch_id})
        await asyncio.to_thread(persist_phones)
        log_event("api:scrubber_upload", {"file": name, "ext": ext, "bytes": len(data)},
                  {"batch": batch_id, "parser": extracted["parser"], "phones": len(phones)})
        return {"ok": True, "upload_batch_id": batch_id, "file_name": name, "extension": ext, "mime_type": mime,
                "parser": extracted["parser"], "rows_scanned": extracted["rows"], "phone_candidates": len(phones),
                "sample": phones[:10]}
    except Exception as exc:
        def mark_fail():
            with dblib.db() as (conn, backend):
                tbl = "dbo.upload_batches" if backend == "sqlserver" else "upload_batches"
                conn.execute(sa_text(f"UPDATE {tbl} SET status='FAILED',error_message=:e WHERE upload_batch_id=:b"),
                             {"e": str(exc)[:4000], "b": batch_id})
        await asyncio.to_thread(mark_fail)
        raise HTTPException(status_code=422, detail=f"Extraction failed: {exc}")


@app.websocket("/ws/v2/vici")
async def vici_ws(ws: WebSocket):
    await ws.accept()
    connections.add(ws)
    try:
        while True:
            import json as _j
            payload = _j.loads(await ws.receive_text())
            m = Telemetry.model_validate(payload)
            result = analyze(m)
            await asyncio.to_thread(persist_telemetry, m, result)
            await ws.send_json({"raw": m.model_dump(), "ai_insights": result})
    except WebSocketDisconnect:
        connections.discard(ws)
