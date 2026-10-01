-- =============================================================================
--  MBPW  ::  MMA Business Prosperity Weapon
--  SQLite schema (local development / no-Postgres mode)
-- =============================================================================
--  backend/app/models/database.py falls back to SQLite when DATABASE_URL is unset:
--      sqlite:///./mbpw.db   (persistent dev)
--      sqlite://             (ephemeral in-memory, StaticPool - Vercel default)
--
--  This file is the byte-exact DDL that
--      Base.metadata.create_all(bind=engine)
--  emits for the SQLite dialect. Use it only for local dev; the production /
--  docker-compose stack targets PostgreSQL (see mbpw_postgres.sql, which adds
--  indexes, triggers, views, functions, lookup tables and seed data).
--
--  HOW TO RUN
--  -----------
--      sqlite3 mbpw.db < database/mbpw_sqlite.sql
--
--  SQLite notes
--  ------------
--  * There is no ALTER COLUMN in SQLite, so schema changes mean table rebuilds.
--  * `updated_at` has no trigger here (SQLite cannot ALTER to add one easily and
--    the ORM's onupdate=datetime.utcnow already handles it).
--  * JSON columns are TEXT with a JSON check - SQLite's JSON1 extension reads
--    them via json_each()/json_extract() at query time.
--  * No foreign keys are declared: SQLite has FKs off by default and the ORM
--    models mark every relationship "FK handled at app level" anyway.
--  * To enable FK enforcement:  PRAGMA foreign_keys = ON;
-- =============================================================================

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;


-- agent_logs
CREATE TABLE agent_logs (
	id VARCHAR NOT NULL, 
	agent_id VARCHAR, 
	action VARCHAR, 
	details TEXT, 
	status VARCHAR, 
	timestamp DATETIME, 
	PRIMARY KEY (id)
);

-- app_config
CREATE TABLE app_config (
	"key" VARCHAR NOT NULL, 
	value TEXT, 
	updated_at DATETIME, 
	PRIMARY KEY ("key")
);

-- audit_logs
CREATE TABLE audit_logs (
	id VARCHAR NOT NULL, 
	user_id VARCHAR NOT NULL, 
	action VARCHAR NOT NULL, 
	resource VARCHAR, 
	resource_id VARCHAR, 
	details VARCHAR, 
	ip_address VARCHAR, 
	created_at DATETIME, 
	PRIMARY KEY (id)
);

-- companies
CREATE TABLE companies (
	id VARCHAR NOT NULL, 
	name VARCHAR NOT NULL, 
	industry VARCHAR, 
	country VARCHAR, 
	website VARCHAR, 
	revenue FLOAT, 
	status VARCHAR, 
	notes TEXT, 
	created_at DATETIME, 
	PRIMARY KEY (id)
);

-- connectors
CREATE TABLE connectors (
	id VARCHAR NOT NULL, 
	name VARCHAR NOT NULL, 
	type VARCHAR NOT NULL, 
	platform VARCHAR, 
	status VARCHAR, 
	config JSON, 
	last_sync_at DATETIME, 
	sync_count INTEGER, 
	leads_found INTEGER, 
	error_message TEXT, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (id)
);

-- contact_intel
CREATE TABLE contact_intel (
	lead_id VARCHAR NOT NULL, 
	person_id VARCHAR, 
	name VARCHAR, 
	company VARCHAR, 
	domain VARCHAR, 
	title VARCHAR, 
	email VARCHAR, 
	phone VARCHAR, 
	lifecycle VARCHAR, 
	channel VARCHAR, 
	contact_confidence FLOAT, 
	identity_confidence FLOAT, 
	employment_confidence FLOAT, 
	email_confidence FLOAT, 
	phone_confidence FLOAT, 
	risk_score FLOAT, 
	freshness_score FLOAT, 
	verification_status VARCHAR, 
	supply_status VARCHAR, 
	provider VARCHAR, 
	profile JSON, 
	last_contacted DATETIME, 
	last_verified DATETIME, 
	next_verification DATETIME, 
	bounce_count INTEGER, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (lead_id)
);

-- contacts
CREATE TABLE contacts (
	id VARCHAR NOT NULL, 
	name VARCHAR NOT NULL, 
	email VARCHAR, 
	phone VARCHAR, 
	role VARCHAR, 
	company_id VARCHAR, 
	PRIMARY KEY (id)
);

-- knowledge_base
CREATE TABLE knowledge_base (
	id VARCHAR NOT NULL, 
	title VARCHAR NOT NULL, 
	entry_type VARCHAR NOT NULL, 
	content TEXT NOT NULL, 
	tags JSON, 
	source VARCHAR, 
	source_url VARCHAR, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (id)
);

-- leads
CREATE TABLE leads (
	id VARCHAR NOT NULL, 
	title VARCHAR NOT NULL, 
	description TEXT, 
	client_name VARCHAR, 
	company VARCHAR, 
	email VARCHAR, 
	phone VARCHAR, 
	country VARCHAR, 
	budget_min FLOAT, 
	budget_max FLOAT, 
	deadline VARCHAR, 
	technologies JSON, 
	skills JSON, 
	platform VARCHAR, 
	job_type VARCHAR, 
	status VARCHAR, 
	urgency VARCHAR, 
	difficulty FLOAT, 
	success_probability FLOAT, 
	risk_level VARCHAR, 
	expected_revenue FLOAT, 
	competition INTEGER, 
	project_size VARCHAR, 
	payment_method VARCHAR, 
	client_history TEXT, 
	url VARCHAR, 
	notes TEXT, 
	tags JSON, 
	found_at DATETIME, 
	analyzed_at DATETIME, 
	PRIMARY KEY (id)
);

-- notifications
CREATE TABLE notifications (
	id VARCHAR NOT NULL, 
	type VARCHAR, 
	title VARCHAR, 
	message TEXT, 
	lead_id VARCHAR, 
	read BOOLEAN, 
	priority VARCHAR, 
	created_at DATETIME, 
	PRIMARY KEY (id)
);

-- outreach
CREATE TABLE outreach (
	id VARCHAR NOT NULL, 
	lead_id VARCHAR, 
	client_name VARCHAR, 
	company VARCHAR, 
	email VARCHAR, 
	channel VARCHAR, 
	step INTEGER, 
	step_label VARCHAR, 
	subject VARCHAR, 
	body_text TEXT, 
	status VARCHAR, 
	simulated BOOLEAN, 
	sent_at DATETIME, 
	replied_at DATETIME, 
	created_at DATETIME, 
	PRIMARY KEY (id)
);

-- outreach_feedback
CREATE TABLE outreach_feedback (
	id VARCHAR NOT NULL, 
	lead_id VARCHAR, 
	channel VARCHAR, 
	outcome VARCHAR, 
	provider VARCHAR, 
	confidence_at_time FLOAT, 
	detail TEXT, 
	created_at DATETIME, 
	PRIMARY KEY (id)
);

-- outreach_states
CREATE TABLE outreach_states (
	lead_id VARCHAR NOT NULL, 
	enrolled BOOLEAN, 
	current_step INTEGER, 
	status VARCHAR, 
	last_sent_at DATETIME, 
	next_due_at DATETIME, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (lead_id)
);

-- proposals
CREATE TABLE proposals (
	id VARCHAR NOT NULL, 
	lead_id VARCHAR, 
	title VARCHAR NOT NULL, 
	cover_letter TEXT, 
	introduction TEXT, 
	technical_plan TEXT, 
	timeline VARCHAR, 
	cost_estimate TEXT, 
	portfolio_suggestions JSON, 
	call_to_action TEXT, 
	win_probability FLOAT, 
	status VARCHAR, 
	created_at DATETIME, 
	submitted_at DATETIME, 
	PRIMARY KEY (id)
);

-- provider_performance
CREATE TABLE provider_performance (
	provider VARCHAR NOT NULL, 
	event_type VARCHAR NOT NULL, 
	count INTEGER, 
	weighted FLOAT, 
	updated_at DATETIME, 
	PRIMARY KEY (provider, event_type)
);

-- sessions
CREATE TABLE sessions (
	id VARCHAR NOT NULL, 
	user_id VARCHAR NOT NULL, 
	token VARCHAR NOT NULL, 
	device VARCHAR, 
	ip_address VARCHAR, 
	created_at DATETIME, 
	expires_at DATETIME NOT NULL, 
	is_active BOOLEAN, 
	PRIMARY KEY (id)
);

-- users
CREATE TABLE users (
	id VARCHAR NOT NULL, 
	email VARCHAR NOT NULL, 
	name VARCHAR NOT NULL, 
	role VARCHAR, 
	hashed_password VARCHAR NOT NULL, 
	is_active BOOLEAN, 
	created_at DATETIME, 
	last_login DATETIME, 
	avatar_url VARCHAR, 
	PRIMARY KEY (id), 
	UNIQUE (email)
);


COMMIT;
PRAGMA foreign_keys = ON;

-- -----------------------------------------------------------------------------
-- Development indexes (SQLite cannot index JSON arrays; the JSON1 extension is
-- used instead for tag/technology filters).
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_leads_found_at         ON leads (found_at DESC);
CREATE INDEX IF NOT EXISTS ix_leads_status           ON leads (status);
CREATE INDEX IF NOT EXISTS ix_leads_status_found     ON leads (status, found_at DESC);
CREATE INDEX IF NOT EXISTS ix_leads_platform         ON leads (platform);
CREATE INDEX IF NOT EXISTS ix_leads_country          ON leads (country);
CREATE INDEX IF NOT EXISTS ix_leads_analyzed_pending ON leads (found_at DESC) WHERE analyzed_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_leads_proposal_ready   ON leads (success_probability DESC)
    WHERE status IN ('analyzing', 'qualified');
CREATE INDEX IF NOT EXISTS ix_leads_missing_email    ON leads (found_at) WHERE email IS NULL OR email = '';
CREATE INDEX IF NOT EXISTS ix_proposals_lead_id      ON proposals (lead_id);
CREATE INDEX IF NOT EXISTS ix_proposals_created_at   ON proposals (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_lead_step     ON outreach (lead_id, step DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_created_at    ON outreach (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_outreach_states_due    ON outreach_states (next_due_at)
    WHERE enrolled AND status = 'active';
CREATE INDEX IF NOT EXISTS ix_notifications_created  ON notifications (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_notifications_unread   ON notifications (created_at DESC) WHERE "read" = 0;
CREATE INDEX IF NOT EXISTS ix_sessions_token         ON sessions (token);
CREATE INDEX IF NOT EXISTS ix_sessions_expires_at    ON sessions (expires_at);
CREATE INDEX IF NOT EXISTS ix_audit_logs_created_at  ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_agent_logs_agent_ts    ON agent_logs (agent_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS ix_contacts_company_id    ON contacts (company_id);
CREATE INDEX IF NOT EXISTS ix_connectors_status      ON connectors (status);
CREATE INDEX IF NOT EXISTS ix_contact_intel_lifecycle ON contact_intel (lifecycle);
CREATE INDEX IF NOT EXISTS ix_contact_intel_supply   ON contact_intel (supply_status);
CREATE INDEX IF NOT EXISTS ix_feedback_lead_ts       ON outreach_feedback (lead_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- Seed: the app_config keys the backend reads at runtime.
-- -----------------------------------------------------------------------------
INSERT OR IGNORE INTO app_config ("key", value) VALUES
    ('outreach_automation_enabled', 'true'),
    ('act.gate.enabled',            'on'),
    ('act.gate.frequency_max',      '4'),
    ('act.gate.reply_cooloff_days', '90'),
    ('act.gate.dnc_companies',      '[]'),
    ('hunter_api_key',  ''),
    ('apollo_api_key',  ''),
    ('hubspot_api_key', ''),
    ('hubspot_client_id',     ''),
    ('hubspot_client_secret', ''),
    ('hubspot_redirect_uri',  ''),
    ('hubspot_app_id',        ''),
    ('hubspot_access_token',  ''),
    ('hubspot_refresh_token', ''),
    ('hubspot_token_expires_at', '');

-- -----------------------------------------------------------------------------
-- Seed: one connector per keyless lead source (services/sources/__init__.py).
-- `platform` must equal the source code or POST /api/connectors/{id}/sync fails.
-- -----------------------------------------------------------------------------
INSERT OR IGNORE INTO connectors (id, name, type, platform, status, config, sync_count, leads_found, created_at, updated_at) VALUES
    ('conn-himalayas',      'Himalayas',        'api', 'himalayas',      'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-remoteok',       'RemoteOK',         'rss', 'remoteok',       'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-remotive',       'Remotive',         'rss', 'remotive',       'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-weworkremotely', 'We Work Remotely', 'rss', 'weworkremotely', 'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-arbeitnow',      'Arbeitnow',        'api', 'arbeitnow',      'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-findwork',       'Findwork',         'api', 'findwork',       'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-greenhouse',     'Greenhouse ATS',   'ats', 'greenhouse',     'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-lever',          'Lever ATS',        'ats', 'lever',          'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-ashby',          'Ashby ATS',        'ats', 'ashby',          'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-hn-hiring',      'HN Who''s Hiring', 'api', 'hn_hiring',      'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-jobspresso',     'Jobspresso',       'rss', 'jobspresso',     'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-remoteco',       'Remote.co',        'rss', 'remoteco',       'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-europeremotely', 'Europe Remotely',  'rss', 'europeremotely', 'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-workingnomads',  'Working Nomads',   'rss', 'workingnomads',  'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('conn-upwork',         'Upwork',           'rss', 'upwork',         'inactive', '{}', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

-- The app never creates default credentials (models/seed.py requires
-- ADMIN_INITIAL_PASSWORD). Passwords are passlib bcrypt digests:
--   python -c "from passlib.context import CryptContext; print(CryptContext(schemes=['bcrypt']).hash('YourPassword'))"
--
-- INSERT INTO users (id, email, name, role, hashed_password, is_active, created_at, last_login, avatar_url)
-- VALUES ('REPLACE-UUID4', 'admin@mbpw.com', 'Admin', 'superadmin',
--         'REPLACE-BCRYPT-HASH', 1, CURRENT_TIMESTAMP, NULL, '');

-- Verification
SELECT 'tables' AS object, count(*) AS n FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'
UNION ALL SELECT 'indexes', count(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';
-- Expected: 17 tables.
