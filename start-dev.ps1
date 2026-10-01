# MMA-CDR TOOL — one-click dev run (no admin required).
# Starts API :8100 (SQLite fallback) + Vite :5173, opens Chrome.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$env:MMA_CDR_USE_SQLITE = "1"
$env:VITE_API_URL = "http://localhost:8100"
Write-Host "Starting MMA-CDR API :8100 ..." -ForegroundColor Green
Start-Process python -ArgumentList "-m","uvicorn","api.app:app","--host","127.0.0.1","--port","8100" -WorkingDirectory $root
Write-Host "Starting Vite :5173 ..." -ForegroundColor Green
$env:VITE_API_URL = "http://localhost:8100"
Start-Process powershell -ArgumentList "-NoExit","-Command","`$env:VITE_API_URL='http://localhost:8100'; npx vite --host localhost --port 5173" -WorkingDirectory $root
Start-Sleep -Seconds 8
Write-Host "API:     http://127.0.0.1:8100/health  + /docs" -ForegroundColor Cyan
Write-Host "Frontend: http://localhost:5173" -ForegroundColor Cyan
Start-Process chrome.exe "http://localhost:5173"
