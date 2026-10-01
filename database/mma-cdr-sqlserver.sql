/* CDR Intelligence V2.1 - Microsoft SQL Server / SSMS
   Target: SQL Server 2012+ (SSMS is only the management client).
   Run this script in SSMS while connected to an account allowed to create the database.
*/

IF DB_ID(N'CDR_Intelligence') IS NULL
BEGIN
    CREATE DATABASE [CDR_Intelligence];
END
GO

USE [CDR_Intelligence];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
GO

/* Core tenancy */
IF OBJECT_ID(N'dbo.tenants', N'U') IS NULL
CREATE TABLE dbo.tenants (
    tenant_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_tenants PRIMARY KEY DEFAULT NEWID(),
    tenant_key NVARCHAR(100) NOT NULL CONSTRAINT UQ_tenants_key UNIQUE,
    name NVARCHAR(200) NOT NULL,
    timezone_name NVARCHAR(100) NOT NULL CONSTRAINT DF_tenants_timezone DEFAULT N'UTC',
    is_active BIT NOT NULL CONSTRAINT DF_tenants_active DEFAULT 1,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_tenants_created DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID(N'dbo.campaigns', N'U') IS NULL
CREATE TABLE dbo.campaigns (
    campaign_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_campaigns PRIMARY KEY DEFAULT NEWID(),
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    campaign_key NVARCHAR(100) NOT NULL,
    name NVARCHAR(200) NOT NULL,
    source_system NVARCHAR(100) NULL,
    is_active BIT NOT NULL CONSTRAINT DF_campaigns_active DEFAULT 1,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_campaigns_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_campaigns_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT UQ_campaigns_tenant_key UNIQUE (tenant_id, campaign_key)
);
GO

/* Universal upload/import tracking */
IF OBJECT_ID(N'dbo.upload_batches', N'U') IS NULL
CREATE TABLE dbo.upload_batches (
    upload_batch_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_upload_batches PRIMARY KEY DEFAULT NEWID(),
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    original_file_name NVARCHAR(512) NOT NULL,
    detected_extension NVARCHAR(32) NULL,
    detected_mime_type NVARCHAR(255) NULL,
    file_size_bytes BIGINT NOT NULL CONSTRAINT CK_upload_batches_size CHECK (file_size_bytes >= 0),
    sha256_hex CHAR(64) NULL,
    ingestion_mode NVARCHAR(40) NOT NULL CONSTRAINT DF_upload_batches_mode DEFAULT N'UPLOAD',
    status NVARCHAR(30) NOT NULL CONSTRAINT DF_upload_batches_status DEFAULT N'RECEIVED',
    total_records BIGINT NOT NULL CONSTRAINT DF_upload_batches_total DEFAULT 0,
    accepted_records BIGINT NOT NULL CONSTRAINT DF_upload_batches_accepted DEFAULT 0,
    rejected_records BIGINT NOT NULL CONSTRAINT DF_upload_batches_rejected DEFAULT 0,
    extracted_phone_count BIGINT NOT NULL CONSTRAINT DF_upload_batches_phone_count DEFAULT 0,
    error_message NVARCHAR(4000) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_upload_batches_created DEFAULT SYSUTCDATETIME(),
    completed_at DATETIME2(3) NULL,
    CONSTRAINT FK_upload_batches_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_upload_batches_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id)
);
GO

IF OBJECT_ID(N'dbo.upload_files', N'U') IS NULL
CREATE TABLE dbo.upload_files (
    upload_file_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_upload_files PRIMARY KEY,
    upload_batch_id UNIQUEIDENTIFIER NOT NULL,
    file_name NVARCHAR(512) NOT NULL,
    extension NVARCHAR(32) NULL,
    mime_type NVARCHAR(255) NULL,
    sha256_hex CHAR(64) NOT NULL,
    file_size_bytes BIGINT NOT NULL,
    raw_file VARBINARY(MAX) NULL,
    extraction_status NVARCHAR(30) NOT NULL CONSTRAINT DF_upload_files_status DEFAULT N'PENDING',
    extraction_message NVARCHAR(4000) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_upload_files_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_upload_files_batch FOREIGN KEY (upload_batch_id) REFERENCES dbo.upload_batches(upload_batch_id)
);
GO

