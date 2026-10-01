import { randomUUID } from 'node:crypto';
import sql from 'mssql';
import type { ConnectionPool, Transaction } from 'mssql';
import { test, expect } from '../fixtures/test.js';
import { openTestSqlServer, sqlServerIntegrationEnabled } from '../helpers/database.js';

let pool: ConnectionPool | undefined;

test.describe('Dedicated SQL Server integration @database @regression', () => {
  test.skip(!sqlServerIntegrationEnabled(), 'SQL Server integration is opt-in; set RUN_SQLSERVER_TESTS=1 and point SQLSERVER_* at a dedicated *_test or *_qa database.');

  test.beforeAll(async () => {
    pool = await openTestSqlServer();
  });

  test.afterAll(async () => {
    if (pool) await pool.close();
  });

  test('live database contains the exact authoritative tables, columns, types, indexes, procedures and views', async () => {
    const tables = await pool!.request().query("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='dbo' AND TABLE_TYPE='BASE TABLE'");
    expect(tables.recordset.map(row => row.TABLE_NAME)).toHaveLength(16);
    expect(tables.recordset.map(row => row.TABLE_NAME)).toEqual(expect.arrayContaining([
      'tenants', 'campaigns', 'upload_batches', 'upload_files', 'raw_records', 'phone_numbers',
      'leads', 'calls', 'suppressions', 'verifications', 'decisions', 'telemetry_snapshots',
      'alerts', 'audit_logs', 'source_quality_daily', 'processing_jobs',
    ]));

    const columns = await pool!.request().query("SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME='upload_batches'");
    const byName = new Map(columns.recordset.map(row => [row.COLUMN_NAME, row]));
    expect(byName.get('upload_batch_id')).toMatchObject({ DATA_TYPE: 'uniqueidentifier', IS_NULLABLE: 'NO' });
    expect(byName.get('original_file_name')).toMatchObject({ DATA_TYPE: 'nvarchar', IS_NULLABLE: 'NO', CHARACTER_MAXIMUM_LENGTH: 512 });
    expect(byName.get('file_size_bytes')).toMatchObject({ DATA_TYPE: 'bigint', IS_NULLABLE: 'NO' });

    const indexes = await pool!.request().query("SELECT name FROM sys.indexes WHERE object_id IN (SELECT object_id FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo')) AND name IS NOT NULL");
    expect(indexes.recordset.map(row => row.name)).toEqual(expect.arrayContaining([
      'IX_upload_batches_tenant_created', 'IX_phone_numbers_tenant_phone', 'IX_suppressions_lookup',
      'IX_telemetry_campaign_observed', 'IX_jobs_status_created',
    ]));
    const procedures = await pool!.request().query("SELECT name FROM sys.procedures WHERE schema_id=SCHEMA_ID('dbo')");
    const views = await pool!.request().query("SELECT name FROM sys.views WHERE schema_id=SCHEMA_ID('dbo')");
    expect(procedures.recordset).toHaveLength(11);
    expect(views.recordset).toHaveLength(5);
  });

  test('tenant/campaign/upload insert-select-update and rollback leave no data behind', async () => {
    const tenantId = randomUUID();
    const campaignId = randomUUID();
    const batchId = randomUUID();
    const tenantKey = `qa-${tenantId}`;
    const transaction = new sql.Transaction(pool!);
    await transaction.begin();
    try {
      await new sql.Request(transaction)
        .input('id', sql.UniqueIdentifier, tenantId)
        .input('key', sql.NVarChar(100), tenantKey)
        .input('name', sql.NVarChar(200), 'QA transaction probe')
        .query('INSERT dbo.tenants(tenant_id,tenant_key,name) VALUES(@id,@key,@name)');
      await new sql.Request(transaction)
        .input('campaignId', sql.UniqueIdentifier, campaignId)
        .input('tenantId', sql.UniqueIdentifier, tenantId)
        .input('key', sql.NVarChar(100), `campaign-${campaignId}`)
        .input('name', sql.NVarChar(200), 'QA campaign')
        .query('INSERT dbo.campaigns(campaign_id,tenant_id,campaign_key,name) VALUES(@campaignId,@tenantId,@key,@name)');
      await new sql.Request(transaction)
        .input('batchId', sql.UniqueIdentifier, batchId)
        .input('tenantId', sql.UniqueIdentifier, tenantId)
        .input('campaignId', sql.UniqueIdentifier, campaignId)
        .input('name', sql.NVarChar(512), 'qa-transaction.csv')
        .input('size', sql.BigInt, 12)
        .query('INSERT dbo.upload_batches(upload_batch_id,tenant_id,campaign_id,original_file_name,file_size_bytes) VALUES(@batchId,@tenantId,@campaignId,@name,@size)');
      await new sql.Request(transaction)
        .input('batchId', sql.UniqueIdentifier, batchId)
        .query("UPDATE dbo.upload_batches SET status=N'COMPLETED', extracted_phone_count=1 WHERE upload_batch_id=@batchId");
      const selected = await new sql.Request(transaction)
        .input('batchId', sql.UniqueIdentifier, batchId)
        .query('SELECT status,extracted_phone_count FROM dbo.upload_batches WHERE upload_batch_id=@batchId');
      expect(selected.recordset[0]).toMatchObject({ status: 'COMPLETED', extracted_phone_count: 1 });
      await transaction.rollback();
    } catch (error) {
      await rollbackQuietly(transaction);
      throw error;
    }
    const after = await pool!.request().input('id', sql.UniqueIdentifier, tenantId).query('SELECT tenant_id FROM dbo.tenants WHERE tenant_id=@id');
    expect(after.recordset).toHaveLength(0);
  });

  test('defaults, unique protection, check constraints and referential integrity are enforced', async () => {
    const tenantId = randomUUID();
    const tenantKey = `qa-constraints-${tenantId}`;
    const defaultTx: Transaction = new sql.Transaction(pool!);
    await defaultTx.begin();
    let defaultTimezone: string | undefined;
    try {
      await new sql.Request(defaultTx)
        .input('id', sql.UniqueIdentifier, tenantId)
        .input('key', sql.NVarChar(100), tenantKey)
        .input('name', sql.NVarChar(200), 'QA defaults')
        .query('INSERT dbo.tenants(tenant_id,tenant_key,name) VALUES(@id,@key,@name)');
      const row = await new sql.Request(defaultTx)
        .input('id', sql.UniqueIdentifier, tenantId)
        .query('SELECT timezone_name,is_active FROM dbo.tenants WHERE tenant_id=@id');
      defaultTimezone = row.recordset[0]?.timezone_name;
      expect(row.recordset[0]?.is_active).toBe(true);
      await defaultTx.rollback();
    } catch (error) {
      await rollbackQuietly(defaultTx);
      throw error;
    }
    expect(defaultTimezone).toBe('UTC');

    const duplicateTx = new sql.Transaction(pool!);
    await duplicateTx.begin();
    let duplicateRejected = false;
    try {
      for (const id of [randomUUID(), randomUUID()]) {
        await new sql.Request(duplicateTx)
          .input('id', sql.UniqueIdentifier, id)
          .input('key', sql.NVarChar(100), tenantKey)
          .input('name', sql.NVarChar(200), 'duplicate key probe')
          .query('INSERT dbo.tenants(tenant_id,tenant_key,name) VALUES(@id,@key,@name)');
      }
    } catch {
      duplicateRejected = true;
    } finally {
      await rollbackQuietly(duplicateTx);
    }
    expect(duplicateRejected).toBe(true);

    const constraintTx = new sql.Transaction(pool!);
    await constraintTx.begin();
    let checkRejected = false;
    let foreignKeyRejected = false;
    try {
      const validTenant = randomUUID();
      await new sql.Request(constraintTx)
        .input('id', sql.UniqueIdentifier, validTenant)
        .input('key', sql.NVarChar(100), `qa-${validTenant}`)
        .input('name', sql.NVarChar(200), 'QA constraint parent')
        .query('INSERT dbo.tenants(tenant_id,tenant_key,name) VALUES(@id,@key,@name)');
      try {
        await new sql.Request(constraintTx)
          .input('tenantId', sql.UniqueIdentifier, validTenant)
          .input('name', sql.NVarChar(512), 'bad-size.csv')
          .input('size', sql.BigInt, -1)
          .query('INSERT dbo.upload_batches(tenant_id,original_file_name,file_size_bytes) VALUES(@tenantId,@name,@size)');
      } catch {
        checkRejected = true;
      }
      try {
        await new sql.Request(constraintTx)
          .input('campaignId', sql.UniqueIdentifier, randomUUID())
          .input('tenantId', sql.UniqueIdentifier, randomUUID())
          .input('key', sql.NVarChar(100), `orphan-${randomUUID()}`)
          .input('name', sql.NVarChar(200), 'orphan campaign')
          .query('INSERT dbo.campaigns(campaign_id,tenant_id,campaign_key,name) VALUES(@campaignId,@tenantId,@key,@name)');
      } catch {
        foreignKeyRejected = true;
      }
    } finally {
      await rollbackQuietly(constraintTx);
    }
    expect(checkRejected).toBe(true);
    expect(foreignKeyRejected).toBe(true);
  });
});

async function rollbackQuietly(transaction: Transaction): Promise<void> {
  try {
    await transaction.rollback();
  } catch {
    // The transaction may already have been rolled back after a test assertion.
  }
}
