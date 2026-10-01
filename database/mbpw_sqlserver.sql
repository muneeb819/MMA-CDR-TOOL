/* =============================================================================
   MBPW  ::  MMA Business Prosperity Weapon
   Microsoft SQL Server (T-SQL) schema + objects + seed data
   =============================================================================
   TARGET      : SQL Server 2016 or newer (uses OPENJSON / ISJSON / DROP+CREATE).
                 Written to avoid 2017+-only syntax so it also runs on 2012/2014
                 if you replace the OPENJSON sections.
   RUN         : SSMS  -> File > Open > this file > Execute (Ctrl+Shift+E)
                 sqlcmd -> sqlcmd -S localhost -E -b -i database\mbpw_sqlserver.sql
                          (add -U <login> -P <password> for SQL auth)
   SAFE BY DEFAULT
               * Every object is guarded (IF OBJECT_ID(...) IS NULL / IS NOT NULL)
                 so the script is fully re-runnable.
               * Login/database/user creation and GRANTs are wrapped in
                 TRY/CATCH: if you lack permission they print a NOTICE instead of
                 aborting the batch.
               * Uses only T-SQL. No GO-less assumptions, no psql directives.

   ENVIRONMENT VARIABLES THE APP EXPECTS
               DATABASE_URL, JWT_SECRET, ADMIN_EMAIL, ADMIN_INITIAL_PASSWORD,
               CRON_SECRET, OPENAI_API_KEY, SMTP_HOST/PORT/USER/PASSWORD/
               FROM_EMAIL/FROM_NAME, HUNTER_API_KEY, APOLLO_API_KEY,
               TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, HUBSPOT_*

   TRANSLATION NOTES (PostgreSQL -> SQL Server)
   ----------------------------------------------------------------------------
   1. BOOLEAN            -> BIT (0/1)
   2. TIMESTAMP (naive)  -> DATETIME2, default SYSUTCDATETIME()
   3. DOUBLE PRECISION   -> FLOAT
   4. TEXT               -> NVARCHAR(MAX)  (TEXT is deprecated in SQL Server)
   5. JSON / JSONB       -> NVARCHAR(MAX) + CHECK (ISJSON(col) = 1)
                           There is no binary-JSON type and no GIN index, so the
                           array columns are projected into real child tables by
                           a trigger (lead_technologies / lead_tags /
                           knowledge_tags) which ARE indexed.
   6. Server-side arrays -> the child tables above.
   7. CREATE INDEX IF NOT EXISTS / DO $$ blocks -> IF OBJECT_ID + GO batches.
   8. ON CONFLICT DO NOTHING -> INSERT ... SELECT ... WHERE NOT EXISTS.
   9. pg_trgm ILIKE indexes -> none (no equivalent); ordinary indexes only.
                           Optional: add a FULLTEXT index, see Section 11.
  10. Column named "read"/"key" are bracketed ([read], [key]).
  11. The 800-byte limit on nonclustered index keys is respected: every indexed
      NVARCHAR column is <= 400 characters. sessions.token is NVARCHAR(MAX) and
      therefore NOT indexed (a JWT is ~500-900 bytes); it is only ever scanned
      on the small sessions table.
  12. NO FOREIGN KEYS / CHECK CONSTRAINTS by default, deliberately - the
      SQLAlchemy models mark every relationship "FK handled at app level" and the
      routers genuinely write dangling values (proposals.lead_id = '' from
      POST /api/proposals/generate; contacts.company_id echoed unvalidated).
      Section 11 ships them as an opt-in, commented block.
   ============================================================================= */

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   SECTION 1  ::  LOGIN, DATABASE, SCHEMA, USER
   ============================================================================= */

-- 1.1 Server login (master) ---------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'mbpw_app')
BEGIN
    BEGIN TRY
        CREATE LOGIN [mbpw_app] WITH PASSWORD = N'CHANGE_ME_mbpw_app_Password!',
                             CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
        PRINT 'Created login mbpw_app - change the password before going live.';
    END TRY
    BEGIN CATCH
        PRINT 'NOTICE: could not create login mbpw_app (' + ERROR_MESSAGE()
            + '). Re-run this script as a sysadmin, or map an existing login.';
    END CATCH
END
GO

-- 1.2 Database ----------------------------------------------------------------
IF DB_ID(N'mbpw') IS NULL
BEGIN
    BEGIN TRY
        EXEC sp_executesql N'CREATE DATABASE [mbpw]';
        PRINT 'Created database mbpw.';
    END TRY
    BEGIN CATCH
        PRINT 'NOTICE: could not create database mbpw (' + ERROR_MESSAGE()
            + '). Create it manually and re-run.';
    END CATCH
END
GO

USE [mbpw];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1.3 Schema ------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'mbpw')
BEGIN
    EXEC sp_executesql N'CREATE SCHEMA [mbpw] AUTHORIZATION [dbo]';
END
GO

-- 1.4 Database user ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'mbpw_app')
BEGIN
    BEGIN TRY
        CREATE USER [mbpw_app] FOR LOGIN [mbpw_app] WITH DEFAULT_SCHEMA = [mbpw];
        EXEC sp_executesql N'ALTER ROLE [db_owner] ADD MEMBER [mbpw_app]';
    END TRY
    BEGIN CATCH
        PRINT 'NOTICE: could not create database user mbpw_app (' + ERROR_MESSAGE() + ').';
    END CATCH
END
GO

