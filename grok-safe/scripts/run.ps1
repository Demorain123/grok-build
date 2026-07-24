[CmdletBinding()]
param(
    [switch]$UseOfficialHome,
    [switch]$IsolatedHome,
    [switch]$StrictExtensionIsolation,
    [switch]$AllowProjectExtensions,
    [switch]$AllowVendorCompatibility,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GrokArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$Binary = Join-Path $SafeRoot 'dist\grok-safe.exe'
$HashFile = Join-Path $SafeRoot 'dist\grok-safe.exe.sha256'
$BuildInfoFile = Join-Path $SafeRoot 'dist\BUILD_INFO.json'
$Preflight = Join-Path $ScriptDir 'preflight.ps1'

if ($UseOfficialHome -and $IsolatedHome) {
    throw 'Choose either -UseOfficialHome or -IsolatedHome, not both.'
}
if (-not (Test-Path $Binary -PathType Leaf)) {
    throw "grok-safe.exe was not found. Build it first with: .\grok-safe\scripts\build.ps1"
}
if (-not (Test-Path $HashFile -PathType Leaf)) {
    throw "grok-safe integrity manifest was not found: $HashFile. Rebuild with build.ps1 instead of running an untracked binary."
}
if (-not (Test-Path $BuildInfoFile -PathType Leaf)) {
    throw "grok-safe BUILD_INFO.json was not found: $BuildInfoFile. Rebuild with build.ps1."
}
if (-not (Test-Path $Preflight -PathType Leaf)) {
    throw "grok-safe preflight script was not found: $Preflight"
}

# Fail closed on accidental/stale binary replacement. This is an integrity
# consistency check, not a signature against an attacker who can rewrite both
# the binary and its local manifests.
$hashManifest = (Get-Content -Raw -LiteralPath $HashFile).Trim()
$expectedHash = ($hashManifest -split '\s+')[0].ToLowerInvariant()
if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid grok-safe SHA256 manifest: $HashFile"
}
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Binary).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "grok-safe.exe SHA256 mismatch. Expected $expectedHash but found $actualHash. Refusing to launch; rebuild from the reviewed safety branch."
}
$buildInfo = Get-Content -Raw -LiteralPath $BuildInfoFile | ConvertFrom-Json
if (-not $buildInfo.binary_sha256 -or $buildInfo.binary_sha256.ToString().ToLowerInvariant() -ne $actualHash) {
    throw 'BUILD_INFO.json binary_sha256 does not match grok-safe.exe. Refusing to launch.'
}

# Fail-closed local policy for Grok-owned non-inference egress. These are set
# explicitly so inherited environment values cannot weaken the reviewed wrapper.
$env:GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS = '0'
$env:GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC = '0'
$env:GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE = '0'
$env:GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS = '0'

# Keep automatic session persistence local even if xAI remote settings or an
# existing user config would otherwise select Writeback. Explicit user-initiated
# remote read/restore/share operations keep their upstream backend behavior.
$env:GROK_STORAGE_MODE = 'local'

# Disable Grok-owned product telemetry, trace uploads, feedback analytics, and
# Grok's external OTLP configuration. The Rust patch independently disables both
# internal and external OTLP exporters. We intentionally do NOT mutate generic
# OTEL_* environment variables because explicit MCP/hooks/shell child processes
# may legitimately depend on the user's OpenTelemetry environment.
$env:GROK_TELEMETRY_ENABLED = 'false'
$env:GROK_TELEMETRY_TRACE_UPLOAD = 'false'
$env:GROK_TELEMETRY_MIXPANEL_ENABLED = 'false'
$env:GROK_FEEDBACK_ENABLED = 'false'
$env:GROK_EXTERNAL_OTEL = '0'

# Preserve normal Grok extension behavior by default. This includes native MCP
# and upstream Claude/Cursor compatibility discovery. Users who explicitly want
# a reduced extension surface for a sensitive run can opt into strict isolation.
if ($StrictExtensionIsolation -and -not $AllowVendorCompatibility) {
    foreach ($name in @(
        'GROK_CLAUDE_SKILLS_ENABLED',
        'GROK_CLAUDE_RULES_ENABLED',
        'GROK_CLAUDE_AGENTS_ENABLED',
        'GROK_CLAUDE_MCPS_ENABLED',
        'GROK_CLAUDE_HOOKS_ENABLED',
        'GROK_CLAUDE_SESSIONS_ENABLED',
        'GROK_CURSOR_SKILLS_ENABLED',
        'GROK_CURSOR_RULES_ENABLED',
        'GROK_CURSOR_AGENTS_ENABLED',
        'GROK_CURSOR_MCPS_ENABLED',
        'GROK_CURSOR_HOOKS_ENABLED',
        'GROK_CURSOR_SESSIONS_ENABLED',
        'GROK_CODEX_SESSIONS_ENABLED'
    )) {
        Set-Item -Path "Env:$name" -Value 'false'
    }
}

