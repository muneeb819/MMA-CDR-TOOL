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
npm run dev      # Vite proxies same-origin /api and /health requests to API_PROXY_TARGET (default http://127.0.0.1:8000)
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

## Automated QA (Playwright)

The repository now includes an implementation-derived Playwright Test suite. The inventory and explicit non-implemented areas are in [`tests/TEST_INVENTORY.md`](tests/TEST_INVENTORY.md); `tests/tests.json` has been replaced with MMA-CDR-specific scenarios.

### Local setup

```bash
npm ci
python -m venv .venv
# macOS/Linux
.venv/bin/python -m pip install -r api/requirements.txt
# Windows PowerShell: .venv\Scripts\python.exe -m pip install -r api/requirements.txt
npx playwright install chromium
npm run build
npm run test:smoke
```

Playwright starts the actual Vite frontend on port 5173 and FastAPI on port 8000 by default. It does **not** reuse an already-listening service unless `PW_REUSE_EXISTING=1` is explicitly set, preventing accidental tests against a developer or production-connected database. Its local API process is pinned to `MMA_CDR_USE_SQLITE=1` and an isolated SQLite file under ignored `test-results/`; it does not need SQL Server credentials. The upload-limit test uses a small local `MAX_UPLOAD_MB` value (default 8 MB) and tests that configured boundary. Normal application uploads still default to `MAX_UPLOAD_MB=256` unless configured otherwise.

The UI uses same-origin relative `/api`, `/health`, and `/ws` URLs by default. Vite proxies these server-side to `API_PROXY_TARGET` (default `http://127.0.0.1:8000`), avoiding browser calls to sandbox `localhost` in preview environments. `VITE_API_URL` remains an optional explicit override.

To target already-running services rather than start local ones, set `BASE_URL` and `API_URL`, then set `PW_START_SERVERS=0`. Non-loopback URLs are blocked unless `QA_ALLOW_REMOTE_TARGET=1` is also set; use that only for a dedicated non-production QA environment, never production. For local auto-starts, `PW_REUSE_EXISTING=1` is an explicit opt-in to reuse a known-safe server; the default is a fresh isolated SQLite API process. `TEST_TENANT_ID` and `TEST_CAMPAIGN_ID` configure the synthetic test identifiers; no production credentials are embedded.

### Test commands

```bash
npm run test:smoke       # quick app/API/upload/refine/score/telemetry checks
npm run test:api         # actual FastAPI contract and security checks
npm run test:e2e         # desktop + mobile Chromium UI flows
npm run test:db          # SQLite checks, DDL source checks, optional SQL Server integration
npm run test:refinery    # Python refinery/providers + optional Rust service
npm run test:extension   # VICIdial MV3 content/popup contracts
npm run test:security
npm run test:performance # measured 10–50,000 row uploads and controlled concurrency
npm run test:regression
npm run test:all
npm run test:types
npm run test:report
```

For optional Rust integration, install Cargo and set `PW_START_RUST=1` (the server binds its actual source-defined port 9100), or provide `RUST_REFINERY_URL`. Rust tests skip with an explicit reason when unavailable. The test suite never contacts paid verification providers.

For live SQL Server tests, first provision and seed a **dedicated test database** with the repository's SQL script, then provide `SQLSERVER_HOST`, `SQLSERVER_PORT`, `SQLSERVER_USER`, `SQLSERVER_PASSWORD`, `SQLSERVER_TEST_DATABASE` (name must end in `_test`/`_qa`, or start with `test_`), and `RUN_SQLSERVER_TESTS=1`. The suite refuses an unmarked database, does not create/drop a database, and rolls back its insert/update/constraint probes. If SQL Server isn't configured, live integration checks are explicitly skipped; static DDL and SQLite tests still run.

`run-tests.ps1` orchestrates dependency checks, build, smoke/API/refinery/E2E/database/security/regression runs and returns a non-zero exit code on failure. Reports are written to `playwright-report/`, `test-results/results.json`, `test-results/junit.xml`, and `test-results/qa-summary.md`; run `npm run test:summary` to print the latest summary. Screenshots, traces and videos are retained on failure under `test-results/playwright/`.

### Current implementation limits captured by QA

- The Python REST refinement path accepts caller-supplied suppression hashes; it does not read the SQL suppressions table or deduplicate records. The REST scoring request currently hard-codes duplicate/suppression flags off. Tests assert only paths that are actually reachable.
- The SQL Server schema has 16 tables; SQLite fallback has seven and is not schema-equivalent. The upload endpoint stages metadata and extracted `raw_records`; the current API code does not write uploaded bytes into `upload_files.raw_file`.
- No auth/RBAC or API tenant-isolation enforcement exists. Recent-list endpoints are not tenant-filtered, and default CORS `WSS_ALLOWED_ORIGINS=*` is permissive. These are launch risks, not features the suite marks secure.
- The extension host permissions still contain `YOUR-VICIDIAL-HOST` / `YOUR-API-HOST` placeholders. Live extension-to-VICIdial deployment testing requires configured hosts.
- `pytesseract` and the Tesseract binary are optional and not installed by `api/requirements.txt`; image tests verify controlled OCR-unavailable handling unless that runtime is separately installed.