/* =============================================================================
   SECTION 2  ::  REFERENCE / LOOKUP TABLES
   These document the vocabularies the app hard-codes in Python. The application
   never reads them, so they are never enforced (see Section 11 for opt-in
   CHECK constraints that would).
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[ref_lead_status]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_lead_status] (
    [code]        NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_lead_status] PRIMARY KEY,
    [label]       NVARCHAR(128) NOT NULL,
    [sort_order]  INT           NOT NULL CONSTRAINT [df_ref_lead_status_sort] DEFAULT (0),
    [is_terminal] BIT           NOT NULL CONSTRAINT [df_ref_lead_status_term] DEFAULT (0),
    [source]      NVARCHAR(128) NOT NULL CONSTRAINT [df_ref_lead_status_src] DEFAULT (N'src/lib/types.ts')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_job_type]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_job_type] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_job_type] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_risk_level]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_risk_level] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_risk_level] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_urgency]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_urgency] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_urgency] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL,
    [rank]  INT           NOT NULL CONSTRAINT [df_ref_urgency_rank] DEFAULT (0)
);
GO

IF OBJECT_ID(N'[mbpw].[ref_user_role]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_user_role] (
    [code]   NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_user_role] PRIMARY KEY,
    [label]  NVARCHAR(128) NOT NULL,
    [level]  INT           NOT NULL,   -- 0 user | 1 admin | 2 superadmin
    [source] NVARCHAR(128) NOT NULL CONSTRAINT [df_ref_user_role_src] DEFAULT (N'app/routers/auth.py:require_role')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_notification_type]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_notification_type] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_notification_type] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_priority]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_priority] (
    [code]  NVARCHAR(16)  NOT NULL CONSTRAINT [pk_ref_priority] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL,
    [rank]  INT           NOT NULL CONSTRAINT [df_ref_priority_rank] DEFAULT (0)
);
GO

IF OBJECT_ID(N'[mbpw].[ref_connector_type]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_connector_type] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_connector_type] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_connector_status]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_connector_status] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_connector_status] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_outreach_channel]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_outreach_channel] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_outreach_channel] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_outreach_record_status]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_outreach_record_status] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_outreach_record_status] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_outreach_state]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_outreach_state] (
    [code]        NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_outreach_state] PRIMARY KEY,
    [label]       NVARCHAR(128) NOT NULL,
    [description] NVARCHAR(MAX) NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_acie_lifecycle]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_acie_lifecycle] (
    [code]        NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_acie_lifecycle] PRIMARY KEY,
    [description] NVARCHAR(MAX) NULL,
    [terminal]    BIT           NOT NULL CONSTRAINT [df_ref_acie_lifecycle_term] DEFAULT (0),
    [source]      NVARCHAR(64)  NOT NULL CONSTRAINT [df_ref_acie_lifecycle_src] DEFAULT (N'services/acie/constants.py:LIFECYCLE')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_supply_status]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_supply_status] (
    [code]        NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_supply_status] PRIMARY KEY,
    [label]       NVARCHAR(128) NOT NULL,
    [blocks_send] BIT           NOT NULL CONSTRAINT [df_ref_supply_status_blk] DEFAULT (0)
);
GO

IF OBJECT_ID(N'[mbpw].[ref_verification_status]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_verification_status] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_verification_status] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_feedback_outcome]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_feedback_outcome] (
    [code]            NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_feedback_outcome] PRIMARY KEY,
    [label]           NVARCHAR(128) NOT NULL,
    [counts_for_cap]  BIT           NOT NULL CONSTRAINT [df_ref_feedback_cap] DEFAULT (0),
    [event_type]      NVARCHAR(16)  NULL,      -- deliver | bounce | NULL
    [bumps_lifecycle] NVARCHAR(32)  NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_provider]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_provider] (
    [code]         NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_provider] PRIMARY KEY,
    [label]        NVARCHAR(128) NOT NULL,
    [kind]         NVARCHAR(16)  NOT NULL,     -- email | phone
    [requires_key] BIT           NOT NULL CONSTRAINT [df_ref_provider_key] DEFAULT (0),
    [active]       BIT           NOT NULL CONSTRAINT [df_ref_provider_act] DEFAULT (1),
    [source]       NVARCHAR(64)  NOT NULL CONSTRAINT [df_ref_provider_src] DEFAULT (N'services/acie/providers/registry.py')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_agent]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_agent] (
    [code]        NVARCHAR(16)  NOT NULL CONSTRAINT [pk_ref_agent] PRIMARY KEY,
    [name]        NVARCHAR(128) NOT NULL,
    [kind]        NVARCHAR(32)  NOT NULL,
    [description] NVARCHAR(MAX) NULL,
    [icon]        NVARCHAR(8)   NULL,
    [source]      NVARCHAR(64)  NOT NULL CONSTRAINT [df_ref_agent_src] DEFAULT (N'app/routers/agents.py:AGENT_DEFINITIONS')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_lead_source]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_lead_source] (
    [code]         NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_lead_source] PRIMARY KEY,
    [display_name] NVARCHAR(128) NOT NULL,
    [source_type]  NVARCHAR(16)  NOT NULL,      -- api | rss | ats
    [homepage]     NVARCHAR(512) NULL,
    [requires_key] BIT           NOT NULL CONSTRAINT [df_ref_lead_source_key] DEFAULT (0),
    [enabled]      BIT           NOT NULL CONSTRAINT [df_ref_lead_source_en] DEFAULT (1),
    [source]       NVARCHAR(64)  NOT NULL CONSTRAINT [df_ref_lead_source_src] DEFAULT (N'app/services/sources/__init__.py')
);
GO

IF OBJECT_ID(N'[mbpw].[ref_outreach_cadence]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_outreach_cadence] (
    [step]       INT           NOT NULL CONSTRAINT [pk_ref_outreach_cadence] PRIMARY KEY,
    [day_offset] INT           NOT NULL,
    [channel]    NVARCHAR(32)  NOT NULL,
    [label]      NVARCHAR(128) NOT NULL,
    [goal]       NVARCHAR(MAX) NOT NULL
);
GO

IF OBJECT_ID(N'[mbpw].[ref_knowledge_type]', N'U') IS NULL
CREATE TABLE [mbpw].[ref_knowledge_type] (
    [code]  NVARCHAR(32)  NOT NULL CONSTRAINT [pk_ref_knowledge_type] PRIMARY KEY,
    [label] NVARCHAR(128) NOT NULL
);
GO

/* =============================================================================
   SECTION 3  ::  IDENTITY, SECURITY & AUDIT      (app/routers/auth.py)
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[users]', N'U') IS NULL
CREATE TABLE [mbpw].[users] (
    [id]              NVARCHAR(64)  NOT NULL CONSTRAINT [pk_users] PRIMARY KEY,
    [email]           NVARCHAR(320) NOT NULL,
    [name]            NVARCHAR(400) NOT NULL,
    [role]            NVARCHAR(32)  NOT NULL CONSTRAINT [df_users_role] DEFAULT (N'user'),
    [hashed_password] NVARCHAR(255) NOT NULL,   -- passlib bcrypt digest
    [is_active]       BIT           NOT NULL CONSTRAINT [df_users_active] DEFAULT (1),
    [created_at]      DATETIME2     NOT NULL CONSTRAINT [df_users_created] DEFAULT (SYSUTCDATETIME()),
    [last_login]      DATETIME2     NULL,
    [avatar_url]      NVARCHAR(1024) NOT NULL CONSTRAINT [df_users_avatar] DEFAULT (N''),
    CONSTRAINT [uq_users_email] UNIQUE ([email])
);
GO

IF OBJECT_ID(N'[mbpw].[sessions]', N'U') IS NULL
CREATE TABLE [mbpw].[sessions] (
    [id]         NVARCHAR(64)   NOT NULL CONSTRAINT [pk_sessions] PRIMARY KEY,
    [user_id]    NVARCHAR(64)   NOT NULL,      -- deliberately not an FK (Section 11)
    [token]      NVARCHAR(MAX)  NOT NULL,      -- raw HS256 JWT; not indexable (>800 bytes)
    [device]     NVARCHAR(256)  NOT NULL CONSTRAINT [df_sessions_device] DEFAULT (N''),
    [ip_address] NVARCHAR(64)   NOT NULL CONSTRAINT [df_sessions_ip] DEFAULT (N''),
    [created_at] DATETIME2      NOT NULL CONSTRAINT [df_sessions_created] DEFAULT (SYSUTCDATETIME()),
    [expires_at] DATETIME2      NOT NULL,
    [is_active]  BIT            NOT NULL CONSTRAINT [df_sessions_active] DEFAULT (1)
);
GO

IF OBJECT_ID(N'[mbpw].[audit_logs]', N'U') IS NULL
CREATE TABLE [mbpw].[audit_logs] (
    [id]          NVARCHAR(64)  NOT NULL CONSTRAINT [pk_audit_logs] PRIMARY KEY,
    [user_id]     NVARCHAR(64)  NOT NULL,      -- user id, or the literal N'anonymous'
    [action]      NVARCHAR(512) NOT NULL,
    [resource]    NVARCHAR(256) NOT NULL CONSTRAINT [df_audit_resource] DEFAULT (N''),
    [resource_id] NVARCHAR(256) NOT NULL CONSTRAINT [df_audit_resource_id] DEFAULT (N''),
    [details]     NVARCHAR(MAX) NULL,
    [ip_address]  NVARCHAR(64)  NOT NULL CONSTRAINT [df_audit_ip] DEFAULT (N''),
    [created_at]  DATETIME2     NOT NULL CONSTRAINT [df_audit_created] DEFAULT (SYSUTCDATETIME())
);
GO

/* =============================================================================
   SECTION 4  ::  CORE PIPELINE
   Hunting -> Landing -> Outreach -> Response      (app/models/schema.py)
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[leads]', N'U') IS NULL
CREATE TABLE [mbpw].[leads] (
    [id]                  NVARCHAR(64)   NOT NULL CONSTRAINT [pk_leads] PRIMARY KEY,
    [title]               NVARCHAR(400)  NOT NULL,
    [description]         NVARCHAR(MAX)  NULL,
    [client_name]         NVARCHAR(400)  NULL,
    [company]             NVARCHAR(400)  NULL,
    [email]               NVARCHAR(320)  NULL,
    [phone]               NVARCHAR(64)   NULL,
    [country]             NVARCHAR(128)  NULL,
    [budget_min]          FLOAT          NULL,
    [budget_max]          FLOAT          NULL,
    [deadline]            NVARCHAR(128)  NULL,     -- free-form string in the app
    [technologies]        NVARCHAR(MAX)  NULL CONSTRAINT [ck_leads_tech_json] CHECK ([technologies] IS NULL OR ISJSON([technologies]) = 1),
    [skills]              NVARCHAR(MAX)  NULL CONSTRAINT [ck_leads_skills_json] CHECK ([skills] IS NULL OR ISJSON([skills]) = 1),
    [platform]            NVARCHAR(64)   NULL,     -- source code, e.g. 'remotive'
    [job_type]            NVARCHAR(64)   NULL,
    [status]              NVARCHAR(64)   NOT NULL CONSTRAINT [df_leads_status] DEFAULT (N'new'),
    [urgency]             NVARCHAR(32)   NOT NULL CONSTRAINT [df_leads_urgency] DEFAULT (N'medium'),
    [difficulty]          FLOAT          NOT NULL CONSTRAINT [df_leads_difficulty] DEFAULT (50),
    [success_probability] FLOAT          NOT NULL CONSTRAINT [df_leads_probability] DEFAULT (50),
    [risk_level]          NVARCHAR(32)   NOT NULL CONSTRAINT [df_leads_risk] DEFAULT (N'medium'),
    [expected_revenue]    FLOAT          NOT NULL CONSTRAINT [df_leads_revenue] DEFAULT (0),
    [competition]         INT            NOT NULL CONSTRAINT [df_leads_competition] DEFAULT (0),
    [project_size]        NVARCHAR(32)   NOT NULL CONSTRAINT [df_leads_project_size] DEFAULT (N'medium'),
    [payment_method]      NVARCHAR(64)   NOT NULL CONSTRAINT [df_leads_payment] DEFAULT (N'Escrow'),
    [client_history]      NVARCHAR(MAX)  NULL,
    [url]                 NVARCHAR(2048) NULL,
    [notes]               NVARCHAR(MAX)  NULL,
    [tags]                NVARCHAR(MAX)  NULL CONSTRAINT [ck_leads_tags_json] CHECK ([tags] IS NULL OR ISJSON([tags]) = 1),
    [found_at]            DATETIME2      NOT NULL CONSTRAINT [df_leads_found] DEFAULT (SYSUTCDATETIME()),
    [analyzed_at]         DATETIME2      NULL
);
GO

IF OBJECT_ID(N'[mbpw].[proposals]', N'U') IS NULL
CREATE TABLE [mbpw].[proposals] (
    [id]                    NVARCHAR(64)  NOT NULL CONSTRAINT [pk_proposals] PRIMARY KEY,
    [lead_id]               NVARCHAR(64)  NULL,    -- may be '' when generated from raw leadData
    [title]                 NVARCHAR(512) NOT NULL,
    [cover_letter]          NVARCHAR(MAX) NULL,
    [introduction]          NVARCHAR(MAX) NULL,
    [technical_plan]        NVARCHAR(MAX) NULL,
    [timeline]              NVARCHAR(512) NULL,
    [cost_estimate]         NVARCHAR(MAX) NULL,
    [portfolio_suggestions] NVARCHAR(MAX) NULL CONSTRAINT [ck_proposals_portfolio_json] CHECK ([portfolio_suggestions] IS NULL OR ISJSON([portfolio_suggestions]) = 1),
    [call_to_action]        NVARCHAR(MAX) NULL,
    [win_probability]       FLOAT         NOT NULL CONSTRAINT [df_proposals_win] DEFAULT (0),
    [status]                NVARCHAR(32)  NOT NULL CONSTRAINT [df_proposals_status] DEFAULT (N'draft'),
    [created_at]            DATETIME2     NOT NULL CONSTRAINT [df_proposals_created] DEFAULT (SYSUTCDATETIME()),
    [submitted_at]          DATETIME2     NULL
);
GO

IF OBJECT_ID(N'[mbpw].[outreach]', N'U') IS NULL
CREATE TABLE [mbpw].[outreach] (
    [id]          NVARCHAR(64)   NOT NULL CONSTRAINT [pk_outreach] PRIMARY KEY,
    [lead_id]     NVARCHAR(64)   NULL,
    [client_name] NVARCHAR(400)  NULL,
    [company]     NVARCHAR(400)  NULL,
    [email]       NVARCHAR(320)  NULL,
    [channel]     NVARCHAR(32)   NOT NULL CONSTRAINT [df_outreach_channel] DEFAULT (N'email'),
    [step]        INT            NOT NULL CONSTRAINT [df_outreach_step] DEFAULT (0),   -- index into CADENCE (0..3)
    [step_label]  NVARCHAR(256)  NULL,
    [subject]     NVARCHAR(1024) NULL,
    [body_text]   NVARCHAR(MAX)  NULL,
    [status]      NVARCHAR(32)   NOT NULL CONSTRAINT [df_outreach_status] DEFAULT (N'simulated'),
    [simulated]   BIT            NOT NULL CONSTRAINT [df_outreach_simulated] DEFAULT (0),
    [sent_at]     DATETIME2      NULL,
    [replied_at]  DATETIME2      NULL,
    [created_at]  DATETIME2      NOT NULL CONSTRAINT [df_outreach_created] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[outreach_states]', N'U') IS NULL
CREATE TABLE [mbpw].[outreach_states] (
    [lead_id]      NVARCHAR(64) NOT NULL CONSTRAINT [pk_outreach_states] PRIMARY KEY,
    [enrolled]     BIT          NOT NULL CONSTRAINT [df_os_enrolled] DEFAULT (1),
    [current_step] INT          NOT NULL CONSTRAINT [df_os_step] DEFAULT (-1),        -- -1 = day 0 not sent yet
    [status]       NVARCHAR(32) NOT NULL CONSTRAINT [df_os_status] DEFAULT (N'active'),
    [last_sent_at] DATETIME2    NULL,
    [next_due_at]  DATETIME2    NULL,
    [created_at]   DATETIME2    NOT NULL CONSTRAINT [df_os_created] DEFAULT (SYSUTCDATETIME()),
    [updated_at]   DATETIME2    NOT NULL CONSTRAINT [df_os_updated] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[notifications]', N'U') IS NULL
CREATE TABLE [mbpw].[notifications] (
    [id]         NVARCHAR(64)  NOT NULL CONSTRAINT [pk_notifications] PRIMARY KEY,
    [type]       NVARCHAR(64)  NULL,      -- system | high_value | urgent | agent | new_lead
    [title]      NVARCHAR(512) NULL,
    [message]    NVARCHAR(MAX) NULL,
    [lead_id]    NVARCHAR(64)  NULL,      -- optional context link
    [read]       BIT          NOT NULL CONSTRAINT [df_notif_read] DEFAULT (0),
    [priority]   NVARCHAR(32)  NOT NULL CONSTRAINT [df_notif_priority] DEFAULT (N'medium'),
    [created_at] DATETIME2     NOT NULL CONSTRAINT [df_notif_created] DEFAULT (SYSUTCDATETIME())
);
GO

/* =============================================================================
   SECTION 5  ::  CRM, CONNECTORS, AGENTS, KNOWLEDGE, CONFIG
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[companies]', N'U') IS NULL
CREATE TABLE [mbpw].[companies] (
    [id]         NVARCHAR(64)   NOT NULL CONSTRAINT [pk_companies] PRIMARY KEY,
    [name]       NVARCHAR(400)  NOT NULL,
    [industry]   NVARCHAR(256)  NULL,
    [country]    NVARCHAR(128)  NULL,
    [website]    NVARCHAR(1024) NULL,
    [revenue]    FLOAT          NOT NULL CONSTRAINT [df_companies_revenue] DEFAULT (0),
    [status]     NVARCHAR(32)   NOT NULL CONSTRAINT [df_companies_status] DEFAULT (N'prospect'),
    [notes]      NVARCHAR(MAX)  NULL,
    [created_at] DATETIME2      NOT NULL CONSTRAINT [df_companies_created] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[contacts]', N'U') IS NULL
CREATE TABLE [mbpw].[contacts] (
    [id]         NVARCHAR(64)  NOT NULL CONSTRAINT [pk_contacts] PRIMARY KEY,
    [name]       NVARCHAR(400) NOT NULL,
    [email]      NVARCHAR(320) NULL,
    [phone]      NVARCHAR(64)  NULL,
    [role]       NVARCHAR(256) NULL,
    [company_id] NVARCHAR(64)  NULL         -- app-level FK, deleted with the company
);
GO

IF OBJECT_ID(N'[mbpw].[connectors]', N'U') IS NULL
CREATE TABLE [mbpw].[connectors] (
    [id]            NVARCHAR(64)   NOT NULL CONSTRAINT [pk_connectors] PRIMARY KEY,
    [name]          NVARCHAR(256)  NOT NULL,
    [type]          NVARCHAR(32)   NOT NULL,   -- api | rss | ats | scraper | webhook
    [platform]      NVARCHAR(64)   NULL,       -- must equal ref_lead_source.code to sync
    [status]        NVARCHAR(32)   NOT NULL CONSTRAINT [df_connectors_status] DEFAULT (N'inactive'),
    [config]        NVARCHAR(MAX)  NULL CONSTRAINT [ck_connectors_config_json] CHECK ([config] IS NULL OR ISJSON([config]) = 1),
    [last_sync_at]  DATETIME2      NULL,
    [sync_count]    INT            NOT NULL CONSTRAINT [df_connectors_sync_count] DEFAULT (0),
    [leads_found]   INT            NOT NULL CONSTRAINT [df_connectors_leads] DEFAULT (0),
    [error_message] NVARCHAR(MAX)  NULL,
    [created_at]    DATETIME2      NOT NULL CONSTRAINT [df_connectors_created] DEFAULT (SYSUTCDATETIME()),
    [updated_at]    DATETIME2      NOT NULL CONSTRAINT [df_connectors_updated] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[agent_logs]', N'U') IS NULL
CREATE TABLE [mbpw].[agent_logs] (
    [id]        NVARCHAR(64)   NOT NULL CONSTRAINT [pk_agent_logs] PRIMARY KEY,
    [agent_id]  NVARCHAR(16)   NULL,        -- agent-1 | agent-2 | agent-3
    [action]    NVARCHAR(128)  NULL,        -- run_started | sync_complete | analyze_complete
    [details]   NVARCHAR(MAX)  NULL,
    [status]    NVARCHAR(32)   NOT NULL CONSTRAINT [df_agent_logs_status] DEFAULT (N'success'),
    [timestamp] DATETIME2      NOT NULL CONSTRAINT [df_agent_logs_ts] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[knowledge_base]', N'U') IS NULL
CREATE TABLE [mbpw].[knowledge_base] (
    [id]         NVARCHAR(64)   NOT NULL CONSTRAINT [pk_knowledge_base] PRIMARY KEY,
    [title]      NVARCHAR(400)  NOT NULL,
    [entry_type] NVARCHAR(64)   NOT NULL,   -- playbook | industry_knowledge | past_win | past_loss | client_history
    [content]    NVARCHAR(MAX)  NOT NULL,
    [tags]       NVARCHAR(MAX)  NULL CONSTRAINT [ck_knowledge_tags_json] CHECK ([tags] IS NULL OR ISJSON([tags]) = 1),
    [source]     NVARCHAR(512)  NOT NULL CONSTRAINT [df_knowledge_source] DEFAULT (N''),
    [source_url] NVARCHAR(2048) NOT NULL CONSTRAINT [df_knowledge_source_url] DEFAULT (N''),
    [created_at] DATETIME2      NOT NULL CONSTRAINT [df_knowledge_created] DEFAULT (SYSUTCDATETIME()),
    [updated_at] DATETIME2      NOT NULL CONSTRAINT [df_knowledge_updated] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[app_config]', N'U') IS NULL
CREATE TABLE [mbpw].[app_config] (
    [key]       NVARCHAR(128) NOT NULL CONSTRAINT [pk_app_config] PRIMARY KEY,
    [value]     NVARCHAR(MAX) NULL,
    [updated_at] DATETIME2    NOT NULL CONSTRAINT [df_app_config_updated] DEFAULT (SYSUTCDATETIME())
);
GO

/* =============================================================================
   SECTION 6  ::  ACIE  (Automated Contact Intelligence Engine)
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[contact_intel]', N'U') IS NULL
CREATE TABLE [mbpw].[contact_intel] (
    [lead_id]               NVARCHAR(64)   NOT NULL CONSTRAINT [pk_contact_intel] PRIMARY KEY,
    [person_id]             NVARCHAR(128)  NULL,
    [name]                  NVARCHAR(400)  NULL,
    [company]               NVARCHAR(400)  NULL,
    [domain]                NVARCHAR(255)  NULL,
    [title]                 NVARCHAR(400)  NULL,
    [email]                 NVARCHAR(320)  NULL,
    [phone]                 NVARCHAR(64)   NULL,
    [lifecycle]             NVARCHAR(32)   NOT NULL CONSTRAINT [df_ci_lifecycle] DEFAULT (N'DISCOVERED'),
    [channel]               NVARCHAR(32)   NOT NULL CONSTRAINT [df_ci_channel] DEFAULT (N'email'),
    [contact_confidence]    FLOAT          NOT NULL CONSTRAINT [df_ci_confidence] DEFAULT (0),
    [identity_confidence]   FLOAT          NOT NULL CONSTRAINT [df_ci_identity] DEFAULT (0),
    [employment_confidence] FLOAT          NOT NULL CONSTRAINT [df_ci_employment] DEFAULT (0),
    [email_confidence]      FLOAT          NOT NULL CONSTRAINT [df_ci_email_conf] DEFAULT (0),
    [phone_confidence]      FLOAT          NOT NULL CONSTRAINT [df_ci_phone_conf] DEFAULT (0),
    [risk_score]            FLOAT          NOT NULL CONSTRAINT [df_ci_risk] DEFAULT (0),
    [freshness_score]       FLOAT          NOT NULL CONSTRAINT [df_ci_fresh] DEFAULT (0),
    [verification_status]   NVARCHAR(32)   NOT NULL CONSTRAINT [df_ci_verify] DEFAULT (N'unknown'),
    [supply_status]         NVARCHAR(32)   NOT NULL CONSTRAINT [df_ci_supply] DEFAULT (N'ok'),
    [provider]              NVARCHAR(64)   NOT NULL CONSTRAINT [df_ci_provider] DEFAULT (N''),
    [profile]               NVARCHAR(MAX)  NULL CONSTRAINT [ck_ci_profile_json] CHECK ([profile] IS NULL OR ISJSON([profile]) = 1),
    [last_contacted]        DATETIME2      NULL,
    [last_verified]         DATETIME2      NULL,
    [next_verification]     DATETIME2      NULL,
    [bounce_count]          INT            NOT NULL CONSTRAINT [df_ci_bounces] DEFAULT (0),
    [created_at]            DATETIME2      NOT NULL CONSTRAINT [df_ci_created] DEFAULT (SYSUTCDATETIME()),
    [updated_at]            DATETIME2      NOT NULL CONSTRAINT [df_ci_updated] DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID(N'[mbpw].[provider_performance]', N'U') IS NULL
CREATE TABLE [mbpw].[provider_performance] (
    [provider]   NVARCHAR(64) NOT NULL,
    [event_type] NVARCHAR(32) NOT NULL,       -- deliver | bounce
    [count]      INT          NOT NULL CONSTRAINT [df_pp_count] DEFAULT (0),
    [weighted]   FLOAT        NOT NULL CONSTRAINT [df_pp_weighted] DEFAULT (0),
    [updated_at] DATETIME2    NOT NULL CONSTRAINT [df_pp_updated] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [pk_provider_performance] PRIMARY KEY ([provider], [event_type])
);
GO

IF OBJECT_ID(N'[mbpw].[outreach_feedback]', N'U') IS NULL
CREATE TABLE [mbpw].[outreach_feedback] (
    [id]                 NVARCHAR(64)  NOT NULL CONSTRAINT [pk_outreach_feedback] PRIMARY KEY,
    [lead_id]            NVARCHAR(64)  NULL,
    [channel]            NVARCHAR(32)  NOT NULL CONSTRAINT [df_fb_channel] DEFAULT (N'email'),
    [outcome]            NVARCHAR(64)  NOT NULL CONSTRAINT [df_fb_outcome] DEFAULT (N'no_response'),
    [provider]           NVARCHAR(64)  NOT NULL CONSTRAINT [df_fb_provider] DEFAULT (N''),
    [confidence_at_time] FLOAT         NOT NULL CONSTRAINT [df_fb_confidence] DEFAULT (0),
    [detail]             NVARCHAR(MAX) NULL,
    [created_at]         DATETIME2     NOT NULL CONSTRAINT [df_fb_created] DEFAULT (SYSUTCDATETIME())
);
GO

/* =============================================================================
   SECTION 7  ::  JSON PROJECTION TABLES  (SQL Server stand-in for jsonb + GIN)
   -----------------------------------------------------------------------------
   The app writes technologies / skills / tags as a JSON array string. SQL Server
   cannot index those, so an AFTER trigger projects each element into a real
   indexed child row. The app is still the single writer; these tables are
   derived. Only the view v_technology_breakdown reads the JSON directly, so a
   bulk load that bypasses triggers can never corrupt it.
   ============================================================================= */

