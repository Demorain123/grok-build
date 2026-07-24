[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$PatchPath = Join-Path $SafeRoot 'patches\0001-disable-cloud-storage-uploads.patch'
$RunScript = Join-Path $ScriptDir 'run.ps1'
$PreflightScript = Join-Path $ScriptDir 'preflight.ps1'
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\grok-safe-guardrails.yml'

function Fail([string]$Message) {
    throw "grok-safe audit FAILED: $Message"
}

function Require-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { Fail $Message }
}

function Require-Regex([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { Fail $Message }
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail 'git is not available on PATH'
    }
    foreach ($path in @($PatchPath, $RunScript, $PreflightScript, $WorkflowPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "missing required safety file: $path" }
    }

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'repository root could not be verified' }

    $patchText = Get-Content -Raw -LiteralPath $PatchPath
    $runText = Get-Content -Raw -LiteralPath $RunScript
    $preflightText = Get-Content -Raw -LiteralPath $PreflightScript
    $workflowText = Get-Content -Raw -LiteralPath $WorkflowPath

    $cratesRoot = Join-Path $RepoRoot 'crates'
    $rustPaths = @(
        Get-ChildItem $cratesRoot -Recurse -File -Filter '*.rs' |
            ForEach-Object { $_.FullName }
    )
    if ($rustPaths.Count -eq 0) { Fail 'no Rust source files found under crates/' }

    Write-Host '[1/10] Checking hardening patch contexts apply cleanly...'
    # The patch is intentionally hand-maintained as a tiny replay layer. --recount
    # derives hunk lengths from the actual +/-/context lines while still requiring
    # those contexts to match the upstream source. This avoids bookkeeping-only
    # failures without masking real upstream code drift.
    & git apply --recount --check -- $PatchPath
    if ($LASTEXITCODE -ne 0) {
        Fail 'hardening patch contexts no longer apply cleanly; upstream security-sensitive code changed and needs review'
    }

    Write-Host '[2/10] Checking shared cloud-upload API surface...'
    $gcsPath = Join-Path $RepoRoot 'crates\codegen\xai-file-utils\src\gcs.rs'
    if (-not (Test-Path $gcsPath)) { Fail "missing expected file: $gcsPath" }
    $gcsText = Get-Content -Raw -LiteralPath $gcsPath
    $gcsMatches = [regex]::Matches($gcsText, 'pub\s+async\s+fn\s+(upload_[A-Za-z0-9_]+)')
    $actualGcs = @($gcsMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    # Four top-level dispatchers must fail before backend selection. Upstream also
    # exposes upload_bytes_via_signed_url directly; that helper is intentionally
    # covered by the patched StorageClient::with_provider loopback defense.
    $guardedDispatchers = @('upload_bytes', 'upload_bytes_signed', 'upload_file', 'upload_stream')
    $storageClientCoveredHelpers = @('upload_bytes_via_signed_url')
    $knownPublicUploadHelpers = @($guardedDispatchers + $storageClientCoveredHelpers | Sort-Object -Unique)

    $unexpectedGcs = @($actualGcs | Where-Object { $_ -notin $knownPublicUploadHelpers })
    if ($unexpectedGcs.Count -gt 0) {
        Fail ('new public cloud-upload helper(s) require review: ' + ($unexpectedGcs -join ', '))
    }
    foreach ($name in $knownPublicUploadHelpers) {
        if ($name -notin $actualGcs) {
            Fail "expected upload helper disappeared or was renamed: $name; review the upstream refactor before building"
        }
    }
    foreach ($name in $guardedDispatchers) {
        Require-Contains $patchText ('grok_safe_block_cloud_storage_upload("' + $name + '")') "patch has no fail-closed guard for $name"
    }
    Require-Contains $patchText 'grok-safe-storage-blocked' 'StorageClient loopback defense required by signed-url helper is missing'

    Write-Host '[3/10] Checking storage/backend bypasses with real file-content scanning...'
    # IMPORTANT: use -Path explicitly. Piping FileInfo objects to Select-String can
    # search their string representation instead of the file contents.
    $directS3 = @(
        Select-String -Path $rustPaths -Pattern '(^|[^A-Za-z0-9_])(crate::s3::upload_|xai_file_utils::s3::upload_)' |
            Where-Object { $_.Path -notlike '*\xai-file-utils\src\gcs.rs' }
    )
    if ($directS3.Count -gt 0) {
        $paths = $directS3 | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('direct S3 upload bypass found outside gcs.rs: ' + ($paths -join '; '))
    }

    $codeBackendHits = @(Select-String -Path $rustPaths -SimpleMatch 'https://code.grok.com')
    $unexpectedCodeBackend = @(
        $codeBackendHits |
            Where-Object { $_.Path -notlike '*\xai-grok-shell\src\remote\client.rs' }
    )
    if ($unexpectedCodeBackend.Count -gt 0) {
        $paths = $unexpectedCodeBackend | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('new direct code.grok.com reference outside remote/client.rs requires review: ' + ($paths -join '; '))
    }

    Write-Host '[4/10] Verifying remote-session writeback is fail-closed...'
    $remoteClientPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\remote\client.rs'
    $remoteSyncPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\remote\sync.rs'
    $agentInitPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\agent\init.rs'
    foreach ($path in @($remoteClientPath, $remoteSyncPath, $agentInitPath)) {
        if (-not (Test-Path $path)) { Fail "missing expected remote-sync source: $path" }
    }
    $remoteClientText = Get-Content -Raw -LiteralPath $remoteClientPath
    $remoteSyncText = Get-Content -Raw -LiteralPath $remoteSyncPath
    $agentInitText = Get-Content -Raw -LiteralPath $agentInitPath
    Require-Contains $remoteClientText 'https://code.grok.com' 'upstream code backend constant moved/changed; review remote egress path'
    Require-Contains $remoteSyncText 'save_session_data' 'RemoteSync implementation changed; review session writeback path'
    Require-Contains $agentInitText 'StorageMode::resolve' 'storage-mode resolution changed; review Writeback gating'
    foreach ($marker in @('GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC','grok-safe-remote-sync-blocked','forcing local session storage')) {
        Require-Contains $patchText $marker "remote-sync hardening marker missing: $marker"
    }

    Write-Host '[5/10] Verifying product telemetry, OTLP and feedback are fail-closed in the binary...'
    $telemetryClientPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\client.rs'
    $externalOtelPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\external\mod.rs'
    $internalOtelPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\otel_layer\mod.rs'
    $feedbackPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\extensions\feedback.rs'
    foreach ($path in @($telemetryClientPath, $externalOtelPath, $internalOtelPath, $feedbackPath)) {
        if (-not (Test-Path $path)) { Fail "missing expected auxiliary-egress source: $path" }
    }
    $telemetryClientText = Get-Content -Raw -LiteralPath $telemetryClientPath
    $externalOtelText = Get-Content -Raw -LiteralPath $externalOtelPath
    $internalOtelText = Get-Content -Raw -LiteralPath $internalOtelPath
    $feedbackText = Get-Content -Raw -LiteralPath $feedbackPath
    Require-Contains $telemetryClientText 'pub fn init(' 'telemetry client init moved/changed; review product telemetry sink'
    Require-Contains $telemetryClientText 'pub fn init_if_needed(' 'telemetry re-init moved/changed; review product telemetry sink'
    Require-Contains $externalOtelText 'pub fn init(cfg: Option<ExternalOtelConfig>)' 'external OTLP init moved/changed; review external exporter sink'
    Require-Contains $internalOtelText 'fn build_tracer_provider(' 'internal OTLP provider construction moved/changed; review internal exporter sink'
    Require-Contains $feedbackText 'async fn handle_feedback(' 'feedback handler moved/changed; review feedback egress sink'
    if ([regex]::Matches($patchText, [regex]::Escape('GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS')).Count -lt 4) {
        Fail 'auxiliary-egress binary guard is not present across all expected telemetry/feedback layers'
    }
    foreach ($marker in @('feedback network submission is disabled','grok_safe_aux_egress_allowed')) {
        Require-Contains $patchText $marker "auxiliary-egress hardening marker missing: $marker"
    }

    Write-Host '[6/10] Verifying in-app updater cannot replace the hardened binary...'
    $updaterPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-update\src\auto_update.rs'
    if (-not (Test-Path $updaterPath)) { Fail "missing updater source: $updaterPath" }
    $updaterText = Get-Content -Raw -LiteralPath $updaterPath
    Require-Contains $updaterText 'pub async fn get_installer()' 'updater installer resolution changed; review self-update path'
    Require-Contains $updaterText 'pub async fn run_install_script' 'updater install sink changed; review self-update path'
    Require-Contains $patchText 'GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE' 'self-update unsafe override guard is missing'
    Require-Contains $patchText 'in-app self-update is disabled' 'run_install_script fail-closed guard is missing'

    Write-Host '[7/10] Verifying launcher policy and inherited endpoint cleanup...'
    $launcherRequirements = @{
        'GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS' = '0'
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC' = '0'
        'GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE' = '0'
        'GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS' = '0'
        'GROK_STORAGE_MODE' = 'local'
        'GROK_TELEMETRY_ENABLED' = 'false'
        'GROK_TELEMETRY_TRACE_UPLOAD' = 'false'
        'GROK_TELEMETRY_MIXPANEL_ENABLED' = 'false'
        'GROK_FEEDBACK_ENABLED' = 'false'
        'GROK_EXTERNAL_OTEL' = '0'
        'OTEL_TRACES_EXPORTER' = 'none'
        'OTEL_SDK_DISABLED' = 'true'
    }
    foreach ($entry in $launcherRequirements.GetEnumerator()) {
        $escapedName = [regex]::Escape($entry.Key)
        $escapedValue = [regex]::Escape($entry.Value)
        Require-Regex $runText "(?m)^\s*\`$env:$escapedName\s*=\s*'$escapedValue'\s*$" "launcher does not force $($entry.Key)=$($entry.Value)"
    }
    foreach ($name in @(
        'GROK_INTERNAL_OTLP_TRACES_ENDPOINT','GROK_INTERNAL_OTLP_HEADERS',
        'GROK_TRACE_UPLOAD_URL','GROK_TRACE_UPLOAD_BUCKET','GROK_TRACE_UPLOAD_REGION',
        'GROK_TRACE_UPLOAD_CREDENTIALS_FILE','GROK_TRACE_UPLOAD_ENDPOINT_URL',
        'GROK_FEEDBACK_BASE_URL','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_HEADERS'
    )) {
        Require-Contains $runText ("'$name'") "launcher does not scrub inherited auxiliary endpoint/credential: $name"
    }

    Write-Host '[8/10] Verifying compatibility isolation and project extension preflight...'
    foreach ($name in @(
        'GROK_CLAUDE_SKILLS_ENABLED','GROK_CLAUDE_RULES_ENABLED','GROK_CLAUDE_AGENTS_ENABLED',
        'GROK_CLAUDE_MCPS_ENABLED','GROK_CLAUDE_HOOKS_ENABLED','GROK_CLAUDE_SESSIONS_ENABLED',
        'GROK_CURSOR_SKILLS_ENABLED','GROK_CURSOR_RULES_ENABLED','GROK_CURSOR_AGENTS_ENABLED',
        'GROK_CURSOR_MCPS_ENABLED','GROK_CURSOR_HOOKS_ENABLED','GROK_CURSOR_SESSIONS_ENABLED',
        'GROK_CODEX_SESSIONS_ENABLED'
    )) {
        Require-Contains $runText ("'$name'") "launcher does not disable compatibility cell by default: $name"
    }
    Require-Contains $runText 'AllowVendorCompatibility' 'launcher lacks explicit vendor-compatibility opt-in'
    Require-Contains $runText '& $Preflight' 'launcher does not execute project extension preflight'
    foreach ($marker in @('.grok\hooks','.grok\plugins','.mcp.json','.cursor\mcp.json','.claude\settings.json')) {
        Require-Contains $preflightText $marker "preflight is missing extension surface: $marker"
    }

    Write-Host '[9/10] Verifying CI guardrails compile the patched security boundary...'
    foreach ($needle in @(
        '.\grok-safe\scripts\audit.ps1',
        'git apply --recount --check -- grok-safe/patches/0001-disable-cloud-storage-uploads.patch',
        'cargo check -p xai-file-utils -p xai-grok-shell -p xai-grok-update -p xai-grok-telemetry',
        'cargo build -p xai-grok-pager-bin --release'
    )) {
        Require-Contains $workflowText $needle "CI guardrail is missing required step: $needle"
    }

    Write-Host '[10/10] Inventorying security-sensitive network/storage markers...'
    $riskPatterns = @(
        '/storage','storage.googleapis.com','https://code.grok.com','save_session_data',
        'repo_state.upload','upload_multipart','batch_upload','TraceExportConfig',
        'GROK_INTERNAL_OTLP_TRACES_ENDPOINT','GROK_TRACE_UPLOAD_BUCKET',
        'GROK_TELEMETRY_ENABLED','GROK_FEEDBACK_ENABLED','run_install_script'
    )
    foreach ($pattern in $riskPatterns) {
        $hits = @(Select-String -Path $rustPaths -SimpleMatch $pattern)
        Write-Host ("  {0,-36} {1,5} hit(s)" -f $pattern, $hits.Count)
    }
    foreach ($marker in @(
        'GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS','grok-safe-storage-blocked',
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC','grok-safe-remote-sync-blocked',
        'GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS','GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE'
    )) {
        Require-Contains $patchText $marker "hardening marker missing from patch: $marker"
    }

    Write-Host ''
    Write-Host 'grok-safe static audit PASSED.' -ForegroundColor Green
    Write-Host 'Known non-inference storage/session-sync/telemetry/update sinks are fail-closed and upgrade drift is checked.'
    Write-Host 'This does NOT prove that model inference contains no source code, nor does it sandbox explicitly trusted MCP/hooks/plugins/shell/web tools.' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
