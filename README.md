# MMA-CDR TOOL — CDR Intelligence & Refinement (SQL Server edition)

Production-oriented CDR / list scrubbing + operational intelligence. Ported from `cdr-intelligence-v2-sqlserver-ssms-v2.1.zip` and hardened.

## What it does
- **Universal upload** `POST /api/v2/scrubber/upload` — any extension/MIME, phone extraction, raw staging.
- **Refinery** — normalize → validate → fingerprint → dedupe → suppression. Rust service in `refinery/` + Python inline fallback in API.
- **Scoring** `POST /api/v2/score` — CALL / REVIEW / SUPPRESS / INVALID / DUPLICATE with quality/contactability/risk.
- **Telemetry** `POST /api/v2/telemetry` + `WS /ws/v2/vici` — drop anomaly, queue saturation, paused-ratio alerts persisted to SQL Server.
- **Frontend** — Overview, Scrubber, Refine & Score, Telemetry, Database/SSMS guide. Demo mode when API offline.
- **Extension** — VICIdial monitor (`extension/`, rebranded to MMA-CDR TOOL Monitor).

## Layout
```
api/               FastAPI (app.py, db.py dual SQLServer/SQLite, ingestion.py, scoring.py, providers.py)
database/mma-cdr-sqlserver.sql   SSMS authoritative schema (16 tables, 11 procs, 5 views)
refinery/          Rust refinery (Axum :9100, /v2/refine + /v2/refine/batch)
extension/         Chrome MV3 VICIdial telemetry monitor
src/               React + Vite + Tailwind UI
```

## Run — backend
```powershell
pip install -r api/requirements.txt
# with SQL Server:
$env:SQLSERVER_HOST="localhost"; $env:SQLSERVER_USER="cdr_app"; $env:SQLSERVER_PASSWORD="CHANGE_ME"
uvicorn api.app:app --host 0.0.0.0 --port 8000
# without SQL Server (dev):
$env:MMA_CDR_USE_SQLITE="1"
uvicorn api.app:app --port 8000
```

## Run — frontend
```powershell
npm install
npm run dev      # VITE_API_URL=http://localhost:8000
npm run build
```

## SSMS
1. Open `database/mma-cdr-sqlserver.sql` in SSMS, Execute → creates `CDR_Intelligence`.
2. Create least-privilege `cdr_app` (db_datareader + db_datawriter + EXECUTE). Never use `sa`.
3. Install ODBC Driver 18 on API host.

## Senior-architect notes (20y review of source bundle)
- Source had no auth/RBAC, heuristic telemetry scoring, in-memory Rust DNC (lost on restart, no tenant scope), broad phone regex (false positives), VARBINARY(MAX) raw retention (DB bloat), CORS `*` default. Kept for compat, flagged in UI/docs.
- This build adds: SQLite dev fallback, input limits (MAX_UPLOAD_MB default 256), bounded ZIP inner files, inline Python refinery mirror, campaign summary + recent-list endpoints, demo-mode UI, least-privilege SQL guidance.
- Before real-money launch: add JWT/RBAC, real provider verification keys, VICIdial DB mapping, TLS, object storage for raw files (not VARBINARY), background jobs, observability, E2E tests.