IF OBJECT_ID(N'[mbpw].[lead_technologies]', N'U') IS NULL
CREATE TABLE [mbpw].[lead_technologies] (
    [lead_id]    NVARCHAR(64)  NOT NULL,
    [technology] NVARCHAR(256) NOT NULL,
    CONSTRAINT [pk_lead_technologies] PRIMARY KEY ([lead_id], [technology])
);
GO

IF OBJECT_ID(N'[mbpw].[lead_tags]', N'U') IS NULL
CREATE TABLE [mbpw].[lead_tags] (
    [lead_id] NVARCHAR(64)  NOT NULL,
    [tag]     NVARCHAR(256) NOT NULL,
    CONSTRAINT [pk_lead_tags] PRIMARY KEY ([lead_id], [tag])
);
GO

IF OBJECT_ID(N'[mbpw].[knowledge_tags]', N'U') IS NULL
CREATE TABLE [mbpw].[knowledge_tags] (
    [entry_id] NVARCHAR(64)  NOT NULL,
    [tag]      NVARCHAR(256) NOT NULL,
    CONSTRAINT [pk_knowledge_tags] PRIMARY KEY ([entry_id], [tag])
);
GO

/* =============================================================================
   SECTION 8  ::  INDEXES
   Every index maps to a WHERE / ORDER BY / GROUP BY that exists in the routers.
   All indexed NVARCHAR columns are <= 400 chars (800-byte key limit).
   ============================================================================= */

