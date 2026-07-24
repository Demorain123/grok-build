[CmdletBinding()]
param(
    [switch]$UseOfficialHome,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GrokArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$Binary = Join-Path $SafeRoot 'dist\grok-safe.exe'

if (-not (Test-Path $Binary)) {
    throw "grok-safe.exe was not found. Build it first with: .\grok-safe\scripts\build.ps1"
}

# Safe mode is fail-closed in the patch. Force the unsafe escape hatch off even
# if the parent shell happened to define it.
$env:GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS = '0'

# Do not inherit user-configured external OTLP exporters into the hardened run.
$env:OTEL_SDK_DISABLED = 'true'
foreach ($name in @(
    'OTEL_EXPORTER_OTLP_ENDPOINT',
    'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT',
    'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT',
    'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT',
    'GROK_TELEMETRY_GCS_BUCKET'
)) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

if (-not $UseOfficialHome) {
    if ($env:GROK_SAFE_HOME) {
        $env:GROK_HOME = $env:GROK_SAFE_HOME
    } else {
        $env:GROK_HOME = Join-Path $HOME '.grok-safe'
    }
    New-Item -ItemType Directory -Force -Path $env:GROK_HOME | Out-Null
}

Write-Host 'grok-safe privacy guard: ON' -ForegroundColor Green
Write-Host 'Non-inference cloud-storage uploads: BLOCKED'
Write-Host "GROK_HOME: $env:GROK_HOME"
Write-Host ''

# Allow callers to use the common `--` separator without forwarding it to Grok.
if ($GrokArgs.Count -gt 0 -and $GrokArgs[0] -eq '--') {
    $GrokArgs = @($GrokArgs | Select-Object -Skip 1)
}

& $Binary @GrokArgs
exit $LASTEXITCODE