IF OBJECT_ID(N'dbo.raw_records', N'U') IS NULL
CREATE TABLE dbo.raw_records (
    raw_record_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_raw_records PRIMARY KEY,
    upload_batch_id UNIQUEIDENTIFIER NOT NULL,
    source_row_number BIGINT NULL,
    source_locator NVARCHAR(1024) NULL,
    raw_text NVARCHAR(MAX) NULL,
    normalized_phone NVARCHAR(32) NULL,
    fingerprint_sha256 CHAR(64) NULL,
    parse_status NVARCHAR(30) NOT NULL CONSTRAINT DF_raw_records_status DEFAULT N'RECEIVED',
    parse_message NVARCHAR(2000) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_raw_records_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_raw_records_batch FOREIGN KEY (upload_batch_id) REFERENCES dbo.upload_batches(upload_batch_id)
);
GO

/* Canonical phone/lead data */
IF OBJECT_ID(N'dbo.phone_numbers', N'U') IS NULL
CREATE TABLE dbo.phone_numbers (
    phone_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_phone_numbers PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    e164_phone NVARCHAR(32) NOT NULL,
    phone_hash CHAR(64) NOT NULL,
    country_code NVARCHAR(8) NULL,
    national_number NVARCHAR(32) NULL,
    carrier_name NVARCHAR(200) NULL,
    line_type NVARCHAR(50) NULL,
    is_reachable BIT NULL,
    is_ported BIT NULL,
    is_reassigned BIT NULL,
    last_verified_at DATETIME2(3) NULL,
    data_freshness_at DATETIME2(3) NULL,
    first_seen_at DATETIME2(3) NOT NULL CONSTRAINT DF_phone_first_seen DEFAULT SYSUTCDATETIME(),
    last_seen_at DATETIME2(3) NOT NULL CONSTRAINT DF_phone_last_seen DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_phone_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT UQ_phone_tenant_hash UNIQUE (tenant_id, phone_hash)
);
GO

IF OBJECT_ID(N'dbo.leads', N'U') IS NULL
CREATE TABLE dbo.leads (
    lead_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_leads PRIMARY KEY DEFAULT NEWID(),
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    phone_id BIGINT NULL,
    external_lead_key NVARCHAR(200) NULL,
    first_name NVARCHAR(200) NULL,
    last_name NVARCHAR(200) NULL,
    state_code NVARCHAR(8) NULL,
    source_name NVARCHAR(200) NULL,
    source_file_name NVARCHAR(512) NULL,
    raw_payload NVARCHAR(MAX) NULL,
    status NVARCHAR(40) NOT NULL CONSTRAINT DF_leads_status DEFAULT N'NEW',
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_leads_created DEFAULT SYSUTCDATETIME(),
    updated_at DATETIME2(3) NOT NULL CONSTRAINT DF_leads_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_leads_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_leads_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id),
    CONSTRAINT FK_leads_phone FOREIGN KEY (phone_id) REFERENCES dbo.phone_numbers(phone_id)
);
GO

IF OBJECT_ID(N'dbo.calls', N'U') IS NULL
CREATE TABLE dbo.calls (
    call_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_calls PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    lead_id UNIQUEIDENTIFIER NULL,
    phone_id BIGINT NULL,
    vicidial_uniqueid NVARCHAR(100) NULL,
    call_date DATETIME2(3) NULL,
    answer_date DATETIME2(3) NULL,
    end_date DATETIME2(3) NULL,
    duration_seconds INT NULL,
    status_code NVARCHAR(100) NULL,
    disposition NVARCHAR(100) NULL,
    agent_user NVARCHAR(100) NULL,
    transfer_number NVARCHAR(64) NULL,
    is_answered BIT NULL,
    is_transferred BIT NULL,
    is_sale BIT NULL,
    raw_payload NVARCHAR(MAX) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_calls_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_calls_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_calls_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id),
    CONSTRAINT FK_calls_lead FOREIGN KEY (lead_id) REFERENCES dbo.leads(lead_id),
    CONSTRAINT FK_calls_phone FOREIGN KEY (phone_id) REFERENCES dbo.phone_numbers(phone_id)
);
GO