-- Split into several batches: CREATE INDEX must not share a batch with the
-- CREATE TABLE it depends on, and smaller batches parse / deploy faster.
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_found_at' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_found_at] ON [mbpw].[leads] ([found_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_status' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_status] ON [mbpw].[leads] ([status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_status_found' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_status_found] ON [mbpw].[leads] ([status], [found_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_platform' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_platform] ON [mbpw].[leads] ([platform]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_country' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_country] ON [mbpw].[leads] ([country]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_company' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_company] ON [mbpw].[leads] ([company]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_title' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_title] ON [mbpw].[leads] ([title]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_job_type' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_job_type] ON [mbpw].[leads] ([job_type]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_email' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_email] ON [mbpw].[leads] ([email]);
-- Lead Analyzer worklist: filter(analyzed_at == None)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_pending_analysis' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_pending_analysis] ON [mbpw].[leads] ([found_at] DESC)
        WHERE [analyzed_at] IS NULL;
-- Proposal Generator worklist: status IN ('analyzing','qualified') AND success_probability >= 50
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_proposal_ready' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_proposal_ready] ON [mbpw].[leads] ([success_probability] DESC, [found_at] DESC)
        WHERE [status] IN (N'analyzing', N'qualified');
-- Enrichment worklist: email IS NULL
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_missing_email' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_missing_email] ON [mbpw].[leads] ([found_at])
        WHERE [email] IS NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_leads_won' AND object_id = OBJECT_ID(N'[mbpw].[leads]'))
    CREATE INDEX [ix_leads_won] ON [mbpw].[leads] ([found_at] DESC) WHERE [status] = N'won';

GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_proposals_lead_id' AND object_id = OBJECT_ID(N'[mbpw].[proposals]'))
    CREATE INDEX [ix_proposals_lead_id] ON [mbpw].[proposals] ([lead_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_proposals_created_at' AND object_id = OBJECT_ID(N'[mbpw].[proposals]'))
    CREATE INDEX [ix_proposals_created_at] ON [mbpw].[proposals] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_proposals_status' AND object_id = OBJECT_ID(N'[mbpw].[proposals]'))
    CREATE INDEX [ix_proposals_status] ON [mbpw].[proposals] ([status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_proposals_win_prob' AND object_id = OBJECT_ID(N'[mbpw].[proposals]'))
    CREATE INDEX [ix_proposals_win_prob] ON [mbpw].[proposals] ([win_probability] DESC);

-- outreach.py: filter(lead_id).order_by(step.desc()).first()
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_lead_step' AND object_id = OBJECT_ID(N'[mbpw].[outreach]'))
    CREATE INDEX [ix_outreach_lead_step] ON [mbpw].[outreach] ([lead_id], [step] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_created_at' AND object_id = OBJECT_ID(N'[mbpw].[outreach]'))
    CREATE INDEX [ix_outreach_created_at] ON [mbpw].[outreach] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_status' AND object_id = OBJECT_ID(N'[mbpw].[outreach]'))
    CREATE INDEX [ix_outreach_status] ON [mbpw].[outreach] ([status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_channel' AND object_id = OBJECT_ID(N'[mbpw].[outreach]'))
    CREATE INDEX [ix_outreach_channel] ON [mbpw].[outreach] ([channel]);

-- Cron hot path: enrolled = 1 AND status = 'active' AND next_due_at <= now
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_states_due' AND object_id = OBJECT_ID(N'[mbpw].[outreach_states]'))
    CREATE INDEX [ix_outreach_states_due] ON [mbpw].[outreach_states] ([next_due_at])
        WHERE [enrolled] = 1 AND [status] = N'active';
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_states_status' AND object_id = OBJECT_ID(N'[mbpw].[outreach_states]'))
    CREATE INDEX [ix_outreach_states_status] ON [mbpw].[outreach_states] ([status]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_notifications_created_at' AND object_id = OBJECT_ID(N'[mbpw].[notifications]'))
    CREATE INDEX [ix_notifications_created_at] ON [mbpw].[notifications] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_notifications_unread' AND object_id = OBJECT_ID(N'[mbpw].[notifications]'))
    CREATE INDEX [ix_notifications_unread] ON [mbpw].[notifications] ([created_at] DESC) WHERE [read] = 0;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_notifications_lead_id' AND object_id = OBJECT_ID(N'[mbpw].[notifications]'))
    CREATE INDEX [ix_notifications_lead_id] ON [mbpw].[notifications] ([lead_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_notifications_type' AND object_id = OBJECT_ID(N'[mbpw].[notifications]'))
    CREATE INDEX [ix_notifications_type] ON [mbpw].[notifications] ([type]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_notifications_priority' AND object_id = OBJECT_ID(N'[mbpw].[notifications]'))
    CREATE INDEX [ix_notifications_priority] ON [mbpw].[notifications] ([priority]);

GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_sessions_user_active' AND object_id = OBJECT_ID(N'[mbpw].[sessions]'))
    CREATE INDEX [ix_sessions_user_active] ON [mbpw].[sessions] ([user_id]) WHERE [is_active] = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_sessions_expires_at' AND object_id = OBJECT_ID(N'[mbpw].[sessions]'))
    CREATE INDEX [ix_sessions_expires_at] ON [mbpw].[sessions] ([expires_at]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_audit_logs_created_at' AND object_id = OBJECT_ID(N'[mbpw].[audit_logs]'))
    CREATE INDEX [ix_audit_logs_created_at] ON [mbpw].[audit_logs] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_audit_logs_user_id' AND object_id = OBJECT_ID(N'[mbpw].[audit_logs]'))
    CREATE INDEX [ix_audit_logs_user_id] ON [mbpw].[audit_logs] ([user_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_audit_logs_resource' AND object_id = OBJECT_ID(N'[mbpw].[audit_logs]'))
    CREATE INDEX [ix_audit_logs_resource] ON [mbpw].[audit_logs] ([resource]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_companies_created_at' AND object_id = OBJECT_ID(N'[mbpw].[companies]'))
    CREATE INDEX [ix_companies_created_at] ON [mbpw].[companies] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_companies_status' AND object_id = OBJECT_ID(N'[mbpw].[companies]'))
    CREATE INDEX [ix_companies_status] ON [mbpw].[companies] ([status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contacts_company_id' AND object_id = OBJECT_ID(N'[mbpw].[contacts]'))
    CREATE INDEX [ix_contacts_company_id] ON [mbpw].[contacts] ([company_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contacts_email' AND object_id = OBJECT_ID(N'[mbpw].[contacts]'))
    CREATE INDEX [ix_contacts_email] ON [mbpw].[contacts] ([email]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_connectors_status' AND object_id = OBJECT_ID(N'[mbpw].[connectors]'))
    CREATE INDEX [ix_connectors_status] ON [mbpw].[connectors] ([status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_connectors_platform' AND object_id = OBJECT_ID(N'[mbpw].[connectors]'))
    CREATE INDEX [ix_connectors_platform] ON [mbpw].[connectors] ([platform]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_connectors_created_at' AND object_id = OBJECT_ID(N'[mbpw].[connectors]'))
    CREATE INDEX [ix_connectors_created_at] ON [mbpw].[connectors] ([created_at] DESC);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_agent_logs_agent_ts' AND object_id = OBJECT_ID(N'[mbpw].[agent_logs]'))
    CREATE INDEX [ix_agent_logs_agent_ts] ON [mbpw].[agent_logs] ([agent_id], [timestamp] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_agent_logs_timestamp' AND object_id = OBJECT_ID(N'[mbpw].[agent_logs]'))
    CREATE INDEX [ix_agent_logs_timestamp] ON [mbpw].[agent_logs] ([timestamp] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_agent_logs_status' AND object_id = OBJECT_ID(N'[mbpw].[agent_logs]'))
    CREATE INDEX [ix_agent_logs_status] ON [mbpw].[agent_logs] ([status]);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_knowledge_created_at' AND object_id = OBJECT_ID(N'[mbpw].[knowledge_base]'))
    CREATE INDEX [ix_knowledge_created_at] ON [mbpw].[knowledge_base] ([created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_knowledge_entry_type' AND object_id = OBJECT_ID(N'[mbpw].[knowledge_base]'))
    CREATE INDEX [ix_knowledge_entry_type] ON [mbpw].[knowledge_base] ([entry_type]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_knowledge_title' AND object_id = OBJECT_ID(N'[mbpw].[knowledge_base]'))
    CREATE INDEX [ix_knowledge_title] ON [mbpw].[knowledge_base] ([title]);

-- Projection tables (the jsonb + GIN equivalent) and ACIE
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_lead_technologies_tech' AND object_id = OBJECT_ID(N'[mbpw].[lead_technologies]'))
    CREATE INDEX [ix_lead_technologies_tech] ON [mbpw].[lead_technologies] ([technology], [lead_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_lead_tags_tag' AND object_id = OBJECT_ID(N'[mbpw].[lead_tags]'))
    CREATE INDEX [ix_lead_tags_tag] ON [mbpw].[lead_tags] ([tag], [lead_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_knowledge_tags_tag' AND object_id = OBJECT_ID(N'[mbpw].[knowledge_tags]'))
    CREATE INDEX [ix_knowledge_tags_tag] ON [mbpw].[knowledge_tags] ([tag], [entry_id]);

GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_lifecycle' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_lifecycle] ON [mbpw].[contact_intel] ([lifecycle]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_supply_status' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_supply_status] ON [mbpw].[contact_intel] ([supply_status]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_confidence' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_confidence] ON [mbpw].[contact_intel] ([contact_confidence] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_email' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_email] ON [mbpw].[contact_intel] ([email]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_domain' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_domain] ON [mbpw].[contact_intel] ([domain]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_next_verify' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_next_verify] ON [mbpw].[contact_intel] ([next_verification])
        WHERE [next_verification] IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_contact_intel_person_id' AND object_id = OBJECT_ID(N'[mbpw].[contact_intel]'))
    CREATE INDEX [ix_contact_intel_person_id] ON [mbpw].[contact_intel] ([person_id]);
-- compliance.py frequency cap: count(sent|opened) in the last 30 days per lead
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_feedback_lead_ts' AND object_id = OBJECT_ID(N'[mbpw].[outreach_feedback]'))
    CREATE INDEX [ix_outreach_feedback_lead_ts] ON [mbpw].[outreach_feedback] ([lead_id], [created_at] DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_outreach_feedback_outcome' AND object_id = OBJECT_ID(N'[mbpw].[outreach_feedback]'))
    CREATE INDEX [ix_outreach_feedback_outcome] ON [mbpw].[outreach_feedback] ([outcome]);
GO
/* =============================================================================
   SECTION 9  ::  TRIGGERS
   ============================================================================= */

-- 9.1 updated_at maintenance ---------------------------------------------------
-- T-SQL has no BEFORE UPDATE, so this is AFTER UPDATE. If the caller already
-- supplied updated_at (the SQLAlchemy onupdate=), we skip - which also makes the
-- trigger non-recursive regardless of the RECURSIVE_TRIGGERS setting.
IF OBJECT_ID(N'[mbpw].[trg_connectors_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_connectors_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_connectors_updated_at]
ON [mbpw].[connectors]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;          -- caller set it; also blocks recursion
    UPDATE [mbpw].[connectors] SET [updated_at] = SYSUTCDATETIME();
END
GO

IF OBJECT_ID(N'[mbpw].[trg_outreach_states_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_outreach_states_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_outreach_states_updated_at]
ON [mbpw].[outreach_states]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;
    UPDATE [mbpw].[outreach_states] SET [updated_at] = SYSUTCDATETIME();
END
GO

IF OBJECT_ID(N'[mbpw].[trg_knowledge_base_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_knowledge_base_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_knowledge_base_updated_at]
ON [mbpw].[knowledge_base]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;
    UPDATE [mbpw].[knowledge_base] SET [updated_at] = SYSUTCDATETIME();
END
GO

IF OBJECT_ID(N'[mbpw].[trg_contact_intel_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_contact_intel_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_contact_intel_updated_at]
ON [mbpw].[contact_intel]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;
    UPDATE [mbpw].[contact_intel] SET [updated_at] = SYSUTCDATETIME();
END
GO

IF OBJECT_ID(N'[mbpw].[trg_provider_performance_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_provider_performance_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_provider_performance_updated_at]
ON [mbpw].[provider_performance]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;
    UPDATE [mbpw].[provider_performance] SET [updated_at] = SYSUTCDATETIME();
END
GO

IF OBJECT_ID(N'[mbpw].[trg_app_config_updated_at]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_app_config_updated_at];
GO
CREATE TRIGGER [mbpw].[trg_app_config_updated_at]
ON [mbpw].[app_config]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE([updated_at]) RETURN;
    UPDATE [mbpw].[app_config] SET [updated_at] = SYSUTCDATETIME();
END
GO

-- 9.2 JSON projection: leads.technologies / leads.tags --------------------------
IF OBJECT_ID(N'[mbpw].[trg_leads_json_sync]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_leads_json_sync];
GO

CREATE TRIGGER [mbpw].[trg_leads_json_sync]
ON [mbpw].[leads]
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    DELETE t
      FROM [mbpw].[lead_technologies] AS t
     WHERE EXISTS (SELECT 1 FROM inserted AS i WHERE i.[id] = t.[lead_id])
        OR EXISTS (SELECT 1 FROM deleted   AS d WHERE d.[id] = t.[lead_id]);

    INSERT INTO [mbpw].[lead_technologies] ([lead_id], [technology])
    SELECT i.[id], LTRIM(RTRIM(j.[value]))
      FROM inserted AS i
     CROSS APPLY OPENJSON(CASE WHEN ISJSON(i.[technologies]) = 1 THEN i.[technologies] ELSE N'[]' END) AS j
     WHERE j.[type] = 1
       AND LEN(LTRIM(RTRIM(j.[value]))) > 0
       AND LEN(LTRIM(RTRIM(j.[value]))) <= 256;

    DELETE t
      FROM [mbpw].[lead_tags] AS t
     WHERE EXISTS (SELECT 1 FROM inserted AS i WHERE i.[id] = t.[lead_id])
        OR EXISTS (SELECT 1 FROM deleted   AS d WHERE d.[id] = t.[lead_id]);

    INSERT INTO [mbpw].[lead_tags] ([lead_id], [tag])
    SELECT i.[id], LTRIM(RTRIM(j.[value]))
      FROM inserted AS i
     CROSS APPLY OPENJSON(CASE WHEN ISJSON(i.[tags]) = 1 THEN i.[tags] ELSE N'[]' END) AS j
     WHERE j.[type] = 1
       AND LEN(LTRIM(RTRIM(j.[value]))) > 0
       AND LEN(LTRIM(RTRIM(j.[value]))) <= 256;
END
GO

-- 9.3 JSON projection: knowledge_base.tags -------------------------------------
IF OBJECT_ID(N'[mbpw].[trg_knowledge_tags_sync]', N'TR') IS NOT NULL
    DROP TRIGGER [mbpw].[trg_knowledge_tags_sync];
GO

CREATE TRIGGER [mbpw].[trg_knowledge_tags_sync]
ON [mbpw].[knowledge_base]
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    DELETE t
      FROM [mbpw].[knowledge_tags] AS t
     WHERE EXISTS (SELECT 1 FROM inserted AS i WHERE i.[id] = t.[entry_id])
        OR EXISTS (SELECT 1 FROM deleted   AS d WHERE d.[id] = t.[entry_id]);

    INSERT INTO [mbpw].[knowledge_tags] ([entry_id], [tag])
    SELECT i.[id], LTRIM(RTRIM(j.[value]))
      FROM inserted AS i
     CROSS APPLY OPENJSON(CASE WHEN ISJSON(i.[tags]) = 1 THEN i.[tags] ELSE N'[]' END) AS j
     WHERE j.[type] = 1
       AND LEN(LTRIM(RTRIM(j.[value]))) > 0
       AND LEN(LTRIM(RTRIM(j.[value]))) <= 256;
END
GO

/* =============================================================================
   SECTION 10  ::  FUNCTIONS  (SQL mirrors of the Python decision logic)
   ============================================================================= */

-- 10.1 Compliance gate - port of services/acie/compliance.py:gate_status ------
IF OBJECT_ID(N'[mbpw].[fn_compliance_gate]', N'IF') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_compliance_gate];
GO

CREATE FUNCTION [mbpw].[fn_compliance_gate]
(
    @lead_id NVARCHAR(64)
)
RETURNS TABLE
AS
BEGIN
    DECLARE @enabled  NVARCHAR(16),
            @freq_raw NVARCHAR(32),
            @cool_raw NVARCHAR(32),
            @dnc      NVARCHAR(MAX),
            @company  NVARCHAR(400),
            @supply   NVARCHAR(32),
            @hits     INT,
            @recent   DATETIME2,
            @freq_max INT,
            @cooloff  INT,
            @cooldown BIT,
            @blocked  NVARCHAR(MAX) = N'';

    SELECT @enabled  = [value] FROM [mbpw].[app_config] WHERE [key] = N'act.gate.enabled';
    SELECT @freq_raw = [value] FROM [mbpw].[app_config] WHERE [key] = N'act.gate.frequency_max';
    SELECT @cool_raw = [value] FROM [mbpw].[app_config] WHERE [key] = N'act.gate.reply_cooloff_days';
    SELECT @dnc      = [value] FROM [mbpw].[app_config] WHERE [key] = N'act.gate.dnc_companies';

    SET @freq_max = COALESCE(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(@freq_raw)), N'')), 4);
    SET @cooloff  = COALESCE(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(@cool_raw)), N'')), 90);

    SELECT @company = [company], @supply = [supply_status]
      FROM [mbpw].[contact_intel] WHERE [lead_id] = @lead_id;

    SET @supply = COALESCE(@supply, N'ok');

    SELECT @hits = COUNT(*)
      FROM [mbpw].[outreach_feedback]
     WHERE [lead_id] = @lead_id
       AND [created_at] >= DATEADD(DAY, -30, SYSUTCDATETIME())
       AND [outcome] IN (N'sent', N'opened');

    SELECT @recent = MAX([created_at])
      FROM [mbpw].[outreach_feedback]
     WHERE [lead_id] = @lead_id
       AND [outcome] IN (N'reply_positive', N'reply_negative');

    SET @cooldown = CASE WHEN @recent IS NULL THEN 0
                         WHEN DATEDIFF(DAY, @recent, SYSUTCDATETIME()) < @cooloff THEN 1
                         ELSE 0 END;

    IF COALESCE(@enabled, N'on') <> N'on'
        SET @blocked = @blocked + N',gate_disabled';

    IF @dnc IS NOT NULL AND ISJSON(@dnc) = 1
       AND EXISTS (SELECT 1
                     FROM OPENJSON(@dnc) WITH ([company] NVARCHAR(400) '$.company') AS d
                    WHERE LOWER(d.[company]) = LOWER(COALESCE(@company, @lead_id)))
        SET @blocked = @blocked + N',do_not_contact';

    IF @supply IN (N'opted_out', N'suppressed', N'bounced')
        SET @blocked = @blocked + N',suppressed:' + @supply;

    IF @hits >= @freq_max
        SET @blocked = @blocked + N',frequency_cap';

    IF @cooldown = 1
        SET @blocked = @blocked + N',reply_cooldown';

    RETURN
    (
        SELECT CASE WHEN LEN(@blocked) = 0 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS [pass],
               CASE WHEN COALESCE(@enabled, N'on') = N'on' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS [gate_enabled],
               CASE WHEN LEN(@blocked) = 0 THEN N'' ELSE SUBSTRING(@blocked, 2, LEN(@blocked)) END AS [blocked],
               @supply                     AS [supply_status],
               @hits                       AS [frequency_current],
               @freq_max                   AS [frequency_max],
               CASE WHEN @recent IS NULL THEN 0
                    WHEN @cooloff - DATEDIFF(DAY, @recent, SYSUTCDATETIME()) > 0
                        THEN @cooloff - DATEDIFF(DAY, @recent, SYSUTCDATETIME())
                    ELSE 0 END              AS [reply_cooldown_days_left]
    );
END
GO

-- 10.2 Blocking predicate used by the outreach engine --------------------------
IF OBJECT_ID(N'[mbpw].[fn_can_send]', N'FN') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_can_send];
GO

CREATE FUNCTION [mbpw].[fn_can_send]
(
    @lead_id NVARCHAR(64)
)
RETURNS BIT
AS
BEGIN
    DECLARE @p BIT = CAST(0 AS BIT);
    SELECT @p = [pass] FROM [mbpw].[fn_compliance_gate](@lead_id);
    RETURN @p;
END
GO

-- 10.3 Next cadence due date - port of outreach_automation.compute_next_due ----
IF OBJECT_ID(N'[mbpw].[fn_compute_next_due]', N'FN') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_compute_next_due];
GO

CREATE FUNCTION [mbpw].[fn_compute_next_due]
(
    @lead_id NVARCHAR(64)
)
RETURNS DATETIME2
AS
BEGIN
    DECLARE @found       BIT = 0,
            @last_sent   DATETIME2,
            @current     INT,
            @cadence_len INT,
            @cur_day     INT,
            @nxt_day     INT,
            @result      DATETIME2;

    SELECT @found = 1, @last_sent = [last_sent_at], @current = [current_step]
      FROM [mbpw].[outreach_states] WHERE [lead_id] = @lead_id;

    IF @found = 0
    BEGIN
        SET @result = NULL;
        RETURN @result;
    END

    SELECT @cadence_len = COUNT(*) FROM [mbpw].[ref_outreach_cadence];

    IF @last_sent IS NULL OR @current < 0
    BEGIN
        SET @result = SYSUTCDATETIME();          -- day 0 is due immediately
        RETURN @result;
    END

    IF @current >= @cadence_len - 1
    BEGIN
        SET @result = NULL;                     -- sequence finished
        RETURN @result;
    END

    SELECT @cur_day = [day_offset] FROM [mbpw].[ref_outreach_cadence] WHERE [step] = @current;
    SELECT @nxt_day = [day_offset] FROM [mbpw].[ref_outreach_cadence] WHERE [step] = @current + 1;

    SET @result = DATEADD(DAY, CASE WHEN @nxt_day - @cur_day > 0
                                    THEN @nxt_day - @cur_day ELSE 0 END, @last_sent);
    RETURN @result;
END
GO

-- 10.4 ACIE confidence tier - port of services/acie/constants.py --------------
IF OBJECT_ID(N'[mbpw].[fn_confidence_tier]', N'FN') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_confidence_tier];
GO

CREATE FUNCTION [mbpw].[fn_confidence_tier]
(
    @score FLOAT
)
RETURNS NVARCHAR(16)
AS
BEGIN
    DECLARE @tier NVARCHAR(16);

    SET @tier = CASE WHEN @score >= 90 THEN N'HIGH'
                     WHEN @score >= 75 THEN N'MEDIUM'
                     ELSE N'LOW' END;

    RETURN @tier;
END
GO

-- 10.5 Provider reliability - port of services/acie/learn.py ------------------
IF OBJECT_ID(N'[mbpw].[fn_provider_reliability]', N'FN') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_provider_reliability];
GO

CREATE FUNCTION [mbpw].[fn_provider_reliability]
(
    @provider NVARCHAR(64)
)
RETURNS FLOAT
AS
BEGIN
    DECLARE @deliver FLOAT,
            @bounce  FLOAT,
            @ratio   FLOAT,
            @result  FLOAT;

    SELECT @deliver = ISNULL((SELECT [weighted] FROM [mbpw].[provider_performance]
                               WHERE [provider] = @provider AND [event_type] = N'deliver'), 0);
    SELECT @bounce  = ISNULL((SELECT [weighted] FROM [mbpw].[provider_performance]
                               WHERE [provider] = @provider AND [event_type] = N'bounce'),  0);

    IF @deliver = 0 AND @bounce = 0
    BEGIN
        SET @result = 0.5;
        RETURN @result;
    END

    SET @ratio = @deliver / CASE WHEN (@deliver + @bounce) > 1.0
                                 THEN (@deliver + @bounce) ELSE 1.0 END;
    IF @bounce >= 3 AND @ratio > 0.15
        SET @ratio = @ratio - 0.15;

    SET @result = CAST(ROUND(@ratio, 3) AS FLOAT);
    RETURN @result;
END
GO

-- 10.6 Email syntax - SQL twin of outreach_service.is_email_deliverable.
-- A real deliverability check needs DNS/MX, which T-SQL cannot do: this
-- reproduces the syntactic + reserved-domain/local-part rules only.
IF OBJECT_ID(N'[mbpw].[fn_email_syntax_ok]', N'FN') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_email_syntax_ok];
GO

CREATE FUNCTION [mbpw].[fn_email_syntax_ok]
(
    @email NVARCHAR(320)
)
RETURNS BIT
AS
BEGIN
    DECLARE @local  NVARCHAR(320),
            @domain NVARCHAR(320),
            @result BIT;

    SET @result = CAST(0 AS BIT);

    IF @email IS NOT NULL AND @email LIKE '%@%.%' AND @email NOT LIKE '% %'
    BEGIN
        SET @local  = LOWER(LTRIM(RTRIM(SUBSTRING(@email, 1, CHARINDEX('@', @email) - 1))));
        SET @domain = LOWER(LTRIM(RTRIM(SUBSTRING(@email, CHARINDEX('@', @email) + 1, 320))));

        IF CHARINDEX('.', @domain) > 0
           AND @domain NOT IN (N'example.com', N'example.net', N'example.org', N'test.com',
                               N'localhost', N'invalid', N'domain.com', N'email.com',
                               N'yourdomain.com', N'example', N'test', N'localhost.localdomain',
                               N'mailinator.com', N'10minutemail.com', N'guerrillamail.com',
                               N'tempmail.com', N'trashmail.com')
           AND @local NOT IN (N'name', N'test', N'user', N'email', N'yourname', N'anonymous', N'sample')
            SET @result = CAST(1 AS BIT);
    END

    RETURN @result;
END
GO

-- 10.7 Funnel helper -----------------------------------------------------------
IF OBJECT_ID(N'[mbpw].[fn_funnel_value]', N'IF') IS NOT NULL
    DROP FUNCTION [mbpw].[fn_funnel_value];
GO

CREATE FUNCTION [mbpw].[fn_funnel_value]()
RETURNS TABLE
AS
RETURN
(
    SELECT ISNULL(l.[status], N'new') AS [stage],
           COUNT_BIG(*)              AS [lead_count],
           ISNULL(SUM(l.[expected_revenue]), 0) AS [pipeline_value]
      FROM [mbpw].[leads] AS l
     GROUP BY ISNULL(l.[status], N'new')
);
GO

/* =============================================================================
   SECTION 11  ::  VIEWS
   ============================================================================= */

-- 11.1 One row per lead: the full cross-table picture ---------------------------
IF OBJECT_ID(N'[mbpw].[v_lead_pipeline]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_lead_pipeline];
GO
CREATE VIEW [mbpw].[v_lead_pipeline] AS
SELECT
    l.[id]                     AS [lead_id],
    l.[title],
    l.[company],
    l.[client_name],
    l.[country],
    l.[platform],
    l.[status],
    l.[urgency],
    l.[risk_level],
    l.[job_type],
    l.[technologies],
    l.[skills],
    l.[tags],
    l.[email],
    l.[budget_min],
    l.[budget_max],
    l.[expected_revenue],
    l.[success_probability],
    l.[difficulty],
    l.[competition],
    l.[url],
    l.[found_at],
    l.[analyzed_at],
    p.[id]                     AS [proposal_id],
    p.[status]                 AS [proposal_status],
    p.[win_probability],
    p.[submitted_at],
    s.[enrolled]               AS [outreach_enrolled],
    s.[current_step]           AS [outreach_step],
    s.[status]                 AS [outreach_state],
    s.[last_sent_at],
    s.[next_due_at],
    (SELECT COUNT_BIG(*) FROM [mbpw].[outreach] AS o WHERE o.[lead_id] = l.[id])        AS [outreach_touches],
    (SELECT MAX(o.[sent_at])    FROM [mbpw].[outreach] AS o WHERE o.[lead_id] = l.[id]) AS [last_touch_at],
    (SELECT MAX(o.[replied_at]) FROM [mbpw].[outreach] AS o WHERE o.[lead_id] = l.[id]) AS [last_reply_at],
    ci.[lifecycle]             AS [acie_lifecycle],
    ci.[channel]               AS [acie_channel],
    ci.[email]                 AS [acie_email],
    ci.[contact_confidence]    AS [acie_confidence],
    [mbpw].[fn_confidence_tier](ci.[contact_confidence]) AS [acie_tier],
    ci.[supply_status]         AS [acie_supply_status],
    ci.[verification_status]   AS [acie_verification_status],
    ci.[bounce_count]          AS [acie_bounce_count],
    [mbpw].[fn_can_send](l.[id]) AS [acie_gate_pass]
FROM [mbpw].[leads] AS l
LEFT JOIN [mbpw].[proposals]      AS p  ON p.[lead_id]  = l.[id]
LEFT JOIN [mbpw].[outreach_states] AS s ON s.[lead_id]  = l.[id]
LEFT JOIN [mbpw].[contact_intel]  AS ci ON ci.[lead_id] = l.[id];
GO

-- 11.2 System KPIs - port of GET /api/admin/system/stats ------------------------
IF OBJECT_ID(N'[mbpw].[v_system_stats]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_system_stats];
GO
CREATE VIEW [mbpw].[v_system_stats] AS
SELECT
    (SELECT COUNT_BIG(*) FROM [mbpw].[leads])                                AS [total_leads],
    (SELECT COUNT_BIG(*) FROM [mbpw].[proposals])                            AS [total_proposals],
    (SELECT COUNT_BIG(*) FROM [mbpw].[companies])                            AS [total_companies],
    (SELECT COUNT_BIG(*) FROM [mbpw].[contacts])                             AS [total_contacts],
    (SELECT COUNT_BIG(*) FROM [mbpw].[users])                                AS [total_users],
    (SELECT COUNT_BIG(*) FROM [mbpw].[notifications])                        AS [total_notifications],
    (SELECT COUNT_BIG(*) FROM [mbpw].[connectors])                           AS [total_connectors],
    (SELECT COUNT_BIG(*) FROM [mbpw].[agent_logs])                           AS [total_agent_logs],
    (SELECT COUNT_BIG(*) FROM [mbpw].[knowledge_base])                       AS [total_knowledge_entries],
    (SELECT COUNT_BIG(*) FROM [mbpw].[sessions] WHERE [is_active] = 1)       AS [active_sessions],
    (SELECT COUNT_BIG(*) FROM [mbpw].[leads]
      WHERE [found_at]   >= CAST(SYSUTCDATETIME() AS DATE))                   AS [today_leads],
    (SELECT COUNT_BIG(*) FROM [mbpw].[proposals]
      WHERE [created_at] >= CAST(SYSUTCDATETIME() AS DATE))                   AS [today_proposals],
    SYSUTCDATETIME()                                                         AS [generated_at];
GO

-- 11.3 Pipeline report - port of GET /api/reports/pipeline ---------------------
IF OBJECT_ID(N'[mbpw].[v_pipeline_report]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_pipeline_report];
GO
CREATE VIEW [mbpw].[v_pipeline_report] AS
SELECT
    ISNULL(l.[status], N'new')  AS [stage],
    r.[label]                   AS [stage_label],
    r.[sort_order],
    COUNT_BIG(*)                AS [lead_count],
    ISNULL(SUM(l.[expected_revenue]), 0) AS [pipeline_value],
    SUM(CASE WHEN l.[status] = N'won' THEN CAST(1 AS BIGINT) ELSE CAST(0 AS BIGINT) END) AS [won],
    CAST(CASE WHEN COUNT_BIG(*) = 0 THEN 0
              ELSE ROUND(100.0 * SUM(CASE WHEN l.[status] = N'won' THEN CAST(1 AS BIGINT) ELSE CAST(0 AS BIGINT) END)
                         / COUNT_BIG(*), 1) END AS FLOAT) AS [conversion_pct]
FROM [mbpw].[leads] AS l
LEFT JOIN [mbpw].[ref_lead_status] AS r ON r.[code] = ISNULL(l.[status], N'new')
GROUP BY ISNULL(l.[status], N'new'), r.[label], r.[sort_order];
GO

-- 11.4 Platform breakdown - port of GET /api/analytics/platforms --------------
IF OBJECT_ID(N'[mbpw].[v_platform_breakdown]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_platform_breakdown];
GO
CREATE VIEW [mbpw].[v_platform_breakdown] AS
SELECT
    l.[platform],
    s.[display_name],
    COUNT_BIG(*)                          AS [leads],
    ISNULL(SUM(l.[expected_revenue]), 0)  AS [expected_revenue],
    MAX(l.[found_at])                     AS [last_seen_at]
FROM [mbpw].[leads] AS l
LEFT JOIN [mbpw].[ref_lead_source] AS s ON s.[code] = l.[platform]
WHERE l.[platform] IS NOT NULL AND l.[platform] <> N''
GROUP BY l.[platform], s.[display_name];
GO

-- 11.5 Country breakdown - port of GET /api/analytics/countries ----------------
IF OBJECT_ID(N'[mbpw].[v_country_breakdown]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_country_breakdown];
GO
CREATE VIEW [mbpw].[v_country_breakdown] AS
SELECT
    l.[country],
    COUNT_BIG(*)                              AS [lead_count],
    ISNULL(SUM(l.[expected_revenue]), 0)       AS [revenue],
    CAST(ROUND(ISNULL(AVG(l.[success_probability]), 0), 1) AS FLOAT) AS [avg_success_probability],
    CAST(ISNULL(AVG(l.[budget_max]), 0) AS FLOAT) AS [avg_budget_max]
FROM [mbpw].[leads] AS l
WHERE l.[country] IS NOT NULL AND l.[country] <> N''
GROUP BY l.[country];
GO

-- 11.6 Technology breakdown - reads the JSON directly (always authoritative) ---
IF OBJECT_ID(N'[mbpw].[v_technology_breakdown]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_technology_breakdown];
GO
CREATE VIEW [mbpw].[v_technology_breakdown] AS
SELECT
    j.[value]  AS [technology],
    COUNT_BIG(*) AS [lead_count]
FROM [mbpw].[leads] AS l
CROSS APPLY OPENJSON(CASE WHEN ISJSON(l.[technologies]) = 1 THEN l.[technologies] ELSE N'[]' END) AS j
WHERE j.[type] = 1 AND LEN(LTRIM(RTRIM(j.[value]))) > 0
GROUP BY j.[value];
GO

-- 11.7 Indexed technology lookup (uses the trigger-projected child table) ------
IF OBJECT_ID(N'[mbpw].[v_lead_technology_index]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_lead_technology_index];
GO
CREATE VIEW [mbpw].[v_lead_technology_index] AS
SELECT t.[technology], t.[lead_id], l.[title], l.[company], l.[status], l.[found_at]
FROM [mbpw].[lead_technologies] AS t
INNER JOIN [mbpw].[leads] AS l ON l.[id] = t.[lead_id];
GO

-- 11.8 Agent performance - port of GET /api/analytics/agents -------------------
IF OBJECT_ID(N'[mbpw].[v_agent_performance]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_agent_performance];
GO
CREATE VIEW [mbpw].[v_agent_performance] AS
SELECT
    a.[code]       AS [agent_id],
    a.[name]       AS [agent_name],
    a.[kind]       AS [agent_type],
    COUNT(l.[id])  AS [tasks_completed],
    MAX(l.[timestamp]) AS [last_active],
    SUM(CASE WHEN l.[status] = N'error'   THEN 1 ELSE 0 END) AS [errors],
    SUM(CASE WHEN l.[status] = N'success' THEN 1 ELSE 0 END) AS [successes]
FROM [mbpw].[ref_agent] AS a
LEFT JOIN [mbpw].[agent_logs] AS l ON l.[agent_id] = a.[code]
GROUP BY a.[code], a.[name], a.[kind];
GO

-- 11.9 Outreach send queue - what GET /api/outreach/cron will process ---------
IF OBJECT_ID(N'[mbpw].[v_outreach_queue]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_outreach_queue];
GO
CREATE VIEW [mbpw].[v_outreach_queue] AS
SELECT
    s.[lead_id],
    l.[company],
    l.[client_name],
    ISNULL(NULLIF(ci.[email], N''), l.[email]) AS [target_email],
    [mbpw].[fn_email_syntax_ok](ISNULL(NULLIF(ci.[email], N''), l.[email])) AS [syntax_ok],
    ISNULL(ci.[channel], N'email')            AS [channel],
    ISNULL(ci.[contact_confidence], 0)        AS [confidence],
    s.[current_step],
    s.[current_step] + 1                      AS [next_step],
    c.[day_offset]                            AS [next_day_offset],
    c.[channel]                               AS [planned_channel],
    c.[label]                                 AS [planned_label],
    s.[next_due_at],
    [mbpw].[fn_compute_next_due](s.[lead_id]) AS [computed_next_due],
    [mbpw].[fn_can_send](s.[lead_id])         AS [gate_pass]
FROM [mbpw].[outreach_states] AS s
INNER JOIN [mbpw].[leads] AS l                ON l.[id] = s.[lead_id]
LEFT JOIN [mbpw].[contact_intel] AS ci        ON ci.[lead_id] = s.[lead_id]
LEFT JOIN [mbpw].[ref_outreach_cadence] AS c  ON c.[step] = s.[current_step] + 1
WHERE s.[enrolled] = 1
  AND s.[status] = N'active'
  AND (s.[next_due_at] IS NULL OR s.[next_due_at] <= SYSUTCDATETIME());
GO

-- 11.10 Outreach effectiveness -------------------------------------------------
IF OBJECT_ID(N'[mbpw].[v_outreach_performance]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_outreach_performance];
GO
CREATE VIEW [mbpw].[v_outreach_performance] AS
SELECT
    o.[channel],
    o.[step],
    o.[step_label],
    COUNT_BIG(*) AS [total],
    SUM(CASE WHEN o.[status] = N'sent'      THEN 1 ELSE 0 END) AS [sent],
    SUM(CASE WHEN o.[status] = N'simulated' THEN 1 ELSE 0 END) AS [simulated],
    SUM(CASE WHEN o.[status] = N'logged'    THEN 1 ELSE 0 END) AS [logged],
    SUM(CASE WHEN o.[status] = N'replied'   THEN 1 ELSE 0 END) AS [replied],
    SUM(CASE WHEN o.[status] = N'failed'    THEN 1 ELSE 0 END) AS [failed],
    CAST(CASE WHEN COUNT_BIG(*) = 0 THEN 0
              ELSE ROUND(100.0 * SUM(CASE WHEN o.[status] = N'replied' THEN 1 ELSE 0 END)
                         / COUNT_BIG(*), 1) END AS FLOAT) AS [reply_rate_pct]
FROM [mbpw].[outreach] AS o
GROUP BY o.[channel], o.[step], o.[step_label];
GO

-- 11.11 Monthly revenue - port of GET /api/analytics/revenue -------------------
IF OBJECT_ID(N'[mbpw].[v_monthly_revenue]', N'V') IS NOT NULL DROP VIEW [mbpw].[v_monthly_revenue];
GO
CREATE VIEW [mbpw].[v_monthly_revenue] AS
WITH months AS
(
    SELECT DATEADD(MONTH, -11, SYSUTCDATETIME()) AS [month_start]
    UNION ALL
    SELECT DATEADD(MONTH, 1, [month_start])
      FROM months
     WHERE [month_start] < SYSUTCDATETIME()
)
SELECT
    CONVERT(CHAR(7), m.[month_start], 126) AS [month],
    ISNULL((SELECT SUM(l.[expected_revenue])
              FROM [mbpw].[leads] AS l
             WHERE l.[status] = N'won'
               AND DATEDIFF(MONTH, DATEFROMPARTS(YEAR(l.[found_at]), MONTH(l.[found_at]), 1), m.[month_start]) = 0), 0) AS [revenue],
    ISNULL((SELECT COUNT_BIG(*)
              FROM [mbpw].[proposals] AS p
             WHERE DATEDIFF(MONTH, DATEFROMPARTS(YEAR(p.[created_at]), MONTH(p.[created_at]), 1), m.[month_start]) = 0), 0) AS [proposals]
FROM months AS m
OPTION (MAXRECURSION 0);
GO

/* =============================================================================
   SECTION 12  ::  SEED DATA  (idempotent - INSERT ... WHERE NOT EXISTS)
   ============================================================================= */

-- 12.1 app_config - every key the app reads, with its code default --------------
INSERT INTO [mbpw].[app_config] ([key], [value], [updated_at])
SELECT v.[key], v.[val], SYSUTCDATETIME()
FROM (VALUES
    (N'outreach_automation_enabled',  N'true'),   -- outreach_automation.AUTOMATION_FLAG
    (N'act.gate.enabled',             N'on'),     -- compliance.GATE_ENABLED
    (N'act.gate.frequency_max',       N'4'),      -- compliance.FREQ_MAX (4 per 30 days)
    (N'act.gate.reply_cooloff_days',  N'90'),     -- compliance.REPLY_COOLOFF
    (N'act.gate.dnc_companies',       N'[]'),     -- JSON: [{"company":"...","reason":"..."}]
    -- Integration secrets: leave empty, or supply via PUT /api/settings or env vars.
    (N'hunter_api_key',               N''),
    (N'apollo_api_key',               N''),
    (N'hubspot_api_key',              N''),
    (N'hubspot_client_id',            N''),
    (N'hubspot_client_secret',        N''),
    (N'hubspot_redirect_uri',         N''),
    (N'hubspot_app_id',               N''),
    (N'hubspot_access_token',         N''),
    (N'hubspot_refresh_token',        N''),
    (N'hubspot_token_expires_at',     N'')
) AS v ([key], [val])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[app_config] AS c WHERE c.[key] = v.[key]);
GO

-- 12.2 Lookup vocabularies ------------------------------------------------------
INSERT INTO [mbpw].[ref_lead_status] ([code], [label], [sort_order], [is_terminal], [source])
SELECT v.[code], v.[label], v.[sort_order], v.[is_terminal], N'src/lib/types.ts'
FROM (VALUES
    (N'new',           N'New',           1, CAST(0 AS BIT)),
    (N'analyzing',     N'Analyzing',     2, CAST(0 AS BIT)),
    (N'qualified',     N'Qualified',     3, CAST(0 AS BIT)),
    (N'proposal_sent', N'Proposal Sent', 4, CAST(0 AS BIT)),
    (N'negotiation',   N'Negotiation',   5, CAST(0 AS BIT)),
    (N'won',           N'Won',           6, CAST(1 AS BIT)),
    (N'lost',          N'Lost',          7, CAST(1 AS BIT)),
    (N'archived',      N'Archived',      8, CAST(1 AS BIT))
) AS v ([code], [label], [sort_order], [is_terminal])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_lead_status] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_job_type] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'remote', N'Remote'), (N'hybrid', N'Hybrid'), (N'onsite', N'On-site'),
    (N'contract', N'Contract'), (N'freelance', N'Freelance'),
    (N'full_time', N'Full-time'), (N'part_time', N'Part-time')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_job_type] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_risk_level] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'low', N'Low'), (N'medium', N'Medium'), (N'high', N'High'), (N'very_high', N'Very high')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_risk_level] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_urgency] ([code], [label], [rank])
SELECT v.[code], v.[label], v.[rank]
FROM (VALUES
    (N'low', N'Low', 1), (N'medium', N'Medium', 2), (N'high', N'High', 3), (N'critical', N'Critical', 4)
) AS v ([code], [label], [rank])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_urgency] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_user_role] ([code], [label], [level], [source])
SELECT v.[code], v.[label], v.[level], N'app/routers/auth.py:require_role'
FROM (VALUES
    (N'user', N'User', 0), (N'admin', N'Admin', 1), (N'superadmin', N'Superadmin', 2)
) AS v ([code], [label], [level])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_user_role] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_notification_type] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'system', N'System'), (N'high_value', N'High value'), (N'urgent', N'Urgent'),
    (N'agent', N'Agent'), (N'new_lead', N'New lead'), (N'follow_up', N'Follow-up'),
    (N'government', N'Government'), (N'enterprise', N'Enterprise')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_notification_type] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_priority] ([code], [label], [rank])
SELECT v.[code], v.[label], v.[rank]
FROM (VALUES
    (N'low', N'Low', 1), (N'medium', N'Medium', 2), (N'high', N'High', 3)
) AS v ([code], [label], [rank])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_priority] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_connector_type] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'api', N'JSON API'), (N'rss', N'RSS feed'), (N'ats', N'ATS API'),
    (N'scraper', N'Scraper'), (N'webhook', N'Webhook')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_connector_type] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_connector_status] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'active', N'Active'), (N'inactive', N'Inactive'), (N'syncing', N'Syncing'), (N'error', N'Error')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_connector_status] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_outreach_channel] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'email', N'Email'), (N'linkedin', N'LinkedIn'), (N'phone', N'Phone'), (N'whatsapp', N'WhatsApp')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_outreach_channel] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_outreach_record_status] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'sent', N'Sent via SMTP'), (N'simulated', N'Simulated (no SMTP)'),
    (N'logged', N'Logged for manual action'), (N'replied', N'Replied'), (N'failed', N'Failed')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_outreach_record_status] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_outreach_state] ([code], [label], [description])
SELECT v.[code], v.[label], v.[descr]
FROM (VALUES
    (N'active',      N'Active',      N'Scheduled for the next due touch.'),
    (N'paused',      N'Paused',      N'Manually paused; enrolled = 0.'),
    (N'needs_email', N'Needs email', N'Parked: ACIE could not resolve a deliverable address.'),
    (N'completed',   N'Completed',   N'Cadence exhausted or lead gone.')
) AS v ([code], [label], [descr])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_outreach_state] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_acie_lifecycle] ([code], [description], [terminal], [source])
SELECT v.[code], v.[descr], v.[term], N'services/acie/constants.py:LIFECYCLE'
FROM (VALUES
    (N'NEW',            N'Freshly created record.',                          CAST(0 AS BIT)),
    (N'DISCOVERED',     N'Lead found by a hunter source.',                   CAST(0 AS BIT)),
    (N'RESOLVED',       N'Company/domain/name identity resolved.',           CAST(0 AS BIT)),
    (N'VERIFIED',       N'Evidence verified by a provider.',                 CAST(0 AS BIT)),
    (N'SCORED',         N'Confidence computed.',                             CAST(0 AS BIT)),
    (N'OUTREACH_READY', N'HIGH tier + compliance gate passed.',              CAST(0 AS BIT)),
    (N'REVIEW_ALT',     N'MEDIUM tier - needs human review / alt channel.',  CAST(0 AS BIT)),
    (N'LOW_SUPPRESS',   N'LOW tier - do not contact.',                       CAST(1 AS BIT)),
    (N'SUPPRESSED',     N'Blocked by the compliance gate.',                  CAST(1 AS BIT)),
    (N'REPLIED',        N'Contact replied.',                                 CAST(0 AS BIT)),
    (N'BOUNCED',        N'Address bounced.',                                 CAST(1 AS BIT)),
    (N'UNSUBSCRIBED',   N'Opted out.',                                       CAST(1 AS BIT)),
    (N'JOB_CHANGE',     N'Person changed role.',                             CAST(0 AS BIT)),
    (N'STALE',          N'Not contacted for 120 days.',                      CAST(0 AS BIT))
) AS v ([code], [descr], [term])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_acie_lifecycle] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_supply_status] ([code], [label], [blocks_send])
SELECT v.[code], v.[label], v.[blk]
FROM (VALUES
    (N'ok',         N'OK',         CAST(0 AS BIT)),
    (N'bounced',    N'Bounced',    CAST(1 AS BIT)),
    (N'opted_out',  N'Opted out',  CAST(1 AS BIT)),
    (N'suppressed', N'Suppressed', CAST(1 AS BIT))
) AS v ([code], [label], [blk])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_supply_status] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_verification_status] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'unknown', N'Unknown'), (N'none', N'None'), (N'valid', N'Valid'),
    (N'invalid', N'Invalid'), (N'risky', N'Risky'), (N'catch_all', N'Catch-all'),
    (N'disposable', N'Disposable')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_verification_status] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_feedback_outcome] ([code], [label], [counts_for_cap], [event_type], [bumps_lifecycle])
