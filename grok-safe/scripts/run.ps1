[CmdletBinding()]
param(
    [switch]$UseOfficialHome,
    [switch]$AllowProjectExtensions,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GrokArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$Binary = Join-Path $SafeRoot 'dist\grok-safe.exe'
$Preflight = Join-Path $ScriptDir 'preflight.ps1'

if (-not (Test-Path $Binary)) {
    throw "grok-safe.exe was not found. Build it first with: .\grok-safe\scripts\build.ps1"
}
if (-not (Test-Path $Preflight)) {
    throw "grok-safe preflight script was not found: $Preflight"
}

# ---------------------------------------------------------------------------
# Fail-closed local policy. These are intentionally set (not merely cleared)
# so an unsafe value inherited from the parent shell cannot weaken grok-safe.
# The Rust patch independently enforces the first three even when the binary is
# launched without this wrapper.
# ---------------------------------------------------------------------------
$env:GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS = '0'
$env:GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC = '0'
$env:GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE = '0'

# Keep session persistence local even if xAI remote settings or an existing
# user config would otherwise select Writeback.
$env:GROK_STORAGE_MODE = 'local'
$env:GROK_CODE_BACKEND_URL = 'http://127.0.0.1:9/grok-safe-remote-sync-blocked'

# Disable SpaceXAI product telemetry, trace uploads, feedback forwarding, and
# external OTLP. Normal model inference is unaffected by these switches.
$env:GROK_TELEMETRY_ENABLED = 'false'
$env:GROK_TELEMETRY_TRACE_UPLOAD = 'false'
$env:GROK_TELEMETRY_MIXPANEL_ENABLED = 'false'
$env:GROK_FEEDBACK_ENABLED = 'false'
$env:GROK_EXTERNAL_OTEL = '0'
$env:OTEL_SDK_DISABLED = 'true'

# Remove inherited destinations/credentials/content gates for external OTLP
# and legacy telemetry upload settings. Do not clear HTTP(S)_PROXY because the
# inference/auth path may legitimately require the user's proxy.
foreach ($name in @(
    'OTEL_EXPORTER_OTLP_ENDPOINT',
    'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT',
    'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT',
    'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT',
    'OTEL_EXPORTER_OTLP_HEADERS',
    'OTEL_EXPORTER_OTLP_LOGS_HEADERS',
    'OTEL_EXPORTER_OTLP_METRICS_HEADERS',
    'OTEL_LOG_USER_PROMPTS',
    'OTEL_LOG_TOOL_DETAILS',
    'GROK_TELEMETRY_GCS_BUCKET',
    'GROK_TELEMETRY_EVENTS_URL',
    'GROK_TELEMETRY_EVENTS_API_KEY',
    'GROK_TELEMETRY_MIXPANEL_TOKEN'
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

# Allow callers to use the common `--` separator without forwarding it to Grok.
if ($GrokArgs.Count -gt 0 -and $GrokArgs[0] -eq '--') {
    $GrokArgs = @($GrokArgs | Select-Object -Skip 1)
}

# CLI-supplied plugin roots bypass project directory discovery, so treat them
# like other project extension surfaces and require the same explicit override.
$hasPluginDir = @($GrokArgs | Where-Object { $_ -eq '--plugin-dir' -or $_ -like '--plugin-dir=*' }).Count -gt 0
if ($hasPluginDir -and -not $AllowProjectExtensions) {
    throw 'grok-safe blocked --plugin-dir. Rerun with -AllowProjectExtensions only after reviewing that plugin source.'
}

Write-Host 'Running project extension preflight...'
if ($AllowProjectExtensions) {
    & $Preflight -ProjectPath (Get-Location).Path -AllowProjectExtensions
} else {
    & $Preflight -ProjectPath (Get-Location).Path
}
if ($LASTEXITCODE -ne 0) { throw 'grok-safe project preflight failed' }

$effectiveHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $HOME '.grok' }

Write-Host ''
Write-Host 'grok-safe privacy guard: ON' -ForegroundColor Green
Write-Host 'Cloud/session artifact uploads: BLOCKED'
Write-Host 'Remote session writeback/share backend: BLOCKED'
Write-Host 'In-app self-update: BLOCKED (sync + rebuild instead)'
Write-Host 'Product telemetry / trace upload / feedback / external OTLP: OFF'
Write-Host "GROK_HOME: $effectiveHome"
Write-Host ''
Write-Host 'Boundary: source text intentionally included in model inference can still leave the machine.' -ForegroundColor Yellow
Write-Host 'Boundary: explicitly trusted MCP/hooks/plugins/shell/web tools may have their own network access.' -ForegroundColor Yellow
Write-Host ''

& $Binary @GrokArgs
exit $LASTEXITCODE