/* Suppression/compliance */
IF OBJECT_ID(N'dbo.suppressions', N'U') IS NULL
CREATE TABLE dbo.suppressions (
    suppression_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_suppressions PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    phone_hash CHAR(64) NOT NULL,
    scope_type NVARCHAR(40) NOT NULL CONSTRAINT DF_supp_scope DEFAULT N'TENANT',
    reason_code NVARCHAR(100) NOT NULL,
    source_name NVARCHAR(200) NULL,
    effective_at DATETIME2(3) NOT NULL CONSTRAINT DF_supp_effective DEFAULT SYSUTCDATETIME(),
    expires_at DATETIME2(3) NULL,
    consent_reference NVARCHAR(300) NULL,
    notes NVARCHAR(2000) NULL,
    is_active BIT NOT NULL CONSTRAINT DF_supp_active DEFAULT 1,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_supp_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_supp_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT CK_supp_dates CHECK (expires_at IS NULL OR expires_at >= effective_at)
);
GO

IF OBJECT_ID(N'dbo.verifications', N'U') IS NULL
CREATE TABLE dbo.verifications (
    verification_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_verifications PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    phone_id BIGINT NULL,
    provider_name NVARCHAR(100) NOT NULL,
    checked_at DATETIME2(3) NOT NULL CONSTRAINT DF_verifications_checked DEFAULT SYSUTCDATETIME(),
    reachable BIT NULL,
    line_type NVARCHAR(50) NULL,
    carrier_name NVARCHAR(200) NULL,
    ported BIT NULL,
    reassigned BIT NULL,
    confidence DECIMAL(6,5) NULL,
    raw_response NVARCHAR(MAX) NULL,
    CONSTRAINT FK_verifications_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_verifications_phone FOREIGN KEY (phone_id) REFERENCES dbo.phone_numbers(phone_id)
);
GO

IF OBJECT_ID(N'dbo.decisions', N'U') IS NULL
CREATE TABLE dbo.decisions (
    decision_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_decisions PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    lead_id UNIQUEIDENTIFIER NULL,
    phone_id BIGINT NULL,
    decision_code NVARCHAR(30) NOT NULL,
    quality_score DECIMAL(6,2) NULL,
    contactability_score DECIMAL(6,2) NULL,
    risk_score DECIMAL(6,2) NULL,
    confidence DECIMAL(6,5) NULL,
    compliance_status NVARCHAR(40) NULL,
    reasons NVARCHAR(MAX) NULL,
    ruleset_version NVARCHAR(50) NULL,
    model_version NVARCHAR(50) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_decisions_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_decisions_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_decisions_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id),
    CONSTRAINT FK_decisions_lead FOREIGN KEY (lead_id) REFERENCES dbo.leads(lead_id),
    CONSTRAINT FK_decisions_phone FOREIGN KEY (phone_id) REFERENCES dbo.phone_numbers(phone_id)
);
GO

/* Realtime operational telemetry */
IF OBJECT_ID(N'dbo.telemetry_snapshots', N'U') IS NULL
CREATE TABLE dbo.telemetry_snapshots (
    telemetry_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_telemetry_snapshots PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    observed_at DATETIME2(3) NOT NULL,
    source_url NVARCHAR(1000) NULL,
    agents_logged_in INT NOT NULL CONSTRAINT CK_telemetry_logged CHECK (agents_logged_in >= 0),
    agents_in_call INT NOT NULL CONSTRAINT CK_telemetry_incall CHECK (agents_in_call >= 0),
    agents_waiting INT NOT NULL CONSTRAINT CK_telemetry_waiting CHECK (agents_waiting >= 0),
    agents_paused INT NOT NULL CONSTRAINT CK_telemetry_paused CHECK (agents_paused >= 0),
    calls_in_queue INT NOT NULL CONSTRAINT CK_telemetry_queue CHECK (calls_in_queue >= 0),
    drop_percent DECIMAL(8,3) NOT NULL CONSTRAINT CK_telemetry_drop CHECK (drop_percent >= 0),
    dial_level DECIMAL(12,3) NULL,
    raw_payload NVARCHAR(MAX) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_telemetry_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_telemetry_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_telemetry_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id)
);
GO