SELECT v.[code], v.[label], v.[cap], v.[ev], v.[lc]
FROM (VALUES
    (N'no_response',    N'No response',          CAST(0 AS BIT), NNULL,            NULL),
    (N'sent',           N'Sent',                 CAST(1 AS BIT), CAST(N'deliver' AS NVARCHAR(16)), NULL),
    (N'opened',         N'Opened',               CAST(1 AS BIT), CAST(N'deliver' AS NVARCHAR(16)), NULL),
    (N'deliver',        N'Delivered',            CAST(0 AS BIT), CAST(N'deliver' AS NVARCHAR(16)), NULL),
    (N'bounce',         N'Bounced',              CAST(0 AS BIT), CAST(N'bounce'  AS NVARCHAR(16)), CAST(N'BOUNCED' AS NVARCHAR(32))),
    (N'invalid',        N'Invalid address',      CAST(0 AS BIT), CAST(N'bounce'  AS NVARCHAR(16)), NULL),
    (N'verify_fail',    N'Verification failed',  CAST(0 AS BIT), CAST(N'bounce'  AS NVARCHAR(16)), NULL),
    (N'reply_positive', N'Positive reply',       CAST(0 AS BIT), CAST(N'deliver' AS NVARCHAR(16)), CAST(N'REPLIED' AS NVARCHAR(32))),
    (N'reply_negative', N'Negative reply',       CAST(0 AS BIT), CAST(N'deliver' AS NVARCHAR(16)), CAST(N'REPLIED' AS NVARCHAR(32))),
    (N'replied',        N'Replied',              CAST(0 AS BIT), NNULL,            CAST(N'REPLIED' AS NVARCHAR(32))),
    (N'unsubscribe',    N'Unsubscribed',         CAST(0 AS BIT), NNULL,            CAST(N'UNSUBSCRIBED' AS NVARCHAR(32))),
    (N'opt_out',        N'Opted out',            CAST(0 AS BIT), NNULL,            CAST(N'UNSUBSCRIBED' AS NVARCHAR(32))),
    (N'job_change',     N'Job change',           CAST(0 AS BIT), NNULL,            CAST(N'JOB_CHANGE' AS NVARCHAR(32)))
) AS v ([code], [label], [cap], [ev], [lc])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_feedback_outcome] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_provider] ([code], [label], [kind], [requires_key], [active], [source])
SELECT v.[code], v.[label], v.[kind], v.[req], CAST(1 AS BIT), N'services/acie/providers/registry.py'
FROM (VALUES
    (N'web',           N'Website scrape',    N'email', CAST(0 AS BIT)),
    (N'doh',           N'DNS-over-HTTPS MX', N'email', CAST(0 AS BIT)),
    (N'apollo',        N'Apollo.io',         N'email', CAST(1 AS BIT)),
    (N'hunter',        N'Hunter.io',         N'email', CAST(1 AS BIT)),
    (N'twilio_lookup', N'Twilio Lookup',     N'phone', CAST(1 AS BIT)),
    (N'lead',          N'Lead record itself',N'email', CAST(0 AS BIT))
) AS v ([code], [label], [kind], [req])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_provider] AS t WHERE t.[code] = v.[code]);
GO

