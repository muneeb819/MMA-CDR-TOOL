import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test, expect } from '../fixtures/test.js';

const ddl = readFileSync(path.resolve('database/mma-cdr-sqlserver.sql'), 'utf8');
const actualTables = [...ddl.matchAll(/^CREATE TABLE dbo\.([A-Za-z0-9_]+)/gm)].map(match => match[1]);
const actualProcedures = [...ddl.matchAll(/^CREATE PROCEDURE dbo\.([A-Za-z0-9_]+)/gm)].map(match => match[1]);
const actualViews = [...ddl.matchAll(/^CREATE VIEW dbo\.([A-Za-z0-9_]+)/gm)].map(match => match[1]);
const actualIndexes = [...ddl.matchAll(/^CREATE INDEX ([A-Za-z0-9_]+)/gm)].map(match => match[1]);

test.describe('SQL Server DDL source contract @database @regression', () => {
  test('authoritative schema contains its 16 actual tables, 11 procedures and 5 views', () => {
    expect(actualTables).toHaveLength(16);
    expect(actualTables).toEqual(expect.arrayContaining([
      'tenants', 'campaigns', 'upload_batches', 'upload_files', 'raw_records', 'phone_numbers',
      'leads', 'calls', 'suppressions', 'verifications', 'decisions', 'telemetry_snapshots',
      'alerts', 'audit_logs', 'source_quality_daily', 'processing_jobs',
    ]));
    expect(actualProcedures).toHaveLength(11);
    expect(actualProcedures).toEqual(expect.arrayContaining([
      'usp_GetOrCreateTenant', 'usp_UpsertPhone', 'usp_CreateUploadBatch', 'usp_RecordRawPhone',
      'usp_CheckSuppression', 'usp_InsertTelemetry', 'usp_InsertAlert', 'usp_InsertDecision',
      'usp_CompleteUploadBatch', 'usp_ClaimProcessingJob', 'usp_WriteAudit',
    ]));
    expect(actualViews).toHaveLength(5);
    expect(actualViews).toEqual(expect.arrayContaining([
      'vw_latest_phone_verification', 'vw_active_suppressions', 'vw_upload_summary',
      'vw_campaign_telemetry_latest', 'vw_cdr_decision_summary',
    ]));
    expect(actualIndexes).toHaveLength(20);
  });

  test('key data types, nullability, keys, checks and tenant-scoped uniqueness match DDL', () => {
    expect(ddl).toMatch(/tenant_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_tenants PRIMARY KEY/);
    expect(ddl).toMatch(/file_size_bytes BIGINT NOT NULL CONSTRAINT CK_upload_batches_size CHECK \(file_size_bytes >= 0\)/);
    expect(ddl).toMatch(/original_file_name NVARCHAR\(512\) NOT NULL/);
    expect(ddl).toMatch(/detected_mime_type NVARCHAR\(255\) NULL/);
    expect(ddl).toMatch(/phone_hash CHAR\(64\) NOT NULL/);
    expect(ddl).toMatch(/CONSTRAINT UQ_phone_tenant_hash UNIQUE \(tenant_id, phone_hash\)/);
    expect(ddl).toMatch(/CONSTRAINT UQ_campaigns_tenant_key UNIQUE \(tenant_id, campaign_key\)/);
    expect(ddl).toMatch(/CONSTRAINT CK_supp_dates CHECK \(expires_at IS NULL OR expires_at >= effective_at\)/);
    expect(ddl).toMatch(/CONSTRAINT FK_telemetry_campaign FOREIGN KEY \(campaign_id\) REFERENCES dbo\.campaigns\(campaign_id\)/);
    expect(ddl).toMatch(/drop_percent DECIMAL\(8,3\) NOT NULL CONSTRAINT CK_telemetry_drop CHECK \(drop_percent >= 0\)/);
    expect(ddl).toMatch(/timezone_name NVARCHAR\(100\) NOT NULL CONSTRAINT DF_tenants_timezone DEFAULT N'UTC'/);
  });

  test('operational indexes and stored procedures named in the DDL are present', () => {
    expect(actualIndexes).toEqual(expect.arrayContaining([
      'IX_upload_batches_tenant_created', 'IX_raw_records_batch_row', 'IX_phone_numbers_tenant_phone',
      'IX_suppressions_lookup', 'IX_decisions_campaign_date', 'IX_telemetry_campaign_observed',
      'IX_jobs_status_created',
    ]));
    expect(ddl).toContain('WITH (UPDLOCK,READPAST,ROWLOCK)');
    expect(ddl).toContain('CREATE VIEW dbo.vw_active_suppressions');
    expect(ddl).toContain('CREATE VIEW dbo.vw_campaign_telemetry_latest');
  });
});