IF OBJECT_ID(N'dbo.alerts', N'U') IS NULL
CREATE TABLE dbo.alerts (
    alert_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_alerts PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NULL,
    campaign_id UNIQUEIDENTIFIER NULL,
    telemetry_id BIGINT NULL,
    severity NVARCHAR(20) NOT NULL,
    alert_type NVARCHAR(80) NOT NULL,
    message NVARCHAR(2000) NOT NULL,
    evidence NVARCHAR(MAX) NULL,
    status NVARCHAR(20) NOT NULL CONSTRAINT DF_alert_status DEFAULT N'OPEN',
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_alert_created DEFAULT SYSUTCDATETIME(),
    resolved_at DATETIME2(3) NULL,
    CONSTRAINT FK_alert_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_alert_campaign FOREIGN KEY (campaign_id) REFERENCES dbo.campaigns(campaign_id),
    CONSTRAINT FK_alert_telemetry FOREIGN KEY (telemetry_id) REFERENCES dbo.telemetry_snapshots(telemetry_id)
);
GO

IF OBJECT_ID(N'dbo.audit_logs', N'U') IS NULL
CREATE TABLE dbo.audit_logs (
    audit_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_logs PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NULL,
    actor_type NVARCHAR(40) NOT NULL,
    actor_id NVARCHAR(200) NULL,
    action_code NVARCHAR(100) NOT NULL,
    entity_type NVARCHAR(100) NULL,
    entity_id NVARCHAR(200) NULL,
    details NVARCHAR(MAX) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_audit_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_audit_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id)
);
GO

IF OBJECT_ID(N'dbo.source_quality_daily', N'U') IS NULL
CREATE TABLE dbo.source_quality_daily (
    quality_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_source_quality_daily PRIMARY KEY,
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    source_name NVARCHAR(200) NOT NULL,
    quality_date DATE NOT NULL,
    records_seen BIGINT NOT NULL CONSTRAINT DF_quality_seen DEFAULT 0,
    valid_records BIGINT NOT NULL CONSTRAINT DF_quality_valid DEFAULT 0,
    duplicate_records BIGINT NOT NULL CONSTRAINT DF_quality_dup DEFAULT 0,
    suppressed_records BIGINT NOT NULL CONSTRAINT DF_quality_supp DEFAULT 0,
    extracted_phones BIGINT NOT NULL CONSTRAINT DF_quality_phone DEFAULT 0,
    invalid_phones BIGINT NOT NULL CONSTRAINT DF_quality_invalid DEFAULT 0,
    CONSTRAINT FK_quality_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT UQ_quality_day UNIQUE (tenant_id, source_name, quality_date)
);
GO

IF OBJECT_ID(N'dbo.processing_jobs', N'U') IS NULL
CREATE TABLE dbo.processing_jobs (
    job_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_processing_jobs PRIMARY KEY DEFAULT NEWID(),
    tenant_id UNIQUEIDENTIFIER NOT NULL,
    upload_batch_id UNIQUEIDENTIFIER NULL,
    job_type NVARCHAR(80) NOT NULL,
    status NVARCHAR(30) NOT NULL CONSTRAINT DF_jobs_status DEFAULT N'QUEUED',
    attempts INT NOT NULL CONSTRAINT DF_jobs_attempts DEFAULT 0,
    progress_percent DECIMAL(6,2) NOT NULL CONSTRAINT DF_jobs_progress DEFAULT 0,
    error_message NVARCHAR(4000) NULL,
    started_at DATETIME2(3) NULL,
    finished_at DATETIME2(3) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_jobs_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_jobs_tenant FOREIGN KEY (tenant_id) REFERENCES dbo.tenants(tenant_id),
    CONSTRAINT FK_jobs_batch FOREIGN KEY (upload_batch_id) REFERENCES dbo.upload_batches(upload_batch_id)
);
GO