-- Icons are stored as ASCII glyph names / escape codes rather than raw emoji,
-- so this script stays pure ASCII and cannot be corrupted by the client's
-- code page. (agents.py uses "\U0001F310" style emoji; map them client-side.)
INSERT INTO [mbpw].[ref_agent] ([code], [name], [kind], [description], [icon], [source])
SELECT v.[code], v.[name], v.[kind], v.[descr], v.[icon], N'app/routers/agents.py:AGENT_DEFINITIONS'
FROM (VALUES
    (N'agent-1', N'Global Opportunity Hunter', N'opportunity_hunter',
     N'Continuously searches worldwide job boards for new IT and business opportunities.', N'\u1F310'),
    (N'agent-2', N'Lead Analyzer', N'lead_analyzer',
     N'Deep analyzes each discovered lead to assess viability, calculate success probability, and determine expected revenue.', N'\u1F50D'),
    (N'agent-3', N'Proposal Generator', N'proposal_generator',
     N'Creates customized, professional proposals for qualified leads.', N'\u1F4DD')
) AS v ([code], [name], [kind], [descr], [icon])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_agent] AS t WHERE t.[code] = v.[code]);
GO

INSERT INTO [mbpw].[ref_knowledge_type] ([code], [label])
SELECT v.[code], v.[label]
FROM (VALUES
    (N'playbook', N'Playbook'), (N'industry_knowledge', N'Industry knowledge'),
    (N'past_win', N'Past win'), (N'past_loss', N'Past loss'), (N'client_history', N'Client history')
) AS v ([code], [label])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_knowledge_type] AS t WHERE t.[code] = v.[code]);
GO