# Remove inherited destinations/credentials for known Grok-owned auxiliary
# paths only. Do not clear HTTP(S)_PROXY or generic OTEL_* variables: inference,
# auth and explicitly configured MCP/tools may legitimately use them.
foreach ($name in @(
    'GROK_INTERNAL_OTLP_TRACES_ENDPOINT',
    'GROK_INTERNAL_OTLP_HEADERS',
    'GROK_TRACE_UPLOAD_URL',
    'GROK_TRACE_UPLOAD_BUCKET',
    'GROK_TRACE_UPLOAD_REGION',
    'GROK_TRACE_UPLOAD_CREDENTIALS_FILE',
    'GROK_TRACE_UPLOAD_CREDENTIALS',
    'GROK_TRACE_UPLOAD_ENDPOINT_URL',
    'GROK_FEEDBACK_BASE_URL',
    'GROK_TELEMETRY_GCS_BUCKET',
    'GROK_TELEMETRY_EVENTS_URL',
    'GROK_TELEMETRY_EVENTS_API_KEY',
    'GROK_TELEMETRY_MIXPANEL_TOKEN'
)) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

# Normal mode deliberately keeps the same user home as official Grok so user
# MCPs, model config, credentials, plugins and preferences continue to work.
# -IsolatedHome is an opt-in mode for testing/sensitive repos. -UseOfficialHome
# remains accepted as an explicit/documenting no-op for older instructions.
if ($IsolatedHome) {
    if ($env:GROK_SAFE_HOME) {
        $env:GROK_HOME = $env:GROK_SAFE_HOME
    } else {
        $env:GROK_HOME = Join-Path $HOME '.grok-safe'
    }
    New-Item -ItemType Directory -Force -Path $env:GROK_HOME | Out-Null
} else {
    $env:GROK_HOME = Join-Path $HOME '.grok'
}

# Allow callers to use the common `--` separator without forwarding it to Grok.
if ($GrokArgs.Count -gt 0 -and $GrokArgs[0] -eq '--') {
    $GrokArgs = @($GrokArgs | Select-Object -Skip 1)
}

# CLI-supplied plugin roots are explicit user intent. Preserve them by default;
# strict extension isolation can require a second explicit acknowledgement.
$hasPluginDir = @($GrokArgs | Where-Object { $_ -eq '--plugin-dir' -or $_ -like '--plugin-dir=*' }).Count -gt 0
if ($hasPluginDir -and $StrictExtensionIsolation -and -not $AllowProjectExtensions) {
    throw 'Strict extension isolation blocked --plugin-dir. Rerun with -AllowProjectExtensions only after reviewing that plugin source.'
}

Write-Host 'Running project extension preflight...'
$preflightArgs = @{
    ProjectPath = (Get-Location).Path
}
if ($StrictExtensionIsolation) { $preflightArgs['StrictExtensionIsolation'] = $true }
if ($AllowProjectExtensions) { $preflightArgs['AllowProjectExtensions'] = $true }
& $Preflight @preflightArgs

$effectiveHome = $env:GROK_HOME

Write-Host ''
Write-Host 'grok-safe privacy guard: ON' -ForegroundColor Green
Write-Host "Binary integrity: VERIFIED ($actualHash)" -ForegroundColor Green
Write-Host 'Cloud/session artifact uploads: BLOCKED'
Write-Host 'Automatic remote session writeback: BLOCKED; explicit remote read/share retained'
Write-Host 'In-app self-update: BLOCKED (sync + rebuild instead)'
Write-Host 'Product telemetry / Grok OTLP / feedback analytics: BLOCKED'
Write-Host 'Native MCP/hooks/plugins: UPSTREAM BEHAVIOR RETAINED'
Write-Host ("Vendor compatibility discovery: {0}" -f $(if ($StrictExtensionIsolation -and -not $AllowVendorCompatibility) { 'BLOCKED FOR THIS STRICT RUN' } else { 'UPSTREAM BEHAVIOR RETAINED' }))
Write-Host "GROK_HOME: $effectiveHome"
Write-Host ''
Write-Host 'Boundary: source text intentionally included in model inference can still leave the machine.' -ForegroundColor Yellow
Write-Host 'Boundary: explicitly configured MCP/hooks/plugins/shell/web/share tools may have their own network access by design.' -ForegroundColor Yellow
Write-Host ''

& $Binary @GrokArgs
exit $LASTEXITCODE