/* Indexes */
CREATE INDEX IX_campaigns_tenant_active ON dbo.campaigns(tenant_id, is_active);
CREATE INDEX IX_upload_batches_tenant_created ON dbo.upload_batches(tenant_id, created_at DESC);
CREATE INDEX IX_upload_batches_status ON dbo.upload_batches(status, created_at DESC);
CREATE INDEX IX_upload_files_batch ON dbo.upload_files(upload_batch_id);
CREATE INDEX IX_raw_records_batch_row ON dbo.raw_records(upload_batch_id, source_row_number);
CREATE INDEX IX_raw_records_phone ON dbo.raw_records(normalized_phone);
CREATE INDEX IX_phone_numbers_tenant_phone ON dbo.phone_numbers(tenant_id, e164_phone);
CREATE INDEX IX_leads_tenant_status ON dbo.leads(tenant_id, status, created_at DESC);
CREATE INDEX IX_leads_campaign ON dbo.leads(campaign_id, created_at DESC);
CREATE INDEX IX_calls_campaign_date ON dbo.calls(campaign_id, call_date DESC);
CREATE INDEX IX_calls_phone_date ON dbo.calls(phone_id, call_date DESC);
CREATE INDEX IX_calls_disposition ON dbo.calls(tenant_id, disposition, call_date DESC);
CREATE INDEX IX_suppressions_lookup ON dbo.suppressions(tenant_id, phone_hash, is_active, effective_at, expires_at);
CREATE INDEX IX_verifications_phone_date ON dbo.verifications(phone_id, checked_at DESC);
CREATE INDEX IX_decisions_lead_date ON dbo.decisions(lead_id, created_at DESC);
CREATE INDEX IX_decisions_campaign_date ON dbo.decisions(campaign_id, created_at DESC);
CREATE INDEX IX_telemetry_campaign_observed ON dbo.telemetry_snapshots(campaign_id, observed_at DESC);
CREATE INDEX IX_alerts_campaign_status ON dbo.alerts(campaign_id, status, created_at DESC);
CREATE INDEX IX_audit_tenant_created ON dbo.audit_logs(tenant_id, created_at DESC);
CREATE INDEX IX_jobs_status_created ON dbo.processing_jobs(status, created_at);
GO