-- 12.3 Cadence - mirror of outreach_service.CADENCE ---------------------------
INSERT INTO [mbpw].[ref_outreach_cadence] ([step], [day_offset], [channel], [label], [goal])
SELECT v.[step], v.[day], v.[channel], v.[label], v.[goal]
FROM (VALUES
    (0,  0, N'email',    N'First touch - intro & value',   N'Introduce MBPW and reference the specific project by name.'),
    (1,  3, N'email',    N'Value add - concrete insight',  N'Share a relevant approach/risk note for their challenge.'),
    (2,  7, N'linkedin', N'Social touch - connect',        N'Connect / engage on LinkedIn to stay visible.'),
    (3, 14, N'email',    N'Final nudge - proof point',     N'Share a result and a low-friction next step, then step back.')
) AS v ([step], [day], [channel], [label], [goal])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_outreach_cadence] AS t WHERE t.[step] = v.[step]);
GO

-- 12.4 The 17 registered sources (services/sources/__init__.py) ---------------
INSERT INTO [mbpw].[ref_lead_source] ([code], [display_name], [source_type], [homepage], [requires_key], [enabled], [source])
SELECT v.[code], v.[dname], v.[stype], v.[home], v.[req], CAST(1 AS BIT), N'app/services/sources/__init__.py'
FROM (VALUES
    (N'adzuna',         N'Adzuna',           N'api', N'https://adzuna.com',          CAST(1 AS BIT)),
    (N'arbeitnow',      N'Arbeitnow',        N'api', N'https://www.arbeitnow.com',   CAST(0 AS BIT)),
    (N'ashby',          N'Ashby ATS',        N'ats', N'https://ashbyhq.com',         CAST(0 AS BIT)),
    (N'europeremotely', N'Europe Remotely',  N'rss', N'https://europeremotely.com',  CAST(0 AS BIT)),
    (N'findwork',       N'Findwork',         N'api', N'https://findwork.dev',        CAST(0 AS BIT)),
    (N'greenhouse',     N'Greenhouse ATS',   N'ats', N'https://greenhouse.io',       CAST(0 AS BIT)),
    (N'himalayas',      N'Himalayas',        N'api', N'https://himalayas.app',       CAST(0 AS BIT)),
    (N'hn_hiring',      N'HN Who''s Hiring', N'api', N'https://news.ycombinator.com',CAST(0 AS BIT)),
    (N'jobspresso',     N'Jobspresso',       N'rss', N'https://jobspresso.co',       CAST(0 AS BIT)),
    (N'jooble',         N'Jooble',           N'api', N'https://jooble.org',          CAST(1 AS BIT)),
    (N'lever',          N'Lever ATS',        N'ats', N'https://lever.co',            CAST(0 AS BIT)),
    (N'remoteok',       N'RemoteOK',         N'rss', N'https://remoteok.com',        CAST(0 AS BIT)),
    (N'remoteco',       N'Remote.co',        N'rss', N'https://remote.co',           CAST(0 AS BIT)),
    (N'remotive',       N'Remotive',        N'rss', N'https://remotive.com',        CAST(0 AS BIT)),
    (N'upwork',         N'Upwork',           N'rss', N'https://www.upwork.com',      CAST(0 AS BIT)),
    (N'weworkremotely', N'We Work Remotely',  N'rss', N'https://weworkremotely.com',  CAST(0 AS BIT)),
    (N'workingnomads',  N'Working Nomads',   N'rss', N'https://www.workingnomads.co',CAST(0 AS BIT))
) AS v ([code], [dname], [stype], [home], [req])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[ref_lead_source] AS t WHERE t.[code] = v.[code]);
GO

