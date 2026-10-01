# MMA-CDR TOOL — SQL Server provisioner. MUST run as Administrator
# (right-click PowerShell -> Run as administrator).
# 1) Grants current Windows user sysadmin (single-user mode recovery).
# 2) Runs database/mma-cdr-sqlserver.sql -> creates CDR_Intelligence.
# 3) Creates SQL login cdr_app with least privilege + prints password.
$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Not elevated. Re-run this script as Administrator."
}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$schema = Join-Path $root "database\mma-cdr-sqlserver.sql"
if (-not (Test-Path $schema)) { throw "Schema not found: $schema" }
$winLogin = "$env:USERDOMAIN\$env:USERNAME"
$appPass = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
Write-Host "Step 1/4: stopping SQL Server ..." -ForegroundColor Yellow
net stop MSSQLSERVER | Out-Null
Write-Host "Step 2/4: single-user mode, provisioning [$winLogin] ..." -ForegroundColor Yellow
net start MSSQLSERVER /mSQLCMD | Out-Null
Start-Sleep -Seconds 5
sqlcmd -E -S localhost -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'$winLogin') CREATE LOGIN [$winLogin] FROM WINDOWS; ALTER SERVER ROLE sysadmin ADD MEMBER [$winLogin];"
Write-Host "Step 3/4: restart normally + run schema ..." -ForegroundColor Yellow
net stop MSSQLSERVER | Out-Null
net start MSSQLSERVER | Out-Null
Start-Sleep -Seconds 8
sqlcmd -E -S localhost -i $schema
Write-Host "Step 4/4: creating least-privilege cdr_app ..." -ForegroundColor Yellow
sqlcmd -E -S localhost -Q @"
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name=N'cdr_app') CREATE LOGIN [cdr_app] WITH PASSWORD=N'$appPass', CHECK_POLICY=ON;
USE [CDR_Intelligence];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'cdr_app') CREATE USER [cdr_app] FOR LOGIN [cdr_app];
ALTER ROLE [db_datareader] ADD MEMBER [cdr_app];
ALTER ROLE [db_datawriter] ADD MEMBER [cdr_app];
GRANT EXECUTE TO [cdr_app];
"@
Write-Host ""
Write-Host "DONE. CDR_Intelligence ready." -ForegroundColor Green
Write-Host "SQLSERVER_DRIVER=ODBC Driver 17 for SQL Server" -ForegroundColor Cyan
Write-Host "SQLSERVER_HOST=localhost  SQLSERVER_USER=cdr_app" -ForegroundColor Cyan
Write-Host "SQLSERVER_PASSWORD=$appPass" -ForegroundColor Red
Write-Host "Restart API with: `$env:MMA_CDR_USE_SQLITE='0'; `$env:SQLSERVER_DRIVER='ODBC Driver 17 for SQL Server'; `$env:SQLSERVER_USER='cdr_app'; `$env:SQLSERVER_PASSWORD='<above>'; python -m uvicorn api.app:app --host 127.0.0.1 --port 8100" -ForegroundColor Cyan