/* Stored procedures */
IF OBJECT_ID(N'dbo.usp_GetOrCreateTenant', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_GetOrCreateTenant;
GO
CREATE PROCEDURE dbo.usp_GetOrCreateTenant
    @TenantKey NVARCHAR(100), @Name NVARCHAR(200), @Timezone NVARCHAR(100) = N'UTC'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TenantId UNIQUEIDENTIFIER;
    SELECT @TenantId = tenant_id FROM dbo.tenants WHERE tenant_key=@TenantKey;
    IF @TenantId IS NULL
    BEGIN
        SET @TenantId=NEWID();
        INSERT dbo.tenants(tenant_id,tenant_key,name,timezone_name) VALUES(@TenantId,@TenantKey,@Name,@Timezone);
    END
    SELECT * FROM dbo.tenants WHERE tenant_id=@TenantId;
END
GO

IF OBJECT_ID(N'dbo.usp_UpsertPhone', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_UpsertPhone;
GO
CREATE PROCEDURE dbo.usp_UpsertPhone
    @TenantId UNIQUEIDENTIFIER, @E164Phone NVARCHAR(32), @PhoneHash CHAR(64),
    @CountryCode NVARCHAR(8)=NULL, @NationalNumber NVARCHAR(32)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PhoneId BIGINT;
    SELECT @PhoneId=phone_id FROM dbo.phone_numbers WHERE tenant_id=@TenantId AND phone_hash=@PhoneHash;
    IF @PhoneId IS NULL
    BEGIN
        INSERT dbo.phone_numbers(tenant_id,e164_phone,phone_hash,country_code,national_number)
        VALUES(@TenantId,@E164Phone,@PhoneHash,@CountryCode,@NationalNumber);
        SET @PhoneId=SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.phone_numbers SET e164_phone=@E164Phone,last_seen_at=SYSUTCDATETIME() WHERE phone_id=@PhoneId;
    SELECT * FROM dbo.phone_numbers WHERE phone_id=@PhoneId;
END
GO

IF OBJECT_ID(N'dbo.usp_CreateUploadBatch', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_CreateUploadBatch;
GO
CREATE PROCEDURE dbo.usp_CreateUploadBatch
    @TenantId UNIQUEIDENTIFIER, @CampaignId UNIQUEIDENTIFIER=NULL, @FileName NVARCHAR(512),
    @Extension NVARCHAR(32)=NULL, @MimeType NVARCHAR(255)=NULL, @SizeBytes BIGINT, @Sha256 CHAR(64)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id UNIQUEIDENTIFIER=NEWID();
    INSERT dbo.upload_batches(upload_batch_id,tenant_id,campaign_id,original_file_name,detected_extension,detected_mime_type,file_size_bytes,sha256_hex)
    VALUES(@Id,@TenantId,@CampaignId,@FileName,@Extension,@MimeType,@SizeBytes,@Sha256);
    SELECT * FROM dbo.upload_batches WHERE upload_batch_id=@Id;
END
GO

IF OBJECT_ID(N'dbo.usp_RecordRawPhone', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_RecordRawPhone;
GO
CREATE PROCEDURE dbo.usp_RecordRawPhone
    @UploadBatchId UNIQUEIDENTIFIER, @RowNumber BIGINT=NULL, @Locator NVARCHAR(1024)=NULL,
    @RawText NVARCHAR(MAX)=NULL, @NormalizedPhone NVARCHAR(32)=NULL, @Fingerprint CHAR(64)=NULL,
    @ParseStatus NVARCHAR(30)=N'PARSED', @ParseMessage NVARCHAR(2000)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.raw_records(upload_batch_id,source_row_number,source_locator,raw_text,normalized_phone,fingerprint_sha256,parse_status,parse_message)
    VALUES(@UploadBatchId,@RowNumber,@Locator,@RawText,@NormalizedPhone,@Fingerprint,@ParseStatus,@ParseMessage);
    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS raw_record_id;
END
GO

IF OBJECT_ID(N'dbo.usp_CheckSuppression', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_CheckSuppression;
GO
CREATE PROCEDURE dbo.usp_CheckSuppression
    @TenantId UNIQUEIDENTIFIER, @PhoneHash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 suppression_id,reason_code,source_name,effective_at,expires_at,scope_type
    FROM dbo.suppressions
    WHERE tenant_id=@TenantId AND phone_hash=@PhoneHash AND is_active=1
      AND effective_at<=SYSUTCDATETIME()
      AND (expires_at IS NULL OR expires_at>=SYSUTCDATETIME())
    ORDER BY effective_at DESC, suppression_id DESC;
END
GO

IF OBJECT_ID(N'dbo.usp_InsertTelemetry', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_InsertTelemetry;
GO
CREATE PROCEDURE dbo.usp_InsertTelemetry
    @TenantId UNIQUEIDENTIFIER=NULL, @CampaignId UNIQUEIDENTIFIER=NULL, @ObservedAt DATETIME2(3),
    @SourceUrl NVARCHAR(1000)=NULL, @AgentsLoggedIn INT, @AgentsInCall INT, @AgentsWaiting INT,
    @AgentsPaused INT, @CallsInQueue INT, @DropPercent DECIMAL(8,3), @DialLevel DECIMAL(12,3)=NULL,
    @RawPayload NVARCHAR(MAX)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.telemetry_snapshots(tenant_id,campaign_id,observed_at,source_url,agents_logged_in,agents_in_call,agents_waiting,agents_paused,calls_in_queue,drop_percent,dial_level,raw_payload)
    VALUES(@TenantId,@CampaignId,@ObservedAt,@SourceUrl,@AgentsLoggedIn,@AgentsInCall,@AgentsWaiting,@AgentsPaused,@CallsInQueue,@DropPercent,@DialLevel,@RawPayload);
    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS telemetry_id;
END
GO

IF OBJECT_ID(N'dbo.usp_InsertAlert', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_InsertAlert;
GO
CREATE PROCEDURE dbo.usp_InsertAlert
    @TenantId UNIQUEIDENTIFIER=NULL,@CampaignId UNIQUEIDENTIFIER=NULL,@TelemetryId BIGINT=NULL,
    @Severity NVARCHAR(20),@AlertType NVARCHAR(80),@Message NVARCHAR(2000),@Evidence NVARCHAR(MAX)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.alerts(tenant_id,campaign_id,telemetry_id,severity,alert_type,message,evidence)
    VALUES(@TenantId,@CampaignId,@TelemetryId,@Severity,@AlertType,@Message,@Evidence);
    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS alert_id;
END
GO

IF OBJECT_ID(N'dbo.usp_InsertDecision', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_InsertDecision;
GO
CREATE PROCEDURE dbo.usp_InsertDecision
    @TenantId UNIQUEIDENTIFIER,@CampaignId UNIQUEIDENTIFIER=NULL,@LeadId UNIQUEIDENTIFIER=NULL,@PhoneId BIGINT=NULL,
    @DecisionCode NVARCHAR(30),@QualityScore DECIMAL(6,2)=NULL,@ContactabilityScore DECIMAL(6,2)=NULL,
    @RiskScore DECIMAL(6,2)=NULL,@Confidence DECIMAL(6,5)=NULL,@ComplianceStatus NVARCHAR(40)=NULL,
    @Reasons NVARCHAR(MAX)=NULL,@RulesetVersion NVARCHAR(50)=NULL,@ModelVersion NVARCHAR(50)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.decisions(tenant_id,campaign_id,lead_id,phone_id,decision_code,quality_score,contactability_score,risk_score,confidence,compliance_status,reasons,ruleset_version,model_version)
    VALUES(@TenantId,@CampaignId,@LeadId,@PhoneId,@DecisionCode,@QualityScore,@ContactabilityScore,@RiskScore,@Confidence,@ComplianceStatus,@Reasons,@RulesetVersion,@ModelVersion);
    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS decision_id;
END
GO

IF OBJECT_ID(N'dbo.usp_CompleteUploadBatch', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_CompleteUploadBatch;
GO
CREATE PROCEDURE dbo.usp_CompleteUploadBatch
    @UploadBatchId UNIQUEIDENTIFIER,@Status NVARCHAR(30),@TotalRecords BIGINT,@AcceptedRecords BIGINT,
    @RejectedRecords BIGINT,@ExtractedPhoneCount BIGINT,@ErrorMessage NVARCHAR(4000)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.upload_batches SET status=@Status,total_records=@TotalRecords,accepted_records=@AcceptedRecords,
      rejected_records=@RejectedRecords,extracted_phone_count=@ExtractedPhoneCount,error_message=@ErrorMessage,completed_at=SYSUTCDATETIME()
    WHERE upload_batch_id=@UploadBatchId;
    SELECT * FROM dbo.upload_batches WHERE upload_batch_id=@UploadBatchId;
END
GO

IF OBJECT_ID(N'dbo.usp_ClaimProcessingJob', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_ClaimProcessingJob;
GO
CREATE PROCEDURE dbo.usp_ClaimProcessingJob @WorkerId NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @JobId UNIQUEIDENTIFIER;
    SELECT TOP 1 @JobId=job_id FROM dbo.processing_jobs WITH (UPDLOCK,READPAST,ROWLOCK)
    WHERE status=N'QUEUED' ORDER BY created_at;
    IF @JobId IS NOT NULL
        UPDATE dbo.processing_jobs SET status=N'RUNNING',attempts=attempts+1,started_at=SYSUTCDATETIME() WHERE job_id=@JobId;
    SELECT * FROM dbo.processing_jobs WHERE job_id=@JobId;
END
GO

IF OBJECT_ID(N'dbo.usp_WriteAudit', N'P') IS NOT NULL DROP PROCEDURE dbo.usp_WriteAudit;
GO
CREATE PROCEDURE dbo.usp_WriteAudit
 @TenantId UNIQUEIDENTIFIER=NULL,@ActorType NVARCHAR(40),@ActorId NVARCHAR(200)=NULL,@ActionCode NVARCHAR(100),
 @EntityType NVARCHAR(100)=NULL,@EntityId NVARCHAR(200)=NULL,@Details NVARCHAR(MAX)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 INSERT dbo.audit_logs(tenant_id,actor_type,actor_id,action_code,entity_type,entity_id,details)
 VALUES(@TenantId,@ActorType,@ActorId,@ActionCode,@EntityType,@EntityId,@Details);
END
GO

/* Views */
IF OBJECT_ID(N'dbo.vw_latest_phone_verification', N'V') IS NOT NULL DROP VIEW dbo.vw_latest_phone_verification;
GO
CREATE VIEW dbo.vw_latest_phone_verification AS
SELECT p.phone_id,p.tenant_id,p.e164_phone,p.phone_hash,p.carrier_name,p.line_type,p.is_reachable,p.is_ported,p.is_reassigned,p.last_verified_at
FROM dbo.phone_numbers p;
GO

IF OBJECT_ID(N'dbo.vw_active_suppressions', N'V') IS NOT NULL DROP VIEW dbo.vw_active_suppressions;
GO
CREATE VIEW dbo.vw_active_suppressions AS
SELECT suppression_id,tenant_id,phone_hash,scope_type,reason_code,source_name,effective_at,expires_at
FROM dbo.suppressions
WHERE is_active=1 AND effective_at<=SYSUTCDATETIME() AND (expires_at IS NULL OR expires_at>=SYSUTCDATETIME());
GO

IF OBJECT_ID(N'dbo.vw_upload_summary', N'V') IS NOT NULL DROP VIEW dbo.vw_upload_summary;
GO
CREATE VIEW dbo.vw_upload_summary AS
SELECT tenant_id,status,COUNT(*) AS batch_count,SUM(total_records) AS total_records,
       SUM(accepted_records) AS accepted_records,SUM(rejected_records) AS rejected_records,
       SUM(extracted_phone_count) AS extracted_phone_count,MAX(created_at) AS last_upload_at
FROM dbo.upload_batches GROUP BY tenant_id,status;
GO

IF OBJECT_ID(N'dbo.vw_campaign_telemetry_latest', N'V') IS NOT NULL DROP VIEW dbo.vw_campaign_telemetry_latest;
GO
CREATE VIEW dbo.vw_campaign_telemetry_latest AS
WITH ranked AS (
 SELECT t.*,ROW_NUMBER() OVER(PARTITION BY campaign_id ORDER BY observed_at DESC,telemetry_id DESC) rn
 FROM dbo.telemetry_snapshots t
)
SELECT * FROM ranked WHERE rn=1;
GO

IF OBJECT_ID(N'dbo.vw_cdr_decision_summary', N'V') IS NOT NULL DROP VIEW dbo.vw_cdr_decision_summary;
GO
CREATE VIEW dbo.vw_cdr_decision_summary AS
SELECT tenant_id,decision_code,COUNT_BIG(*) AS decision_count,
       AVG(CAST(quality_score AS DECIMAL(10,2))) AS avg_quality_score,
       AVG(CAST(contactability_score AS DECIMAL(10,2))) AS avg_contactability_score,
       AVG(CAST(risk_score AS DECIMAL(10,2))) AS avg_risk_score,
       MAX(created_at) AS last_decision_at
FROM dbo.decisions GROUP BY tenant_id,decision_code;
GO

/* Seed a local tenant for first-run testing. */
IF NOT EXISTS (SELECT 1 FROM dbo.tenants WHERE tenant_key=N'default')
INSERT dbo.tenants(tenant_key,name,timezone_name) VALUES(N'default',N'Default Tenant',N'UTC');
GO

PRINT 'CDR_Intelligence SQL Server schema installed successfully.';
GO
