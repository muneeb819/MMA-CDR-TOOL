[CmdletBinding()]
param(
    [switch]$SkipDependencyInstall,
    [switch]$SkipBrowserInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = [System.Collections.Generic.List[string]]::new()
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Invoke-RequiredCommand {
    param([string]$Name, [string]$Command, [string[]]$Arguments)

    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    & $Command @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $script:Failures.Add("$Name (exit $code)")
        Write-Host "$Name failed with exit code $code" -ForegroundColor Red
        return $false
    }
    Write-Host "$Name passed" -ForegroundColor Green
    return $true
}

function Stop-OnFailure {
    param([bool]$Succeeded, [string]$Step)
    if (-not $Succeeded) {
        Write-Error "Mandatory setup step failed: $Step"
        exit 1
    }
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error 'Node.js/npm is required.'
    exit 1
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error 'Python is required for the FastAPI backend.'
    exit 1
}

if (-not $SkipDependencyInstall) {
    Stop-OnFailure (Invoke-RequiredCommand 'Install Node dependencies' 'npm' @('ci')) 'npm ci'
    if (-not (Test-Path '.venv/Scripts/python.exe')) {
        Stop-OnFailure (Invoke-RequiredCommand 'Create Python virtual environment' 'python' @('-m', 'venv', '.venv')) 'python -m venv .venv'
    }
    $Python = (Resolve-Path '.venv/Scripts/python.exe').Path
    Stop-OnFailure (Invoke-RequiredCommand 'Install API dependencies' $Python @('-m', 'pip', 'install', '-r', 'api/requirements.txt')) 'pip install -r api/requirements.txt'
} else {
    $Python = if (Test-Path '.venv/Scripts/python.exe') { Resolve-Path '.venv/Scripts/python.exe' } else { (Get-Command python).Source }
}

if (-not $env:BASE_URL) { $env:BASE_URL = 'http://127.0.0.1:5173' }
if (-not $env:API_URL) { $env:API_URL = 'http://127.0.0.1:8000' }
if (-not $env:TEST_TENANT_ID) { $env:TEST_TENANT_ID = '00000000-0000-0000-0000-000000000001' }
if (-not $env:TEST_CAMPAIGN_ID) { $env:TEST_CAMPAIGN_ID = '22222222-2222-4222-8222-222222222222' }
if (-not $env:MAX_UPLOAD_MB) { $env:MAX_UPLOAD_MB = '8' }
$env:PYTHON = $Python

Write-Host "Using frontend $($env:BASE_URL) and API $($env:API_URL)."
if ($env:RUN_SQLSERVER_TESTS -eq '1') {
    Write-Host 'SQL Server integration is opted in; database must be explicitly named *_test or *_qa.' -ForegroundColor Yellow
} else {
    Write-Host 'SQL Server integration is unavailable/not opted in; database integration cases will report as skipped.' -ForegroundColor Yellow
}

if (-not $SkipBrowserInstall) {
    Stop-OnFailure (Invoke-RequiredCommand 'Install Playwright Chromium' 'npx' @('playwright', 'install', 'chromium')) 'npx playwright install chromium'
}

Stop-OnFailure (Invoke-RequiredCommand 'Frontend production build' 'npm' @('run', 'build')) 'npm run build'
$null = Invoke-RequiredCommand 'Playwright TypeScript type check' 'npm' @('run', 'test:types')

# Run focused suites as separate CI/local gates, then the complete suite so the
# final JSON/JUnit/HTML and qa-summary.md describe the complete regression run.
$Suites = @(
    @{ Name = 'Smoke'; Script = 'test:smoke' },
    @{ Name = 'API'; Script = 'test:api' },
    @{ Name = 'Refinery'; Script = 'test:refinery' },
    @{ Name = 'E2E'; Script = 'test:e2e' },
    @{ Name = 'Database'; Script = 'test:db' },
    @{ Name = 'Security'; Script = 'test:security' },
    @{ Name = 'Performance and concurrency'; Script = 'test:performance' },
    @{ Name = 'Regression'; Script = 'test:regression' },
    @{ Name = 'All tests'; Script = 'test:all' }
)
foreach ($suite in $Suites) {
    $null = Invoke-RequiredCommand $suite.Name 'npm' @('run', $suite.Script)
}

$summaryPath = Join-Path $Root 'test-results/qa-summary.md'
if (Test-Path $summaryPath) {
    Write-Host "`nFinal QA summary: $summaryPath" -ForegroundColor Cyan
    Get-Content $summaryPath
} else {
    Write-Host 'QA summary was not generated; inspect Playwright reporter output.' -ForegroundColor Yellow
}

if ($script:Failures.Count -gt 0) {
    Write-Host "`nFAILED STEPS:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll requested QA steps succeeded." -ForegroundColor Green
exit 0