-- 12.5 Connectors - one per keyless source, ready for POST /api/connectors/{id}/sync
-- `platform` MUST equal ref_lead_source.code or sync_source() fails.
INSERT INTO [mbpw].[connectors] ([id], [name], [type], [platform], [status], [config], [sync_count], [leads_found], [created_at], [updated_at])
SELECT v.[id], v.[name], v.[type], v.[platform], N'inactive', N'{}', 0, 0, SYSUTCDATETIME(), SYSUTCDATETIME()
FROM (VALUES
    (N'conn-himalayas',      N'Himalayas',        N'api', N'himalayas'),
    (N'conn-remoteok',       N'RemoteOK',         N'rss', N'remoteok'),
    (N'conn-remotive',       N'Remotive',        N'rss', N'remotive'),
    (N'conn-weworkremotely', N'We Work Remotely', N'rss', N'weworkremotely'),
    (N'conn-arbeitnow',      N'Arbeitnow',        N'api', N'arbeitnow'),
    (N'conn-findwork',       N'Findwork',         N'api', N'findwork'),
    (N'conn-greenhouse',     N'Greenhouse ATS',   N'ats', N'greenhouse'),
    (N'conn-lever',          N'Lever ATS',        N'ats', N'lever'),
    (N'conn-ashby',          N'Ashby ATS',        N'ats', N'ashby'),
    (N'conn-hn-hiring',      N'HN Who''s Hiring', N'api', N'hn_hiring'),
    (N'conn-jobspresso',     N'Jobspresso',       N'rss', N'jobspresso'),
    (N'conn-remoteco',       N'Remote.co',        N'rss', N'remoteco'),
    (N'conn-europeremotely', N'Europe Remotely',  N'rss', N'europeremotely'),
    (N'conn-workingnomads',  N'Working Nomads',   N'rss', N'workingnomads'),
    (N'conn-upwork',         N'Upwork',           N'rss', N'upwork')
) AS v ([id], [name], [type], [platform])
WHERE NOT EXISTS (SELECT 1 FROM [mbpw].[connectors] AS c WHERE c.[id] = v.[id]);
GO
-- Keyed sources (Adzuna, Jooble) are NOT seeded: sync_all_sources() skips them.

-- 12.6 First superadmin ---------------------------------------------------------
-- The app NEVER creates default credentials (models/seed.py requires
-- ADMIN_INITIAL_PASSWORD). Generate a bcrypt digest with:
--   python -c "from passlib.context import CryptContext; \
--              print(CryptContext(schemes=['bcrypt']).hash('YourPassword'))"
-- then uncomment and fill in:
--
-- INSERT INTO [mbpw].[users] ([id], [email], [name], [role], [hashed_password],
--                             [is_active], [created_at], [last_login], [avatar_url])
-- VALUES ('REPLACE-WITH-UUID4', 'admin@mbpw.com', 'Admin', 'superadmin',
--         'REPLACE-WITH-BCRYPT-HASH', 1, SYSUTCDATETIME(), NULL, N'');
--
-- provider_performance is intentionally left empty: learn.py starts every
-- unknown provider at 0.5 reliability.


/* =============================================================================
   SECTION 13  ::  PERMISSIONS
   ============================================================================= */

BEGIN TRY
    GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[mbpw] TO [mbpw_app];
    GRANT EXECUTE ON SCHEMA::[mbpw] TO [mbpw_app];
END TRY
BEGIN CATCH
    PRINT 'NOTICE: schema-level grants skipped (' + ERROR_MESSAGE() + ').';
END CATCH
GO

-- Optional read-only reporting role
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'mbpw_readonly')
BEGIN
    BEGIN TRY
        CREATE USER [mbpw_readonly] FOR LOGIN [mbpw_readonly] WITH DEFAULT_SCHEMA = [mbpw];
    END TRY
    BEGIN CATCH
        PRINT 'NOTICE: read-only user skipped (login mbpw_readonly not present).';
    END CATCH
END
GO

BEGIN TRY
    GRANT SELECT ON SCHEMA::[mbpw] TO [mbpw_readonly];
END TRY
BEGIN CATCH
    PRINT 'NOTICE: read-only grant skipped (' + ERROR_MESSAGE() + ').';
END CATCH
GO


/* =============================================================================
   SECTION 14  ::  OPTIONAL STRICT MODE - commented out on purpose
   -----------------------------------------------------------------------------
   Read TRANSLATION NOTE 12 first. Enable these AFTER auditing your data,
   one at a time.

   CHECK constraints
   -----------------
   ALTER TABLE [mbpw].[leads] WITH CHECK ADD CONSTRAINT [ck_leads_status]
       CHECK ([status] IN (SELECT [code] FROM [mbpw].[ref_lead_status]));
   ALTER TABLE [mbpw].[leads] WITH CHECK ADD CONSTRAINT [ck_leads_probability]
       CHECK ([success_probability] BETWEEN 0 AND 100);
   ALTER TABLE [mbpw].[leads] WITH CHECK ADD CONSTRAINT [ck_leads_difficulty]
       CHECK ([difficulty] BETWEEN 0 AND 100);
   ALTER TABLE [mbpw].[users] WITH CHECK ADD CONSTRAINT [ck_users_role]
       CHECK ([role] IN (N'user', N'admin', N'superadmin'));
   ALTER TABLE [mbpw].[proposals] WITH CHECK ADD CONSTRAINT [ck_proposals_status]
       CHECK ([status] IN (N'draft', N'review', N'submitted', N'accepted', N'rejected'));
   ALTER TABLE [mbpw].[outreach] WITH CHECK ADD CONSTRAINT [ck_outreach_status]
       CHECK ([status] IN (N'sent', N'simulated', N'logged', N'replied', N'failed'));
   ALTER TABLE [mbpw].[outreach_states] WITH CHECK ADD CONSTRAINT [ck_outreach_states_status]
       CHECK ([status] IN (N'active', N'paused', N'needs_email', N'completed'));
   ALTER TABLE [mbpw].[contact_intel] WITH CHECK ADD CONSTRAINT [ck_contact_intel_supply]
       CHECK ([supply_status] IN (N'ok', N'bounced', N'opted_out', N'suppressed'));

   Foreign keys (safe ones - lead_id is always a real id there)
   -----------------------------------------------------------
   ALTER TABLE [mbpw].[contact_intel]   WITH CHECK ADD CONSTRAINT [fk_ci_lead]
       FOREIGN KEY ([lead_id]) REFERENCES [mbpw].[leads]([id]) ON DELETE CASCADE;
   ALTER TABLE [mbpw].[outreach_states] WITH CHECK ADD CONSTRAINT [fk_os_lead]
       FOREIGN KEY ([lead_id]) REFERENCES [mbpw].[leads]([id]) ON DELETE CASCADE;
   ALTER TABLE [mbpw].[lead_technologies] WITH CHECK ADD CONSTRAINT [fk_lt_lead]
       FOREIGN KEY ([lead_id]) REFERENCES [mbpw].[leads]([id]) ON DELETE CASCADE;
   ALTER TABLE [mbpw].[lead_tags] WITH CHECK ADD CONSTRAINT [fk_ltag_lead]
       FOREIGN KEY ([lead_id]) REFERENCES [mbpw].[leads]([id]) ON DELETE CASCADE;

   Foreign keys (risky - see TRANSLATION NOTE 12)
   -------------------------------------------------
   -- outreach.lead_id     : rows exist with lead_id = ''
   -- contacts.company_id  : companyId is echoed unvalidated
   -- proposals.lead_id    : '' is written by POST /api/proposals/generate

   Optional: SQL Server's answer to the missing pg_trgm ILIKE indexes.
   Run separately (a full-text catalog is a database-level object):
       CREATE FULLTEXT CATALOG [mbpw_ft] AS DEFAULT;
       CREATE FULLTEXT INDEX ON [mbpw].[leads]
           (title, company, client_name) KEY INDEX pk_leads;
       ... then:  SELECT ... FROM leads WHERE CONTAINS ([title], '"react"');
   ============================================================================= */


/* =============================================================================
   SECTION 15  ::  VERIFICATION
   ============================================================================= */

SELECT 'base tables' AS [object], COUNT(*) AS [n]
  FROM sys.objects WHERE schema_id = SCHEMA_ID(N'mbpw') AND type = N'U'
UNION ALL
SELECT 'views',      COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N'mbpw') AND type = N'V'
UNION ALL
SELECT 'functions',  COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N'mbpw') AND type IN (N'FN', N'IF', N'TF')
UNION ALL
SELECT 'triggers',   COUNT(*) FROM sys.triggers
 WHERE SCHEMA_NAME(schema_id) = N'mbpw' AND is_ms_shipped = 0
UNION ALL
SELECT 'indexes',    COUNT(DISTINCT i.[object_id])
  FROM sys.indexes AS i
  JOIN sys.schemas AS s ON s.[schema_id] = i.[schema_id]
 WHERE s.[name] = N'mbpw'
UNION ALL
SELECT 'constraints', COUNT(*)
  FROM sys.objects WHERE schema_id = SCHEMA_ID(N'mbpw') AND type IN (N'C', N'F', N'PK', N'UQ', N'D');
-- Expected: 41 base tables (17 application + 21 ref_* + 3 JSON projection),
--           11 views, 7 functions, 8 triggers, 0 foreign keys by design.

SELECT * FROM [mbpw].[v_system_stats];
SELECT * FROM [mbpw].[v_pipeline_report] ORDER BY [sort_order];
SELECT TOP (10) * FROM [mbpw].[v_platform_breakdown]   ORDER BY [leads] DESC;
SELECT TOP (10) * FROM [mbpw].[v_technology_breakdown] ORDER BY [lead_count] DESC;
SELECT TOP (10) * FROM [mbpw].[v_country_breakdown]    ORDER BY [lead_count] DESC;
SELECT * FROM [mbpw].[v_agent_performance];
SELECT TOP (20) * FROM [mbpw].[v_outreach_queue];
SELECT * FROM [mbpw].[fn_compliance_gate](N'REPLACE-WITH-A-LEAD-ID');

PRINT '--- MBPW schema ready. Point the backend at this database and start the API. ---';
GO
