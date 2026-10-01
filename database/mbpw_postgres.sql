-- =============================================================================
--  MBPW  ::  MMA Business Prosperity Weapon
--  Full PostgreSQL schema + objects + seed data
-- =============================================================================
--  Generated from the application source of truth:
--     backend/app/models/database.py     (engine / DATABASE_URL resolution)
--     backend/app/models/schema.py       (14 models  -> 14 tables)
--     backend/app/routers/auth.py        (3 models   -> 3  tables)
--     backend/app/models/seed.py         (admin bootstrap)
--     backend/app/services/**            (AppConfig keys, ACIE constants, cadence)
--
--  17 application tables, exactly matching what
--  `Base.metadata.create_all(bind=engine)` emits for the PostgreSQL dialect.
--
--  HOW TO RUN
--  -----------
--    psql -U postgres -f database/mbpw_postgres.sql
--  (or paste into any PostgreSQL >= 13 client; `\gexec` / `\connect` are psql
--   directives, plain `SELECT ... ; CREATE DATABASE` equivalents are noted.)
--
--  ENVIRONMENT VARIABLES THE APP EXPECTS
--  -------------------------------------
--    DATABASE_URL=postgresql://mbpw_app:***@localhost:5432/mbpw
--    JWT_SECRET, ADMIN_EMAIL, ADMIN_INITIAL_PASSWORD, CRON_SECRET
--    OPENAI_API_KEY, SMTP_HOST/PORT/USER/PASSWORD/FROM_EMAIL/FROM_NAME
--    HUNTER_API_KEY, APOLLO_API_KEY, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN
--    HUBSPOT_*  (alternatively store them as app_config rows)
--
--  IMPORTANT FIDELITY NOTES (read before editing)
--  ---------------------------------------------
--  1. NO FOREIGN KEYS / NO CHECK CONSTRAINTS are applied by default, on purpose.
--     The SQLAlchemy models declare every relationship as "FK handled at app
--     level" (see the `# FK handled at app level` comments in schema.py) and the
--     routers genuinely write dangling values:
--       * proposals.lead_id   -> routers/proposals.py writes '' when only
--                                `leadData` was supplied to POST /generate
--       * contacts.company_id -> routers/crm.py echoes the client-supplied
--                                companyId without validating it
--       * outreach_states / outreach / notifications are deleted/synced
--         independently of leads
--     Adding hard FKs turns those code paths into HTTP 500s. Section 10 ships
--     them as an OPT-IN block you can enable after auditing your data.
--  2. JSON columns are created as `jsonb` (the app asks for `JSON`). This is a
--     drop-in superset: SQLAlchemy serialises the Python value to JSON text and
--     PostgreSQL casts unknown-typed parameters to jsonb implicitly, while
--     jsonb additionally gives you GIN indexing and `@>` containment. To match
--     `create_all()` byte-for-byte, change every `jsonb` below to `json`.
--  3. Server-side DEFAULTs are provided for hand-written SQL and tooling only.
--     The ORM always sends an explicit value for every column (none of the
--     models declare `server_default`), so these defaults never mask an
--     application-level NULL.
--  4. All timestamps are `TIMESTAMP WITHOUT TIME ZONE` because the app writes
--     naive `datetime.utcnow()` values everywhere.
-- =============================================================================

\set ON_ERROR_STOP on

-- =============================================================================
-- SECTION 1  ::  ROLE, DATABASE, SCHEMA, EXTENSIONS
-- =============================================================================

-- 1.1 Application role -------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mbpw_app') THEN
        CREATE ROLE mbpw_app LOGIN PASSWORD 'CHANGE_ME_mbpw_app_password';
    END IF;
END
$$;

-- 1.2 Database ---------------------------------------------------------------
-- CREATE DATABASE cannot run inside a transaction block, so it is issued with
-- \gexec (psql). Non-psql clients: run `CREATE DATABASE mbpw OWNER mbpw_app
-- ENCODING 'UTF8' TEMPLATE template0;` manually once, then re-run this file.
SELECT 'CREATE DATABASE mbpw OWNER mbpw_app ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mbpw');
\gexec
-- The trailing ';' above is what \gexec wants; it also keeps this file parseable
-- by non-psql clients (which will simply return the DDL text as a result row).

\connect mbpw

-- 1.2b Pin the database timezone to UTC -------------------------------------
-- The application writes NAIVE datetimes everywhere (datetime.utcnow()), and
-- every timestamp column below is TIMESTAMP WITHOUT TIME ZONE. Pinning the
-- database to UTC guarantees that any ad-hoc SQL, psql session or BI tool that
-- writes timestamptz values stores the same wall-clock UTC the app uses.
-- (If your session TimeZone is, say, Etc/GMT-5, `now()` inserted into a naive
--  column is silently shifted by +5h and every due-date comparison breaks.)
DO $$
BEGIN
    EXECUTE 'ALTER DATABASE mbpw SET timezone TO ''UTC''';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Not permitted to ALTER DATABASE; set timezone to UTC manually or use timezone(''utc'', now()) in ad-hoc SQL.';
END
$$;
SET timezone TO 'UTC';

-- 1.3 Schema -----------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS mbpw AUTHORIZATION mbpw_app;
SET search_path TO mbpw, public;

-- 1.4 Extensions -------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest, crypt
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- trigram indexes for ILIKE '%x%'
CREATE EXTENSION IF NOT EXISTS btree_gin;  -- composite GIN (jsonb + text)

-- Optional: the docker-compose stack ships pgvector/pgvector:pg16. Enable it
-- if you intend to add embedding columns later.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS vector';
    END IF;
END
$$;


-- =============================================================================
-- SECTION 2  ::  REFERENCE / LOOKUP TABLES
-- -----------------------------------------------------------------------------
-- These are pure documentation + reporting objects. The application hard-codes
-- these vocabularies in Python (see ref_* provenance comments) and does NOT
-- read them, so they are never enforced. Enable the constraints in Section 10
-- if you want the database to police them.
-- =============================================================================

-- 2.1 Lead lifecycle  (src/lib/types.ts: LeadStatus + routers/leads.py) -------
CREATE TABLE IF NOT EXISTS ref_lead_status (
    code        VARCHAR(32)  PRIMARY KEY,
    label       VARCHAR(64)  NOT NULL,
    sort_order  INTEGER      NOT NULL DEFAULT 0,
    is_terminal BOOLEAN      NOT NULL DEFAULT FALSE,
    source      VARCHAR(128) NOT NULL DEFAULT 'src/lib/types.ts'
);
COMMENT ON TABLE ref_lead_status IS 'Canonical lead pipeline stages used by /api/leads, /api/reports/pipeline.';

-- 2.2 Job types (src/lib/types.ts: JobType) ---------------------------------
CREATE TABLE IF NOT EXISTS ref_job_type (
    code   VARCHAR(32) PRIMARY KEY,
    label  VARCHAR(64) NOT NULL
);

-- 2.3 Risk levels (src/lib/types.ts: RiskLevel) -----------------------------
CREATE TABLE IF NOT EXISTS ref_risk_level (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

-- 2.4 Urgency (src/lib/types.ts: UrgencyLevel) ------------------------------
CREATE TABLE IF NOT EXISTS ref_urgency (
    code   VARCHAR(32) PRIMARY KEY,
    label  VARCHAR(64) NOT NULL,
    rank   INTEGER     NOT NULL DEFAULT 0
);

-- 2.5 User roles (routers/auth.py: require_role) ----------------------------
CREATE TABLE IF NOT EXISTS ref_user_role (
    code     VARCHAR(32)  PRIMARY KEY,
    label    VARCHAR(64)  NOT NULL,
    level    INTEGER      NOT NULL,          -- 0 user | 1 admin | 2 superadmin
    source   VARCHAR(128) NOT NULL DEFAULT 'app/routers/auth.py:require_role'
);

-- 2.6 Notification taxonomy (src/lib/types.ts + routers/*) -------------------
CREATE TABLE IF NOT EXISTS ref_notification_type (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS ref_priority (
    code  VARCHAR(16) PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    rank  INTEGER     NOT NULL DEFAULT 0
);

-- 2.7 Connector taxonomy (src/lib/types.ts: Connector.type) -----------------
CREATE TABLE IF NOT EXISTS ref_connector_type (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS ref_connector_status (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

-- 2.8 Outreach vocabulary ----------------------------------------------------
CREATE TABLE IF NOT EXISTS ref_outreach_channel (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS ref_outreach_record_status (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS ref_outreach_state (
    code        VARCHAR(32) PRIMARY KEY,
    label       VARCHAR(64) NOT NULL,
    description TEXT
);

-- 2.9 ACIE vocabulary (services/acie/constants.py + compliance.py + learn.py) -
CREATE TABLE IF NOT EXISTS ref_acie_lifecycle (
    code        VARCHAR(32) PRIMARY KEY,
    description TEXT,
    terminal    BOOLEAN NOT NULL DEFAULT FALSE,
    source      VARCHAR(64) NOT NULL DEFAULT 'services/acie/constants.py:LIFECYCLE'
);

CREATE TABLE IF NOT EXISTS ref_supply_status (
    code        VARCHAR(32) PRIMARY KEY,
    label       VARCHAR(64) NOT NULL,
    blocks_send BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS ref_verification_status (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS ref_feedback_outcome (
    code            VARCHAR(32) PRIMARY KEY,
    label           VARCHAR(64) NOT NULL,
    counts_for_cap  BOOLEAN NOT NULL DEFAULT FALSE,  -- counts vs frequency cap
    event_type      VARCHAR(16),                    -- deliver | bounce | NULL
    bumps_lifecycle VARCHAR(32)
);

CREATE TABLE IF NOT EXISTS ref_provider (
    code          VARCHAR(32) PRIMARY KEY,
    label         VARCHAR(64) NOT NULL,
    kind          VARCHAR(16) NOT NULL,
    requires_key  BOOLEAN NOT NULL DEFAULT FALSE,
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    source        VARCHAR(64) NOT NULL DEFAULT 'services/acie/providers/registry.py'
);

CREATE TABLE IF NOT EXISTS ref_agent (
    code        VARCHAR(16) PRIMARY KEY,
    name        VARCHAR(64) NOT NULL,
    kind        VARCHAR(32) NOT NULL,
    description TEXT,
    icon        VARCHAR(8),
    source      VARCHAR(64) NOT NULL DEFAULT 'app/routers/agents.py:AGENT_DEFINITIONS'
);

-- 2.10 Registered lead sources (services/sources/__init__.py:ALL_SOURCES) ----
CREATE TABLE IF NOT EXISTS ref_lead_source (
    code          VARCHAR(32) PRIMARY KEY,
    display_name  VARCHAR(64) NOT NULL,
    source_type   VARCHAR(16) NOT NULL,      -- api | rss | ats
    homepage      VARCHAR(256),
    requires_key  BOOLEAN NOT NULL DEFAULT FALSE,
    enabled       BOOLEAN NOT NULL DEFAULT TRUE,
    source        VARCHAR(64) NOT NULL DEFAULT 'app/services/sources/__init__.py'
);

-- 2.11 Outreach cadence (services/outreach_service.py:CADENCE) ----------------
CREATE TABLE IF NOT EXISTS ref_outreach_cadence (
    step       INTEGER      PRIMARY KEY,
    day_offset INTEGER      NOT NULL,
    channel    VARCHAR(32)  NOT NULL,
    label      VARCHAR(128) NOT NULL,
    goal       TEXT         NOT NULL
);
COMMENT ON TABLE ref_outreach_cadence IS
    'Mirror of services/outreach_service.py:CADENCE (day 0/3/7/14). The app reads '
    'the Python constant, not this table; it is kept for reporting and for the '
    'mbpw_*_schedule views.';

-- 2.12 Knowledge-base entry types (src/lib/types.ts: KnowledgeEntry.entryType) -
CREATE TABLE IF NOT EXISTS ref_knowledge_type (
    code  VARCHAR(32) PRIMARY KEY,
    label VARCHAR(64) NOT NULL
);


-- =============================================================================
-- SECTION 3  ::  IDENTITY, SECURITY & AUDIT
-- backend/app/routers/auth.py
-- =============================================================================

-- 3.1 users ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id              VARCHAR       NOT NULL,
    email           VARCHAR       NOT NULL,
    name            VARCHAR       NOT NULL,
    role            VARCHAR       NOT NULL DEFAULT 'user',
    hashed_password VARCHAR       NOT NULL,
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP     NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    last_login      TIMESTAMP     NULL,
    avatar_url      VARCHAR       NOT NULL DEFAULT '',
    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT uq_users_email UNIQUE (email)
);
COMMENT ON TABLE  users IS 'Application users. role drives RBAC: user(0) < admin(1) < superadmin(2).';
COMMENT ON COLUMN users.hashed_password IS 'passlib bcrypt digest produced by CryptContext(schemes=["bcrypt"]).';
COMMENT ON COLUMN users.created_at     IS 'Naive UTC (app writes datetime.utcnow()).';

-- 3.2 sessions ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
    id         VARCHAR   NOT NULL,
    user_id    VARCHAR   NOT NULL,          -- deliberately not an FK (see §10)
    token      VARCHAR   NOT NULL,          -- the raw HS256 JWT
    device     VARCHAR   NOT NULL DEFAULT '',
    ip_address VARCHAR   NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    expires_at TIMESTAMP NOT NULL,
    is_active  BOOLEAN   NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_sessions PRIMARY KEY (id)
);
COMMENT ON TABLE sessions IS 'Issued JWTs. /api/auth/logout flips is_active; /api/admin/maintenance/cleanup-sessions purges by expires_at.';

-- 3.3 audit_logs -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
    id          VARCHAR   NOT NULL,
    user_id     VARCHAR   NOT NULL,          -- user uuid, or the literal 'anonymous'
    action      VARCHAR   NOT NULL,
    resource    VARCHAR   NOT NULL DEFAULT '',
    resource_id VARCHAR   NOT NULL DEFAULT '',
    details     VARCHAR   NOT NULL DEFAULT '',
    ip_address  VARCHAR   NOT NULL DEFAULT '',
    created_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_audit_logs PRIMARY KEY (id)
);


-- =============================================================================
-- SECTION 4  ::  CORE PIPELINE  (Hunting -> Landing -> Outreach -> Response)
-- backend/app/models/schema.py
-- =============================================================================

-- 4.1 leads ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
    id                   VARCHAR      NOT NULL,
    title                VARCHAR      NOT NULL,
    description          TEXT,
    client_name          VARCHAR,
    company              VARCHAR,
    email                VARCHAR,
    phone                VARCHAR,
    country              VARCHAR,
    budget_min           DOUBLE PRECISION,
    budget_max           DOUBLE PRECISION,
    deadline             VARCHAR,                 -- free-form string in the app
    technologies         jsonb,                   -- text[]
    skills               jsonb,                   -- text[]
    platform             VARCHAR,                 -- source code, e.g. 'remotive'
    job_type             VARCHAR,
    status               VARCHAR      NOT NULL DEFAULT 'new',
    urgency              VARCHAR      NOT NULL DEFAULT 'medium',
    difficulty           DOUBLE PRECISION NOT NULL DEFAULT 50,
    success_probability  DOUBLE PRECISION NOT NULL DEFAULT 50,
    risk_level           VARCHAR      NOT NULL DEFAULT 'medium',
    expected_revenue     DOUBLE PRECISION NOT NULL DEFAULT 0,
    competition          INTEGER      NOT NULL DEFAULT 0,
    project_size         VARCHAR      NOT NULL DEFAULT 'medium',
    payment_method       VARCHAR      NOT NULL DEFAULT 'Escrow',
    client_history       TEXT,
    url                  VARCHAR,
    notes                TEXT,
    tags                 jsonb,                   -- text[] + 'enriched:<src>', 'email_confirmed'
    found_at             TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    analyzed_at          TIMESTAMP    NULL,
    CONSTRAINT pk_leads PRIMARY KEY (id)
);
COMMENT ON TABLE  leads IS 'Central opportunity record. Written by services/sync.py (id = ''live-'' || md5(title|company|url)[:16]) and by routers/leads.py (id = uuid4).';
COMMENT ON COLUMN leads.id IS 'Deterministic md5 hash for hunted leads => re-syncing updates in place instead of duplicating.';
COMMENT ON COLUMN leads.technologies IS 'JSON array of strings. NOTE: leads.py/search.py call .any() on this column, which SQLAlchemy cannot emit for JSON on PostgreSQL (AttributeError). Use the view v_technology_breakdown or jsonb containment: technologies @> ''["react"]''::jsonb.';
COMMENT ON COLUMN leads.tags IS 'JSON array of strings; enrichment appends "enriched:<source>", a manual email adds "email_confirmed".';
COMMENT ON COLUMN leads.found_at IS 'Set to the job post''s published_at by sync.py, otherwise utcnow.';
COMMENT ON COLUMN leads.analyzed_at IS 'NULL = awaiting Lead Analyzer (agents.py filters on this).';

-- 4.2 proposals --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS proposals (
    id                    VARCHAR      NOT NULL,
    lead_id               VARCHAR,               -- may be '' when generated from raw leadData
    title                 VARCHAR      NOT NULL,
    cover_letter          TEXT,
    introduction          TEXT,
    technical_plan        TEXT,
    timeline              VARCHAR,
    cost_estimate         TEXT,
    portfolio_suggestions jsonb,
    call_to_action        TEXT,
    win_probability       DOUBLE PRECISION NOT NULL DEFAULT 0,
    status                VARCHAR      NOT NULL DEFAULT 'draft',
    created_at            TIMESTAMP    NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    submitted_at          TIMESTAMP    NULL,
    CONSTRAINT pk_proposals PRIMARY KEY (id)
);
COMMENT ON TABLE proposals IS 'AI-generated (services/ai_service.py, OpenAI) or template-fallback proposals.';

-- 4.3 outreach (touch log) ---------------------------------------------------
CREATE TABLE IF NOT EXISTS outreach (
    id          VARCHAR   NOT NULL,
    lead_id     VARCHAR,
    client_name VARCHAR,
    company     VARCHAR,
    email       VARCHAR,
    channel     VARCHAR   NOT NULL DEFAULT 'email',
    step        INTEGER   NOT NULL DEFAULT 0,       -- index into CADENCE (0..3)
    step_label  VARCHAR,
    subject     VARCHAR,
    body_text   TEXT,
    status      VARCHAR   NOT NULL DEFAULT 'simulated',
    simulated   BOOLEAN   NOT NULL DEFAULT FALSE,
    sent_at     TIMESTAMP NULL,
    replied_at  TIMESTAMP NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_outreach PRIMARY KEY (id)
);
COMMENT ON COLUMN outreach.status IS 'sent | simulated | logged | replied | failed (email_sender.py + outreach.py).';
COMMENT ON COLUMN outreach.simulated IS 'TRUE when SMTP is unconfigured — message was built and stored, not delivered.';

-- 4.4 outreach_states (cadence scheduler state) ------------------------------
CREATE TABLE IF NOT EXISTS outreach_states (
    lead_id       VARCHAR   NOT NULL,
    enrolled      BOOLEAN   NOT NULL DEFAULT TRUE,
    current_step  INTEGER   NOT NULL DEFAULT -1,   -- -1 = day 0 not sent yet
    status        VARCHAR   NOT NULL DEFAULT 'active',
    last_sent_at  TIMESTAMP NULL,
    next_due_at   TIMESTAMP NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    updated_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_outreach_states PRIMARY KEY (lead_id)
);
COMMENT ON TABLE outreach_states IS 'Per-lead progressive-outreach state machine driven by GET /api/outreach/cron (outreach_automation.process_due_outreach).';
COMMENT ON COLUMN outreach_states.status IS 'active | paused | needs_email (parked) | completed.';

-- 4.5 notifications ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
    id         VARCHAR   NOT NULL,
    type       VARCHAR,                    -- system | high_value | urgent | agent | new_lead | ...
    title      VARCHAR,
    message    TEXT,
    lead_id    VARCHAR,                    -- optional context link
    "read"     BOOLEAN   NOT NULL DEFAULT FALSE,
    priority   VARCHAR   NOT NULL DEFAULT 'medium',
    created_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_notifications PRIMARY KEY (id)
);
COMMENT ON COLUMN notifications."read" IS 'Quoted because READ is a col_name_keyword in PostgreSQL; the ORM emits it unquoted and resolves identically.';


-- =============================================================================
-- SECTION 5  ::  CRM, CONNECTORS, AGENTS, KNOWLEDGE, CONFIG
-- =============================================================================

-- 5.1 companies --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS companies (
    id         VARCHAR          NOT NULL,
    name       VARCHAR          NOT NULL,
    industry   VARCHAR,
    country    VARCHAR,
    website    VARCHAR,
    revenue    DOUBLE PRECISION NOT NULL DEFAULT 0,
    status     VARCHAR          NOT NULL DEFAULT 'prospect',
    notes      TEXT,
    created_at TIMESTAMP        NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_companies PRIMARY KEY (id)
);

-- 5.2 contacts ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contacts (
    id         VARCHAR NOT NULL,
    name       VARCHAR NOT NULL,
    email      VARCHAR,
    phone      VARCHAR,
    role       VARCHAR,
    company_id VARCHAR,                     -- app-level FK, deleted with the company
    CONSTRAINT pk_contacts PRIMARY KEY (id)
);

-- 5.3 connectors -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS connectors (
    id            VARCHAR   NOT NULL,
    name          VARCHAR   NOT NULL,
    type          VARCHAR   NOT NULL,       -- api | rss | ats | scraper | webhook
    platform      VARCHAR,                  -- must equal a ref_lead_source.code for sync to resolve
    status        VARCHAR   NOT NULL DEFAULT 'inactive',
    config        jsonb,
    last_sync_at  TIMESTAMP NULL,
    sync_count    INTEGER   NOT NULL DEFAULT 0,
    leads_found   INTEGER   NOT NULL DEFAULT 0,
    error_message TEXT      NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    updated_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_connectors PRIMARY KEY (id)
);
COMMENT ON COLUMN connectors.platform IS 'Resolved by routers/connectors.py as get_source(platform or slugified name).';

-- 5.4 agent_logs -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_logs (
    id        VARCHAR   NOT NULL,
    agent_id  VARCHAR,                      -- agent-1 | agent-2 | agent-3
    action    VARCHAR,                      -- run_started | sync_complete | analyze_complete | ...
    details   TEXT,
    status    VARCHAR   NOT NULL DEFAULT 'success',
    timestamp TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_agent_logs PRIMARY KEY (id)
);
COMMENT ON TABLE agent_logs IS 'Append-only execution trail for the 3 real agents in routers/agents.py. /ai-teams agent state is in-memory and is NOT persisted here.';

-- 5.5 knowledge_base ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS knowledge_base (
    id         VARCHAR   NOT NULL,
    title      VARCHAR   NOT NULL,
    entry_type VARCHAR   NOT NULL,           -- playbook | industry_knowledge | past_win | past_loss | client_history
    content    TEXT      NOT NULL,
    tags       jsonb,
    source     VARCHAR   NOT NULL DEFAULT '',
    source_url VARCHAR   NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    updated_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_knowledge_base PRIMARY KEY (id)
);

-- 5.6 app_config (key/value secret + feature-flag store) ---------------------
CREATE TABLE IF NOT EXISTS app_config (
    "key"      VARCHAR   NOT NULL,
    value      TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_app_config PRIMARY KEY ("key")
);
COMMENT ON TABLE app_config IS 'Runtime configuration read through SessionLocal by routers/settings.py, services/enrichment.py, services/hubspot.py, services/outreach_automation.py and services/acie/compliance.py.';
COMMENT ON COLUMN app_config.value IS 'Opaque string. May be JSON (act.gate.dnc_companies), a number-as-text, or a secret. Seeded in Section 8.';


-- =============================================================================
-- SECTION 6  ::  ACIE  (Automated Contact Intelligence Engine)
-- backend/app/models/schema.py :: ContactIntel / ProviderPerformance / OutreachFeedback
-- =============================================================================

-- 6.1 contact_intel ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS contact_intel (
    lead_id                VARCHAR          NOT NULL,   -- PK == one intel record per lead
    person_id              VARCHAR,                      -- resolved person identity id
    name                   VARCHAR,
    company                VARCHAR,
    domain                 VARCHAR,
    title                  VARCHAR,
    email                  VARCHAR,
    phone                  VARCHAR,
    lifecycle              VARCHAR          NOT NULL DEFAULT 'DISCOVERED',
    channel                VARCHAR          NOT NULL DEFAULT 'email',
    contact_confidence     DOUBLE PRECISION NOT NULL DEFAULT 0,
    identity_confidence    DOUBLE PRECISION NOT NULL DEFAULT 0,
    employment_confidence  DOUBLE PRECISION NOT NULL DEFAULT 0,
    email_confidence       DOUBLE PRECISION NOT NULL DEFAULT 0,
    phone_confidence       DOUBLE PRECISION NOT NULL DEFAULT 0,
    risk_score             DOUBLE PRECISION NOT NULL DEFAULT 0,
    freshness_score        DOUBLE PRECISION NOT NULL DEFAULT 0,
    verification_status    VARCHAR          NOT NULL DEFAULT 'unknown',
    supply_status          VARCHAR          NOT NULL DEFAULT 'ok',
    provider               VARCHAR          NOT NULL DEFAULT '',
    profile                jsonb,                       -- full ACIE decision payload
    last_contacted         TIMESTAMP        NULL,
    last_verified          TIMESTAMP        NULL,
    next_verification      TIMESTAMP        NULL,
    bounce_count           INTEGER          NOT NULL DEFAULT 0,
    created_at             TIMESTAMP        NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    updated_at             TIMESTAMP        NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_contact_intel PRIMARY KEY (lead_id)
);
COMMENT ON TABLE  contact_intel IS 'The ACIE decision object: identity -> employment -> verification -> risk -> freshness -> score -> channel -> compliance -> lifecycle.';
COMMENT ON COLUMN contact_intel.contact_confidence IS '0..100 weighted score (acie/constants.py:WEIGHTS). >=90 HIGH / >=75 MEDIUM / else LOW.';
COMMENT ON COLUMN contact_intel.supply_status   IS 'ok | bounced | opted_out | suppressed. Anything other than ''ok'' fails the compliance gate.';
COMMENT ON COLUMN contact_intel.lifecycle       IS 'DISCOVERED | RESOLVED | OUTREACH_READY | REVIEW_ALT | LOW_SUPPRESS | SUPPRESSED | REPLIED | BOUNCED | UNSUBSCRIBED | JOB_CHANGE | STALE.';
COMMENT ON COLUMN contact_intel.profile        IS 'JSON snapshot: {identity, employment, verification, risk, score, components, channel, gate, evidence[]}.';

-- 6.2 provider_performance (learning engine) ---------------------------------
CREATE TABLE IF NOT EXISTS provider_performance (
    provider   VARCHAR          NOT NULL,
    event_type VARCHAR          NOT NULL,    -- deliver | bounce
    count      INTEGER          NOT NULL DEFAULT 0,
    weighted   DOUBLE PRECISION NOT NULL DEFAULT 0,
    updated_at TIMESTAMP        NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_provider_performance PRIMARY KEY (provider, event_type)
);
COMMENT ON TABLE provider_performance IS 'Per-provider evidence quality. reliability = deliver/(deliver+bounce), penalised -0.15 once bounce >= 3 (services/acie/learn.py).';

-- 6.3 outreach_feedback (closed loop) ----------------------------------------
CREATE TABLE IF NOT EXISTS outreach_feedback (
    id                  VARCHAR          NOT NULL,
    lead_id             VARCHAR,
    channel             VARCHAR          NOT NULL DEFAULT 'email',
    outcome             VARCHAR          NOT NULL DEFAULT 'no_response',
    provider            VARCHAR          NOT NULL DEFAULT '',
    confidence_at_time  DOUBLE PRECISION NOT NULL DEFAULT 0,
    detail              TEXT,
    created_at          TIMESTAMP        NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT pk_outreach_feedback PRIMARY KEY (id)
);
COMMENT ON TABLE outreach_feedback IS 'Every send outcome. Feeds the frequency cap (last 30d), the reply cooldown, lifecycle transitions and provider_performance.';


-- =============================================================================
-- SECTION 7  ::  INDEXES
-- Every index below maps to a WHERE / ORDER BY / GROUP BY that actually exists
-- in the routers, so they are not speculative.
-- =============================================================================

-- 7.1 leads ------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_leads_found_at          ON leads (found_at DESC);
CREATE INDEX IF NOT EXISTS ix_leads_status            ON leads (status);
CREATE INDEX IF NOT EXISTS ix_leads_status_found      ON leads (status, found_at DESC);
CREATE INDEX IF NOT EXISTS ix_leads_platform          ON leads (platform);
CREATE INDEX IF NOT EXISTS ix_leads_country           ON leads (country);
CREATE INDEX IF NOT EXISTS ix_leads_company           ON leads (company);
CREATE INDEX IF NOT EXISTS ix_leads_job_type          ON leads (job_type);
-- Lead Analyzer worklist: db.query(Lead).filter(Lead.analyzed_at == None)
CREATE INDEX IF NOT EXISTS ix_leads_pending_analysis  ON leads (found_at DESC) WHERE analyzed_at IS NULL;
-- Proposal Generator worklist: status IN ('analyzing','qualified') AND success_probability >= 50
CREATE INDEX IF NOT EXISTS ix_leads_proposal_ready    ON leads (success_probability DESC, found_at DESC)
    WHERE status IN ('analyzing', 'qualified');
-- Enrichment worklist: Lead.email IS NULL OR Lead.email = ''
CREATE INDEX IF NOT EXISTS ix_leads_missing_email     ON leads (found_at) WHERE email IS NULL OR email = '';
CREATE INDEX IF NOT EXISTS ix_leads_won               ON leads (found_at DESC) WHERE status = 'won';
CREATE INDEX IF NOT EXISTS ix_leads_technologies_gin  ON leads USING gin (technologies jsonb_path_ops);
CREATE INDEX IF NOT EXISTS ix_leads_tags_gin          ON leads USING gin (tags jsonb_path_ops);
-- Search: Lead.title.ilike('%kw%') OR description/client_name/company.ilike('%kw%')
-- Trigram indexes need the pg_trgm opclass; create them only when it is available
-- (pg_trgm ships with PostgreSQL contrib, but managed providers sometimes hide it).
DO $$
DECLARE
    v_trgm BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_opclass oc
                     JOIN pg_am am ON am.oid = oc.opcmethod
                    WHERE oc.opcname = 'gin_trgm_ops' AND am.amname = 'gin')
      INTO v_trgm;

    IF v_trgm THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_leads_title_trgm ON leads USING gin (title gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_leads_company_trgm ON leads USING gin (company gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_leads_description_trgm ON leads USING gin (description gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_companies_name_trgm ON companies USING gin (name gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_contacts_name_trgm ON contacts USING gin (name gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS ix_knowledge_title_trgm ON knowledge_base USING gin (title gin_trgm_ops)';
    ELSE
        RAISE NOTICE 'pg_trgm opclass not available - skipping 6 trigram indexes (ILIKE scans will be sequential).';
    END IF;
END
$$;

-- 7.2 proposals --------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_proposals_lead_id       ON proposals (lead_id);
CREATE INDEX IF NOT EXISTS ix_proposals_created_at    ON proposals (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_proposals_status        ON proposals (status);
CREATE INDEX IF NOT EXISTS ix_proposals_win_prob      ON proposals (win_probability DESC);
CREATE INDEX IF NOT EXISTS ix_proposals_portfolio_gin ON proposals USING gin (portfolio_suggestions jsonb_path_ops);

-- 7.3 outreach ---------------------------------------------------------------
-- outreach.py: .filter(Outreach.lead_id == l.id).order_by(Outreach.step.desc()).first()
CREATE INDEX IF NOT EXISTS ix_outreach_lead_step       ON outreach (lead_id, step DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_created_at     ON outreach (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_status         ON outreach (status);
CREATE INDEX IF NOT EXISTS ix_outreach_channel        ON outreach (channel);
CREATE INDEX IF NOT EXISTS ix_outreach_sent_at        ON outreach (sent_at DESC) WHERE status = 'sent';

-- 7.4 outreach_states --------------------------------------------------------
-- The cron hot path: WHERE enrolled = true AND status = 'active' AND next_due_at <= now()
CREATE INDEX IF NOT EXISTS ix_outreach_states_due     ON outreach_states (next_due_at)
    WHERE enrolled AND status = 'active';
CREATE INDEX IF NOT EXISTS ix_outreach_states_status  ON outreach_states (status);
CREATE INDEX IF NOT EXISTS ix_outreach_states_step    ON outreach_states (current_step);

-- 7.5 notifications ----------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_notifications_created_at ON notifications (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_notifications_unread     ON notifications (created_at DESC) WHERE NOT "read";
CREATE INDEX IF NOT EXISTS ix_notifications_lead_id    ON notifications (lead_id);
CREATE INDEX IF NOT EXISTS ix_notifications_type       ON notifications (type);
CREATE INDEX IF NOT EXISTS ix_notifications_priority   ON notifications (priority);

-- 7.6 users / sessions / audit ----------------------------------------------
CREATE INDEX IF NOT EXISTS ix_sessions_token        ON sessions (token);
CREATE INDEX IF NOT EXISTS ix_sessions_user_active  ON sessions (user_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS ix_sessions_expires_at   ON sessions (expires_at);
CREATE INDEX IF NOT EXISTS ix_audit_logs_created_at ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_user_id    ON audit_logs (user_id);
CREATE INDEX IF NOT EXISTS ix_audit_logs_resource   ON audit_logs (resource, resource_id);

-- 7.7 companies / contacts ---------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_companies_created_at   ON companies (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_companies_status       ON companies (status);
CREATE INDEX IF NOT EXISTS ix_contacts_company_id    ON contacts (company_id);
CREATE INDEX IF NOT EXISTS ix_contacts_email         ON contacts (email);

-- 7.8 connectors -------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_connectors_status     ON connectors (status);
CREATE INDEX IF NOT EXISTS ix_connectors_platform   ON connectors (platform);
CREATE INDEX IF NOT EXISTS ix_connectors_created_at ON connectors (created_at DESC);

-- 7.9 agent_logs -------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_agent_logs_agent_ts    ON agent_logs (agent_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS ix_agent_logs_timestamp  ON agent_logs (timestamp DESC);
CREATE INDEX IF NOT EXISTS ix_agent_logs_status     ON agent_logs (status);

-- 7.10 knowledge_base --------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_knowledge_created_at   ON knowledge_base (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_knowledge_entry_type   ON knowledge_base (entry_type);
CREATE INDEX IF NOT EXISTS ix_knowledge_tags_gin     ON knowledge_base USING gin (tags jsonb_path_ops);

-- 7.11 ACIE ------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_contact_intel_lifecycle        ON contact_intel (lifecycle);
CREATE INDEX IF NOT EXISTS ix_contact_intel_supply_status   ON contact_intel (supply_status);
CREATE INDEX IF NOT EXISTS ix_contact_intel_confidence      ON contact_intel (contact_confidence DESC);
CREATE INDEX IF NOT EXISTS ix_contact_intel_email           ON contact_intel (email);
CREATE INDEX IF NOT EXISTS ix_contact_intel_domain          ON contact_intel (domain);
CREATE INDEX IF NOT EXISTS ix_contact_intel_next_verify     ON contact_intel (next_verification)
    WHERE next_verification IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_contact_intel_person_id       ON contact_intel (person_id);
-- compliance.py frequency cap: count(sent|opened) in the last 30 days per lead
CREATE INDEX IF NOT EXISTS ix_outreach_feedback_lead_ts     ON outreach_feedback (lead_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_feedback_outcome     ON outreach_feedback (outcome);
CREATE INDEX IF NOT EXISTS ix_outreach_feedback_lead_id     ON outreach_feedback (lead_id);


-- =============================================================================
-- SECTION 8  ::  TRIGGERS  (updated_at maintenance)
-- Mirrors the SQLAlchemy `onupdate=datetime.utcnow` on
-- connectors, outreach_states, knowledge_base, contact_intel, provider_performance.
-- =============================================================================

CREATE OR REPLACE FUNCTION mbpw_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := (now() AT TIME ZONE 'utc');
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['connectors','outreach_states','knowledge_base','contact_intel','provider_performance']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_touch_updated_at ON %1$I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_touch_updated_at
             BEFORE UPDATE ON %1$I
             FOR EACH ROW EXECUTE FUNCTION mbpw_touch_updated_at()', t);
    END LOOP;
END
$$;

-- Enforce the app's invariant that app_config rows are never orphaned/stale.
CREATE OR REPLACE FUNCTION mbpw_app_config_key_upsert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- keep updated_at accurate even for raw-SQL writers
    NEW.updated_at := (now() AT TIME ZONE 'utc');
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_app_config_touch_updated_at ON app_config;
CREATE TRIGGER trg_app_config_touch_updated_at
    BEFORE UPDATE ON app_config
    FOR EACH ROW EXECUTE FUNCTION mbpw_app_config_key_upsert();


-- =============================================================================
-- SECTION 9  ::  FUNCTIONS  (SQL mirrors of the Python decision logic)
-- Useful for psql-based reporting/auditing; the app does not call these.
-- =============================================================================

-- 9.1 Compliance gate — port of services/acie/compliance.py:gate_status -------
-- NOTE: the blocked-reason list is built with array_append(), not "arr || 'x'".
-- The || form is ambiguous in PostgreSQL: a bare string literal is `unknown` and
-- gets coerced to text[], producing "malformed array literal: frequency_cap".
CREATE OR REPLACE FUNCTION mbpw_compliance_gate(p_lead_id TEXT)
RETURNS TABLE (
    pass                      BOOLEAN,
    gate_enabled              BOOLEAN,
    blocked                   TEXT[],
    supply_status             TEXT,
    frequency_current         INTEGER,
    frequency_max             INTEGER,
    reply_cooldown_days_left  INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_cfg_enabled    TEXT;
    v_freq_raw       TEXT;
    v_cooloff_raw    TEXT;
    v_dnc_raw        TEXT;
    v_company        TEXT;
    v_intel_status   TEXT;
    v_freq_hits      INTEGER;
    v_recent_reply   TIMESTAMP;
    v_blocked        TEXT[] := ARRAY[]::TEXT[];
    v_freq_max       INTEGER;
    v_cooloff        INTEGER;
    v_in_cooldown    BOOLEAN;
BEGIN
    SELECT value INTO v_cfg_enabled FROM app_config WHERE "key" = 'act.gate.enabled';
    SELECT value INTO v_freq_raw    FROM app_config WHERE "key" = 'act.gate.frequency_max';
    SELECT value INTO v_cooloff_raw FROM app_config WHERE "key" = 'act.gate.reply_cooloff_days';
    SELECT value INTO v_dnc_raw     FROM app_config WHERE "key" = 'act.gate.dnc_companies';

    v_freq_max := COALESCE(NULLIF(v_freq_raw,    '')::INTEGER, 4);
    v_cooloff  := COALESCE(NULLIF(v_cooloff_raw, '')::INTEGER, 90);

    SELECT ci.company, ci.supply_status
      INTO v_company, v_intel_status
      FROM contact_intel ci
     WHERE ci.lead_id = p_lead_id;

    v_intel_status := COALESCE(v_intel_status, 'ok');

    SELECT count(*)::INTEGER INTO v_freq_hits
      FROM outreach_feedback f
     WHERE f.lead_id = p_lead_id
       AND f.created_at >= (now() AT TIME ZONE 'utc') - INTERVAL '30 days'
       AND f.outcome IN ('sent', 'opened');

    SELECT max(f.created_at) INTO v_recent_reply
      FROM outreach_feedback f
     WHERE f.lead_id = p_lead_id
       AND f.outcome IN ('reply_positive', 'reply_negative');

    v_in_cooldown := v_recent_reply IS NOT NULL
                     AND ((now() AT TIME ZONE 'utc') - v_recent_reply) < (v_cooloff || ' days')::INTERVAL;

    IF COALESCE(v_cfg_enabled, 'on') <> 'on' THEN
        v_blocked := array_append(v_blocked, 'gate_disabled');
    END IF;

    IF v_dnc_raw IS NOT NULL AND v_dnc_raw <> '' AND v_dnc_raw <> '[]' THEN
        IF EXISTS (
            SELECT 1
              FROM jsonb_array_elements(v_dnc_raw::jsonb) d
             WHERE lower(d ->> 'company') = lower(COALESCE(v_company, p_lead_id))
        ) THEN
            v_blocked := array_append(v_blocked, 'do_not_contact');
        END IF;
    END IF;

    IF v_intel_status IN ('opted_out', 'suppressed', 'bounced') THEN
        v_blocked := array_append(v_blocked, 'suppressed:' || v_intel_status);
    END IF;

    IF v_freq_hits >= v_freq_max THEN
        v_blocked := array_append(v_blocked, 'frequency_cap');
    END IF;

    IF v_in_cooldown THEN
        v_blocked := array_append(v_blocked, 'reply_cooldown');
    END IF;

    RETURN QUERY
    SELECT array_length(v_blocked, 1) IS NULL OR array_length(v_blocked, 1) = 0,
           COALESCE(v_cfg_enabled, 'on') = 'on',
           v_blocked,
           v_intel_status,
           v_freq_hits,
           v_freq_max,
           CASE WHEN v_recent_reply IS NULL THEN 0
                ELSE GREATEST(0, v_cooloff - (EXTRACT(DAY FROM ((now() AT TIME ZONE 'utc') - v_recent_reply))::INTEGER))
           END;
END;
$$;

COMMENT ON FUNCTION mbpw_compliance_gate(TEXT) IS
    'SQL port of services/acie/compliance.py:gate_status. Called by outreach_automation.send_step() before every send.';

-- 9.2 Blocking predicate used by the outreach engine ------------------------
CREATE OR REPLACE FUNCTION mbpw_can_send(p_lead_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT (mbpw_compliance_gate(p_lead_id)).pass;
$$;

-- 9.3 Next cadence due date — port of outreach_automation.compute_next_due --
CREATE OR REPLACE FUNCTION mbpw_compute_next_due(p_lead_id TEXT)
RETURNS TIMESTAMP
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    st          outreach_states%ROWTYPE;
    cadence_len INTEGER;
    cur_day     INTEGER;
    nxt_day     INTEGER;
BEGIN
    SELECT * INTO st FROM outreach_states WHERE lead_id = p_lead_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT count(*)::INTEGER INTO cadence_len FROM ref_outreach_cadence;

    IF st.last_sent_at IS NULL OR st.current_step < 0 THEN
        RETURN (now() AT TIME ZONE 'utc');          -- day 0 is due immediately
    END IF;
    IF st.current_step >= cadence_len - 1 THEN
        RETURN NULL;                                 -- sequence finished
    END IF;

    SELECT day_offset INTO cur_day FROM ref_outreach_cadence WHERE step = st.current_step;
    SELECT day_offset INTO nxt_day FROM ref_outreach_cadence WHERE step = st.current_step + 1;

    RETURN st.last_sent_at + (GREATEST(0, nxt_day - cur_day) || ' days')::INTERVAL;
END;
$$;

-- 9.4 ACIE confidence tier — port of services/acie/pipeline.py:_to_decision --
CREATE OR REPLACE FUNCTION mbpw_confidence_tier(p_score DOUBLE PRECISION)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_score >= 90 THEN 'HIGH'     -- constants.HIGH_CONFIDENCE
        WHEN p_score >= 75 THEN 'MEDIUM'   -- constants.REVIEW_THRESHOLD
        ELSE 'LOW'
    END;
$$;

-- 9.5 Provider reliability — port of services/acie/learn.py:provider_reliability
CREATE OR REPLACE FUNCTION mbpw_provider_reliability(p_provider TEXT)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_deliver DOUBLE PRECISION;
    v_bounce  DOUBLE PRECISION;
    v_ratio   DOUBLE PRECISION;
BEGIN
    -- NB: scalar sub-select + COALESCE, not "SELECT ... INTO": an unknown
    -- provider yields zero rows, and SELECT INTO would leave the variable NULL.
    SELECT COALESCE((SELECT weighted FROM provider_performance
                      WHERE provider = p_provider AND event_type = 'deliver'), 0)
      INTO v_deliver;
    SELECT COALESCE((SELECT weighted FROM provider_performance
                      WHERE provider = p_provider AND event_type = 'bounce'), 0)
      INTO v_bounce;

    IF v_deliver = 0 AND v_bounce = 0 THEN
        RETURN 0.5;
    END IF;

    v_ratio := v_deliver / GREATEST(1.0, v_deliver + v_bounce);
    IF v_bounce >= 3 THEN
        v_ratio := GREATEST(0.0, v_ratio - 0.15);
    END IF;
    RETURN round(v_ratio::numeric, 3)::double precision;
END;
$$;

-- 9.6 Email deliverability — SQL twin of outreach_service.is_email_deliverable
-- NOTE: a true deliverability check needs DNS/MX, which this function cannot do.
--       It reproduces the syntactic + reserved-domain/local-part rules only.
CREATE OR REPLACE FUNCTION mbpw_email_syntax_ok(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_local  TEXT;
    v_domain TEXT;
BEGIN
    IF p_email IS NULL OR p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN FALSE;
    END IF;

    v_local  := lower(split_part(trim(p_email), '@', 1));
    v_domain := lower(split_part(trim(p_email), '@', 2));

    IF v_domain = ANY (ARRAY['example.com','example.net','example.org','test.com','localhost',
                              'invalid','domain.com','email.com','yourdomain.com','example',
                              'test','localhost.localdomain','mailinator.com','10minutemail.com',
                              'guerrillamail.com','tempmail.com','trashmail.com']) THEN
        RETURN FALSE;
    END IF;

    IF v_local = ANY (ARRAY['name','test','user','email','yourname','anonymous','sample']) THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END;
$$;

-- 9.7 Lead -> funnel helper --------------------------------------------------
CREATE OR REPLACE FUNCTION mbpw_funnel_value()
RETURNS TABLE (stage TEXT, lead_count BIGINT, pipeline_value DOUBLE PRECISION)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(l.status, 'new'),
           count(*)::BIGINT,
           COALESCE(sum(l.expected_revenue), 0)
      FROM leads l
     GROUP BY COALESCE(l.status, 'new');
$$;


-- =============================================================================
-- SECTION 10  ::  VIEWS
-- Reporting layer mirroring what /api/analytics, /api/reports and /api/admin
-- compute in Python.
-- =============================================================================

-- 10.1 One row per lead: the full cross-table picture ------------------------
CREATE OR REPLACE VIEW v_lead_pipeline AS
SELECT
    l.id                       AS lead_id,
    l.title,
    l.company,
    l.client_name,
    l.country,
    l.platform,
    l.status,
    l.urgency,
    l.risk_level,
    l.job_type,
    l.technologies,
    l.skills,
    l.tags,
    l.email,
    l.budget_min,
    l.budget_max,
    l.expected_revenue,
    l.success_probability,
    l.difficulty,
    l.competition,
    l.url,
    l.found_at,
    l.analyzed_at,
    p.id                       AS proposal_id,
    p.status                   AS proposal_status,
    p.win_probability,
    p.submitted_at,
    s.enrolled                 AS outreach_enrolled,
    s.current_step             AS outreach_step,
    s.status                   AS outreach_state,
    s.last_sent_at,
    s.next_due_at,
    (SELECT count(*) FROM outreach o WHERE o.lead_id = l.id)                       AS outreach_touches,
    (SELECT max(o.sent_at)   FROM outreach o WHERE o.lead_id = l.id)                AS last_touch_at,
    (SELECT max(o.replied_at) FROM outreach o WHERE o.lead_id = l.id)               AS last_reply_at,
    ci.lifecycle               AS acie_lifecycle,
    ci.channel                 AS acie_channel,
    ci.email                   AS acie_email,
    ci.contact_confidence      AS acie_confidence,
    mbpw_confidence_tier(ci.contact_confidence)                                    AS acie_tier,
    ci.supply_status           AS acie_supply_status,
    ci.verification_status     AS acie_verification_status,
    ci.bounce_count            AS acie_bounce_count,
    mbpw_can_send(l.id)        AS acie_gate_pass
FROM leads l
LEFT JOIN proposals      p  ON p.lead_id  = l.id
LEFT JOIN outreach_states s ON s.lead_id  = l.id
LEFT JOIN contact_intel  ci ON ci.lead_id = l.id;

COMMENT ON VIEW v_lead_pipeline IS
    'Densified lead table: lead + latest proposal + cadence state + ACIE decision. Use instead of the ORM relationship graph (proposals is 1:N but the ORM backref resolves to the first row).';

-- 10.2 System KPIs — port of GET /api/admin/system/stats --------------------
CREATE OR REPLACE VIEW v_system_stats AS
SELECT
    (SELECT count(*) FROM leads)                                  AS total_leads,
    (SELECT count(*) FROM proposals)                              AS total_proposals,
    (SELECT count(*) FROM companies)                              AS total_companies,
    (SELECT count(*) FROM contacts)                               AS total_contacts,
    (SELECT count(*) FROM users)                                  AS total_users,
    (SELECT count(*) FROM notifications)                          AS total_notifications,
    (SELECT count(*) FROM connectors)                             AS total_connectors,
    (SELECT count(*) FROM agent_logs)                             AS total_agent_logs,
    (SELECT count(*) FROM knowledge_base)                         AS total_knowledge_entries,
    (SELECT count(*) FROM sessions WHERE is_active)               AS active_sessions,
    (SELECT count(*) FROM leads
      WHERE found_at >= (now() AT TIME ZONE 'utc')::DATE)          AS today_leads,
    (SELECT count(*) FROM proposals
      WHERE created_at >= (now() AT TIME ZONE 'utc')::DATE)       AS today_proposals,
    (now() AT TIME ZONE 'utc')                                     AS generated_at;

-- 10.3 Pipeline report — port of GET /api/reports/pipeline ------------------
CREATE OR REPLACE VIEW v_pipeline_report AS
SELECT
    COALESCE(l.status, 'new')      AS stage,
    r.label                        AS stage_label,
    r.sort_order,
    count(*)::BIGINT               AS lead_count,
    COALESCE(sum(l.expected_revenue), 0) AS pipeline_value,
    count(*) FILTER (WHERE l.status = 'won')::BIGINT  AS won,
    round(100.0 * count(*) FILTER (WHERE l.status = 'won')
          / NULLIF(count(*), 0), 1)                    AS conversion_pct
FROM leads l
LEFT JOIN ref_lead_status r ON r.code = COALESCE(l.status, 'new')
GROUP BY COALESCE(l.status, 'new'), r.label, r.sort_order;

-- 10.4 Platform breakdown — port of GET /api/analytics/platforms ------------
CREATE OR REPLACE VIEW v_platform_breakdown AS
SELECT
    l.platform,
    s.display_name,
    count(*)::BIGINT                                        AS leads,
    COALESCE(sum(l.expected_revenue), 0)                    AS expected_revenue,
    max(l.found_at)                                         AS last_seen_at
FROM leads l
LEFT JOIN ref_lead_source s ON s.code = l.platform
WHERE l.platform IS NOT NULL AND l.platform <> ''
GROUP BY l.platform, s.display_name
ORDER BY leads DESC;

-- 10.5 Country breakdown — port of GET /api/analytics/countries -------------
CREATE OR REPLACE VIEW v_country_breakdown AS
SELECT
    l.country,
    count(*)::BIGINT                                     AS lead_count,
    COALESCE(sum(l.expected_revenue), 0)                 AS revenue,
    round(avg(l.success_probability)::numeric, 1)::double precision AS avg_success_probability,
    round(avg(l.budget_max))                             AS avg_budget_max
FROM leads l
WHERE l.country IS NOT NULL AND l.country <> ''
GROUP BY l.country
ORDER BY lead_count DESC;

-- 10.6 Technology breakdown — what /api/analytics/technologies counts in Python
CREATE OR REPLACE VIEW v_technology_breakdown AS
SELECT
    t.value                                   AS technology,
    count(*)::BIGINT                          AS lead_count
FROM leads l
CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(l.technologies, '[]'::jsonb)) AS t(value)
GROUP BY t.value
ORDER BY lead_count DESC;

COMMENT ON VIEW v_technology_breakdown IS
    'Replacement for iterating Lead.technologies in Python (analytics.py). Also the fix for the SQLAlchemy .any() incompatibility noted on leads.technologies.';

-- 10.7 Agent performance — port of GET /api/analytics/agents ----------------
CREATE OR REPLACE VIEW v_agent_performance AS
SELECT
    a.code                              AS agent_id,
    a.name                              AS agent_name,
    a.kind                              AS agent_type,
    count(l.id)                         AS tasks_completed,
    max(l.timestamp)                    AS last_active,
    count(*) FILTER (WHERE l.status = 'error')::BIGINT AS errors,
    count(*) FILTER (WHERE l.status = 'success')::BIGINT AS successes
FROM ref_agent a
LEFT JOIN agent_logs l ON l.agent_id = a.code
GROUP BY a.code, a.name, a.kind
ORDER BY a.code;

-- 10.8 Outreach send queue — what GET /api/outreach/cron will process --------
CREATE OR REPLACE VIEW v_outreach_queue AS
SELECT
    s.lead_id,
    l.company,
    l.client_name,
    COALESCE(NULLIF(ci.email, ''), l.email)                    AS target_email,
    mbpw_email_syntax_ok(COALESCE(NULLIF(ci.email, ''), l.email)) AS syntax_ok,
    COALESCE(ci.channel, 'email')                              AS channel,
    COALESCE(ci.contact_confidence, 0)                         AS confidence,
    s.current_step,
    (s.current_step + 1)                                       AS next_step,
    c.day_offset                                              AS next_day_offset,
    c.channel                                                  AS planned_channel,
    c.label                                                    AS planned_label,
    s.next_due_at,
    mbpw_compute_next_due(s.lead_id)                           AS computed_next_due,
    mbpw_can_send(s.lead_id)                                   AS gate_pass
FROM outreach_states s
JOIN leads l               ON l.id = s.lead_id
LEFT JOIN contact_intel ci ON ci.lead_id = s.lead_id
LEFT JOIN ref_outreach_cadence c ON c.step = s.current_step + 1
WHERE s.enrolled
  AND s.status = 'active'
  AND (s.next_due_at IS NULL OR s.next_due_at <= (now() AT TIME ZONE 'utc'))
ORDER BY s.next_due_at NULLS FIRST;

-- 10.9 Outreach effectiveness -----------------------------------------------
CREATE OR REPLACE VIEW v_outreach_performance AS
SELECT
    o.channel,
    o.step,
    o.step_label,
    count(*)::BIGINT                                              AS total,
    count(*) FILTER (WHERE o.status = 'sent')::BIGINT             AS sent,
    count(*) FILTER (WHERE o.status = 'simulated')::BIGINT        AS simulated,
    count(*) FILTER (WHERE o.status = 'logged')::BIGINT           AS logged,
    count(*) FILTER (WHERE o.status = 'replied')::BIGINT          AS replied,
    count(*) FILTER (WHERE o.status = 'failed')::BIGINT           AS failed,
    round(100.0 * count(*) FILTER (WHERE o.status = 'replied')
          / NULLIF(count(*), 0), 1)                               AS reply_rate_pct
FROM outreach o
GROUP BY o.channel, o.step, o.step_label
ORDER BY o.step, o.channel;

-- 10.10 Monthly revenue — port of GET /api/analytics/revenue ----------------
CREATE OR REPLACE VIEW v_monthly_revenue AS
SELECT
    to_char(d.month_start, 'YYYY-MM')                                       AS month,
    COALESCE((
        SELECT sum(l.expected_revenue)
          FROM leads l
         WHERE l.status = 'won'
           AND date_trunc('month', l.found_at) = d.month_start
    ), 0)                                                                    AS revenue,
    COALESCE((
        SELECT count(*)
          FROM proposals p
         WHERE date_trunc('month', p.created_at) = d.month_start
    ), 0)                                                                    AS proposals
FROM generate_series(
         date_trunc('month', (now() AT TIME ZONE 'utc') - INTERVAL '11 months'),
         date_trunc('month',  (now() AT TIME ZONE 'utc')),
         INTERVAL '1 month'
     ) AS d(month_start);


-- =============================================================================
-- SECTION 11  ::  SEED DATA  (idempotent)
-- =============================================================================

-- 11.1 app_config — every key the application reads, with its code default -----
INSERT INTO app_config ("key", value) VALUES
    ('outreach_automation_enabled', 'true'),   -- outreach_automation.AUTOMATION_FLAG (default "true")
    ('act.gate.enabled',             'on'),     -- compliance.GATE_ENABLED  (default "on")
    ('act.gate.frequency_max',       '4'),      -- compliance.FREQ_MAX      (default 4 / 30 days)
    ('act.gate.reply_cooloff_days',  '90'),     -- compliance.REPLY_COOLOFF (default 90)
    ('act.gate.dnc_companies',       '[]'),     -- JSON: [{"company":"...","reason":"..."}]
    -- Integration secrets. Leave empty and supply via /api/settings or env vars.
    ('hunter_api_key',   ''),
    ('apollo_api_key',   ''),
    ('hubspot_api_key',  ''),
    ('hubspot_client_id',     ''),
    ('hubspot_client_secret', ''),
    ('hubspot_redirect_uri',  ''),
    ('hubspot_app_id',        ''),
    ('hubspot_access_token',  ''),
    ('hubspot_refresh_token', ''),
    ('hubspot_token_expires_at', '')
ON CONFLICT ("key") DO NOTHING;

-- 11.2 ref_lead_status -------------------------------------------------------
INSERT INTO ref_lead_status (code, label, sort_order, is_terminal) VALUES
    ('new',           'New',           1, FALSE),
    ('analyzing',     'Analyzing',     2, FALSE),
    ('qualified',     'Qualified',     3, FALSE),
    ('proposal_sent', 'Proposal Sent', 4, FALSE),
    ('negotiation',   'Negotiation',   5, FALSE),
    ('won',           'Won',           6, TRUE),
    ('lost',          'Lost',          7, TRUE),
    ('archived',      'Archived',      8, TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_job_type (code, label) VALUES
    ('remote','Remote'), ('hybrid','Hybrid'), ('onsite','On-site'),
    ('contract','Contract'), ('freelance','Freelance'),
    ('full_time','Full-time'), ('part_time','Part-time')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_risk_level (code, label) VALUES
    ('low','Low'), ('medium','Medium'), ('high','High'), ('very_high','Very high')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_urgency (code, label, rank) VALUES
    ('low','Low',1), ('medium','Medium',2), ('high','High',3), ('critical','Critical',4)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_user_role (code, label, level) VALUES
    ('user','User',0), ('admin','Admin',1), ('superadmin','Superadmin',2)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_notification_type (code, label) VALUES
    ('system','System'), ('high_value','High value'), ('urgent','Urgent'),
    ('agent','Agent'), ('new_lead','New lead'), ('follow_up','Follow-up'),
    ('government','Government'), ('enterprise','Enterprise')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_priority (code, label, rank) VALUES
    ('low','Low',1), ('medium','Medium',2), ('high','High',3)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_connector_type (code, label) VALUES
    ('api','JSON API'), ('rss','RSS feed'), ('ats','ATS API'),
    ('scraper','Scraper'), ('webhook','Webhook')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_connector_status (code, label) VALUES
    ('active','Active'), ('inactive','Inactive'), ('syncing','Syncing'), ('error','Error')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_outreach_channel (code, label) VALUES
    ('email','Email'), ('linkedin','LinkedIn'), ('phone','Phone'), ('whatsapp','WhatsApp')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_outreach_record_status (code, label) VALUES
    ('sent','Sent via SMTP'), ('simulated','Simulated (no SMTP)'),
    ('logged','Logged for manual action'), ('replied','Replied'), ('failed','Failed')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_outreach_state (code, label, description) VALUES
    ('active',     'Active',     'Scheduled for the next due touch.'),
    ('paused',     'Paused',     'Manually paused; enrolled = false.'),
    ('needs_email','Needs email','Parked: ACIE could not resolve a deliverable address.'),
    ('completed',  'Completed',  'Cadence exhausted or lead gone.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_acie_lifecycle (code, description, terminal) VALUES
    ('NEW','Freshly created record.',FALSE),
    ('DISCOVERED','Lead found by a hunter source.',FALSE),
    ('RESOLVED','Company/domain/name identity resolved.',FALSE),
    ('VERIFIED','Evidence verified by a provider.',FALSE),
    ('SCORED','Confidence computed.',FALSE),
    ('OUTREACH_READY','HIGH tier + compliance gate passed.',FALSE),
    ('REVIEW_ALT','MEDIUM tier — needs human review / alt channel.',FALSE),
    ('LOW_SUPPRESS','LOW tier — do not contact.',TRUE),
    ('SUPPRESSED','Blocked by the compliance gate.',TRUE),
    ('REPLIED','Contact replied.',FALSE),
    ('BOUNCED','Address bounced.',TRUE),
    ('UNSUBSCRIBED','Opted out.',TRUE),
    ('JOB_CHANGE','Person changed role.',FALSE),
    ('STALE','Not contacted for 120 days.',FALSE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_supply_status (code, label, blocks_send) VALUES
    ('ok','OK',FALSE),
    ('bounced','Bounced',TRUE),
    ('opted_out','Opted out',TRUE),
    ('suppressed','Suppressed',TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_verification_status (code, label) VALUES
    ('unknown','Unknown'), ('none','None'), ('valid','Valid'),
    ('invalid','Invalid'), ('risky','Risky'), ('catch_all','Catch-all'),
    ('disposable','Disposable')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_feedback_outcome (code, label, counts_for_cap, event_type, bumps_lifecycle) VALUES
    ('no_response',    'No response',   FALSE, NULL,      NULL),
    ('sent',           'Sent',          TRUE,  'deliver', NULL),
    ('opened',         'Opened',        TRUE,  'deliver', NULL),
    ('deliver',        'Delivered',     FALSE, 'deliver', NULL),
    ('bounce',         'Bounced',       FALSE, 'bounce',  'BOUNCED'),
    ('invalid',        'Invalid address',FALSE, 'bounce', NULL),
    ('verify_fail',    'Verification failed', FALSE, 'bounce', NULL),
    ('reply_positive', 'Positive reply',FALSE, 'deliver', 'REPLIED'),
    ('reply_negative', 'Negative reply',FALSE, 'deliver', 'REPLIED'),
    ('replied',        'Replied',       FALSE, NULL,      'REPLIED'),
    ('unsubscribe',    'Unsubscribed',  FALSE, NULL,      'UNSUBSCRIBED'),
    ('opt_out',        'Opted out',     FALSE, NULL,      'UNSUBSCRIBED'),
    ('job_change',     'Job change',    FALSE, NULL,      'JOB_CHANGE')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_provider (code, label, kind, requires_key) VALUES
    ('web',           'Website scrape',    'email', FALSE),
    ('doh',           'DNS-over-HTTPS MX', 'email', FALSE),
    ('apollo',        'Apollo.io',         'email', TRUE),
    ('hunter',        'Hunter.io',         'email', TRUE),
    ('twilio_lookup', 'Twilio Lookup',     'phone', TRUE),
    ('lead',          'Lead record itself','email', FALSE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_agent (code, name, kind, description, icon) VALUES
    ('agent-1','Global Opportunity Hunter','opportunity_hunter',
     'Continuously searches worldwide job boards for new IT and business opportunities.','🌐'),
    ('agent-2','Lead Analyzer','lead_analyzer',
     'Deep analyzes each discovered lead to assess viability, calculate success probability, and determine expected revenue.','🔍'),
    ('agent-3','Proposal Generator','proposal_generator',
     'Creates customized, professional proposals for qualified leads.','📝')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref_knowledge_type (code, label) VALUES
    ('playbook','Playbook'), ('industry_knowledge','Industry knowledge'),
    ('past_win','Past win'), ('past_loss','Past loss'), ('client_history','Client history')
ON CONFLICT (code) DO NOTHING;

-- 11.3 ref_outreach_cadence — mirror of outreach_service.CADENCE -------------
INSERT INTO ref_outreach_cadence (step, day_offset, channel, label, goal) VALUES
    (0,  0, 'email',    'First touch - intro & value',  'Introduce MBPW and reference the specific project by name.'),
    (1,  3, 'email',    'Value add - concrete insight','Share a relevant approach/risk note for their challenge.'),
    (2,  7, 'linkedin', 'Social touch - connect',      'Connect / engage on LinkedIn to stay visible.'),
    (3, 14, 'email',    'Final nudge - proof point',   'Share a result and a low-friction next step, then step back.')
ON CONFLICT (step) DO NOTHING;

-- 11.4 ref_lead_source — the 17 registered sources (services/sources/__init__.py)
INSERT INTO ref_lead_source (code, display_name, source_type, homepage, requires_key) VALUES
    ('adzuna',         'Adzuna',             'api', 'https://adzuna.com',          TRUE),
    ('arbeitnow',      'Arbeitnow',          'api', 'https://www.arbeitnow.com',   FALSE),
    ('ashby',          'Ashby ATS',          'ats', 'https://ashbyhq.com',         FALSE),
    ('europeremotely', 'Europe Remotely',    'rss', 'https://europeremotely.com',  FALSE),
    ('findwork',       'Findwork',           'api', 'https://findwork.dev',        FALSE),
    ('greenhouse',     'Greenhouse ATS',     'ats', 'https://greenhouse.io',       FALSE),
    ('himalayas',      'Himalayas',          'api', 'https://himalayas.app',       FALSE),
    ('hn_hiring',      'HN Who''s Hiring',   'api', 'https://news.ycombinator.com',FALSE),
    ('jobspresso',     'Jobspresso',         'rss', 'https://jobspresso.co',       FALSE),
    ('jooble',         'Jooble',             'api', 'https://jooble.org',          TRUE),
    ('lever',          'Lever ATS',          'ats', 'https://lever.co',            FALSE),
    ('remoteok',       'RemoteOK',           'rss', 'https://remoteok.com',        FALSE),
    ('remoteco',       'Remote.co',          'rss', 'https://remote.co',           FALSE),
    ('remotive',       'Remotive',           'rss', 'https://remotive.com',        FALSE),
    ('upwork',         'Upwork',             'rss', 'https://www.upwork.com',      FALSE),
    ('weworkremotely', 'We Work Remotely',   'rss', 'https://weworkremotely.com',  FALSE),
    ('workingnomads',  'Working Nomads',     'rss', 'https://www.workingnomads.co',FALSE)
ON CONFLICT (code) DO NOTHING;

-- 11.5 connectors — one per keyless source, ready for POST /api/connectors/{id}/sync
--     `platform` MUST equal ref_lead_source.code, otherwise sync_source() fails.
INSERT INTO connectors (id, name, type, platform, status, config) VALUES
    ('conn-himalayas',      'Himalayas',           'api', 'himalayas',      'inactive', '{}'),
    ('conn-remoteok',       'RemoteOK',            'rss', 'remoteok',       'inactive', '{}'),
    ('conn-remotive',       'Remotive',            'rss', 'remotive',       'inactive', '{}'),
    ('conn-weworkremotely', 'We Work Remotely',    'rss', 'weworkremotely', 'inactive', '{}'),
    ('conn-arbeitnow',      'Arbeitnow',           'api', 'arbeitnow',      'inactive', '{}'),
    ('conn-findwork',       'Findwork',            'api', 'findwork',       'inactive', '{}'),
    ('conn-greenhouse',     'Greenhouse ATS',      'ats', 'greenhouse',     'inactive', '{}'),
    ('conn-lever',          'Lever ATS',           'ats', 'lever',          'inactive', '{}'),
    ('conn-ashby',          'Ashby ATS',           'ats', 'ashby',          'inactive', '{}'),
    ('conn-hn-hiring',      'HN Who''s Hiring',    'api', 'hn_hiring',      'inactive', '{}'),
    ('conn-jobspresso',     'Jobspresso',          'rss', 'jobspresso',     'inactive', '{}'),
    ('conn-remoteco',       'Remote.co',           'rss', 'remoteco',       'inactive', '{}'),
    ('conn-europeremotely', 'Europe Remotely',     'rss', 'europeremotely', 'inactive', '{}'),
    ('conn-workingnomads',  'Working Nomads',      'rss', 'workingnomads',  'inactive', '{}'),
    ('conn-upwork',         'Upwork',              'rss', 'upwork',         'inactive', '{}')
ON CONFLICT (id) DO NOTHING;

-- Keyed sources (Adzuna, Jooble) are intentionally NOT seeded: they are skipped by
-- sync_all_sources() because requires_key = true.

-- 11.6 First superadmin ------------------------------------------------------
-- The app NEVER creates default credentials (models/seed.py: it requires
-- ADMIN_INITIAL_PASSWORD). Passwords are bcrypt digests produced by
-- passlib CryptContext(schemes=["bcrypt"]). Generate one with:
--     python -c "from passlib.context import CryptContext; \
--                print(CryptContext(schemes=['bcrypt']).hash('YourPassword'))"
-- then paste it below, or simply start the API with ADMIN_INITIAL_PASSWORD set
-- and let seed.py insert the row for you.
--
-- INSERT INTO users (id, email, name, role, hashed_password, is_active, created_at)
-- VALUES (
--     'REPLACE-WITH-UUID4',
--     'admin@mbpw.com',
--     'Admin',
--     'superadmin',
--     'REPLACE-WITH-BCRYPT-HASH',
--     TRUE,
--     (now() AT TIME ZONE 'utc')
-- );

-- 11.7 provider_performance — nothing pre-seeded: learn.py starts every unknown
--     provider at 0.5 reliability, so an empty table is the correct state.


-- =============================================================================
-- SECTION 12  ::  GRANTS
-- =============================================================================

GRANT USAGE ON SCHEMA mbpw TO mbpw_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA mbpw TO mbpw_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA mbpw TO mbpw_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA mbpw TO mbpw_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA mbpw
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mbpw_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA mbpw
    GRANT USAGE, SELECT ON SEQUENCES TO mbpw_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA mbpw
    GRANT EXECUTE ON FUNCTIONS TO mbpw_app;

-- Read-only analytics role (optional)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mbpw_readonly') THEN
        CREATE ROLE mbpw_readonly NOLOGIN;
    END IF;
END
$$;
GRANT USAGE ON SCHEMA mbpw TO mbpw_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mbpw TO mbpw_readonly;


-- =============================================================================
-- SECTION 13  ::  OPTIONAL STRICT MODE  —  DO NOT RUN WITHOUT AUDITING
-- -----------------------------------------------------------------------------
-- Read §1 note 1 first. The application intentionally tolerates dangling ids,
-- so turning these on will surface as HTTP 500s on the code paths listed there.
-- Recommended rollout: clean the data first, then enable table by table.
-- =============================================================================

-- 13.1 CHECK constraints ------------------------------------------------------
-- ALTER TABLE leads
--     ADD CONSTRAINT ck_leads_status        CHECK (status IN (SELECT code FROM ref_lead_status)),
--     ADD CONSTRAINT ck_leads_job_type      CHECK (job_type IS NULL OR job_type IN (SELECT code FROM ref_job_type)),
--     ADD CONSTRAINT ck_leads_risk_level    CHECK (risk_level IN (SELECT code FROM ref_risk_level)),
--     ADD CONSTRAINT ck_leads_urgency       CHECK (urgency IN (SELECT code FROM ref_urgency)),
--     ADD CONSTRAINT ck_leads_probability   CHECK (success_probability BETWEEN 0 AND 100),
--     ADD CONSTRAINT ck_leads_difficulty    CHECK (difficulty BETWEEN 0 AND 100),
--     ADD CONSTRAINT ck_leads_technologies  CHECK (jsonb_typeof(technologies) = 'array'),
--     ADD CONSTRAINT ck_leads_tags          CHECK (jsonb_typeof(tags) = 'array');
--
-- ALTER TABLE users          ADD CONSTRAINT ck_users_role CHECK (role IN ('user','admin','superadmin'));
-- ALTER TABLE proposals      ADD CONSTRAINT ck_proposals_status CHECK (status IN ('draft','review','submitted','accepted','rejected'));
-- ALTER TABLE notifications  ADD CONSTRAINT ck_notifications_read CHECK ("read" IN (TRUE, FALSE));
-- ALTER TABLE outreach       ADD CONSTRAINT ck_outreach_status CHECK (status IN ('sent','simulated','logged','replied','failed'));
-- ALTER TABLE outreach_states ADD CONSTRAINT ck_outreach_states_status CHECK (status IN ('active','paused','needs_email','completed'));
-- ALTER TABLE contact_intel  ADD CONSTRAINT ck_contact_intel_supply_status CHECK (supply_status IN ('ok','bounced','opted_out','suppressed'));

-- 13.2 Foreign keys ------------------------------------------------------------
-- Start with the ones that are safe (lead_id is always a real uuid4 there):
-- ALTER TABLE contact_intel   ADD CONSTRAINT fk_contact_intel_lead   FOREIGN KEY (lead_id)   REFERENCES leads(id) ON DELETE CASCADE;
-- ALTER TABLE outreach_states ADD CONSTRAINT fk_outreach_states_lead FOREIGN KEY (lead_id)   REFERENCES leads(id) ON DELETE CASCADE;
--
-- Careful with these two — see §1 note 1:
-- ALTER TABLE outreach   ADD CONSTRAINT fk_outreach_lead   FOREIGN KEY (lead_id) REFERENCES leads(id) ON DELETE CASCADE;  -- rows exist with lead_id = ''
-- ALTER TABLE contacts   ADD CONSTRAINT fk_contacts_company FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; -- companyId is unvalidated
-- ALTER TABLE proposals  ADD CONSTRAINT fk_proposals_lead FOREIGN KEY (lead_id) REFERENCES leads(id) ON DELETE SET NULL; -- '' is written by POST /generate


-- =============================================================================
-- SECTION 14  ::  VERIFICATION
-- =============================================================================

SELECT 'tables'  AS object, count(*) AS n FROM information_schema.tables
 WHERE table_schema = 'mbpw' AND table_type = 'BASE TABLE'
UNION ALL
SELECT 'views',   count(*) FROM information_schema.views WHERE table_schema = 'mbpw'
UNION ALL
SELECT 'functions', count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'mbpw'
UNION ALL
SELECT 'indexes',  count(*) FROM pg_indexes WHERE schemaname = 'mbpw'
UNION ALL
SELECT 'triggers', count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'mbpw' AND NOT t.tgisinternal;

-- Expected: 38 base tables = 17 application tables + 21 ref_* lookup tables.

SELECT * FROM v_system_stats;
SELECT * FROM v_pipeline_report ORDER BY sort_order NULLS LAST;
SELECT * FROM v_platform_breakdown LIMIT 10;
SELECT * FROM v_technology_breakdown LIMIT 10;
SELECT * FROM v_agent_performance;
SELECT * FROM v_outreach_queue LIMIT 20;
SELECT * FROM mbpw_compliance_gate('REPLACE-WITH-A-LEAD-ID');

\echo '--- MBPW schema ready. Point DATABASE_URL at this database and start the API. ---'
