[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$PatchDir = Join-Path $SafeRoot 'patches'
$RunScript = Join-Path $ScriptDir 'run.ps1'
$PreflightScript = Join-Path $ScriptDir 'preflight.ps1'
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\grok-safe-guardrails.yml'

function Fail([string]$Message) {
    throw "grok-safe audit FAILED: $Message"
}

function Require-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { Fail $Message }
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail 'git is not available on PATH'
    }
    foreach ($path in @($RunScript, $PreflightScript, $WorkflowPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "missing required safety file: $path" }
    }

    $PatchFiles = @(
        Get-ChildItem -LiteralPath $PatchDir -File -Filter '*.patch' -ErrorAction Stop |
            Sort-Object Name
    )
    if ($PatchFiles.Count -eq 0) { Fail "no hardening patches found under: $PatchDir" }
    $patchText = (($PatchFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n")

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'repository root could not be verified' }

    $runText = Get-Content -Raw -LiteralPath $RunScript
    $preflightText = Get-Content -Raw -LiteralPath $PreflightScript
    $workflowText = Get-Content -Raw -LiteralPath $WorkflowPath

    $cratesRoot = Join-Path $RepoRoot 'crates'
    $rustPaths = @(
        Get-ChildItem $cratesRoot -Recurse -File -Filter '*.rs' |
            ForEach-Object { $_.FullName }
    )
    if ($rustPaths.Count -eq 0) { Fail 'no Rust source files found under crates/' }

    Write-Host '[1/10] Checking ordered hardening patch contexts apply cleanly...'
    foreach ($patch in $PatchFiles) {
        Write-Host ("  checking {0}" -f $patch.Name)
        & git apply --recount --check -- $patch.FullName
        if ($LASTEXITCODE -ne 0) {
            Fail "hardening patch no longer applies cleanly: $($patch.Name); upstream security-sensitive code changed and needs review"
        }
    }

    Write-Host '[2/10] Checking shared cloud-upload API surface...'
    $gcsPath = Join-Path $RepoRoot 'crates\codegen\xai-file-utils\src\gcs.rs'
    if (-not (Test-Path $gcsPath)) { Fail "missing expected file: $gcsPath" }
    $gcsText = Get-Content -Raw -LiteralPath $gcsPath
    $gcsMatches = [regex]::Matches($gcsText, 'pub\s+async\s+fn\s+(upload_[A-Za-z0-9_]+)')
    $actualGcs = @($gcsMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

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
        Require-Contains $patchText ('grok_safe_block_cloud_storage_upload("' + $name + '")') "patch set has no fail-closed guard for $name"
    }
    Require-Contains $patchText 'grok-safe-storage-blocked' 'StorageClient loopback defense required by signed-url helper is missing'

    Write-Host '[3/10] Checking storage/backend bypasses and cloud SDK placement...'
    $directS3 = @(
        Select-String -Path $rustPaths -Pattern '(^|[^A-Za-z0-9_])(crate::s3::upload_|xai_file_utils::s3::upload_)' |
            Where-Object { $_.Path -notlike '*\xai-file-utils\src\gcs.rs' }
    )
    if ($directS3.Count -gt 0) {
        $paths = $directS3 | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('direct S3 upload bypass found outside gcs.rs: ' + ($paths -join '; '))
    }

    $awsSdkHits = @(Select-String -Path $rustPaths -SimpleMatch 'aws_sdk_s3')
    $unexpectedAwsSdk = @($awsSdkHits | Where-Object { $_.Path -notlike '*\xai-file-utils\src\s3.rs' })
    if ($unexpectedAwsSdk.Count -gt 0) {
        $paths = $unexpectedAwsSdk | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('AWS S3 SDK appeared outside the reviewed xai-file-utils/s3.rs boundary: ' + ($paths -join '; '))
    }

    $gcsSdkHits = @(Select-String -Path $rustPaths -SimpleMatch 'gcloud_storage')
    $unexpectedGcsSdk = @($gcsSdkHits | Where-Object { $_.Path -notlike '*\xai-file-utils\src\gcs.rs' })
    if ($unexpectedGcsSdk.Count -gt 0) {
        $paths = $unexpectedGcsSdk | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('GCS SDK appeared outside the reviewed xai-file-utils/gcs.rs boundary: ' + ($paths -join '; '))
    }

    $multipartHits = @(Select-String -Path $rustPaths -SimpleMatch 'reqwest::multipart')
    $unexpectedMultipart = @($multipartHits | Where-Object { $_.Path -notlike '*\xai-file-utils\src\storage_client.rs' })
    if ($unexpectedMultipart.Count -gt 0) {
        $paths = $unexpectedMultipart | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('reqwest multipart upload surface appeared outside StorageClient: ' + ($paths -join '; '))
    }

    $codeBackendHits = @(Select-String -Path $rustPaths -SimpleMatch 'https://code.grok.com')
    $unexpectedCodeBackend = @($codeBackendHits | Where-Object { $_.Path -notlike '*\xai-grok-shell\src\remote\client.rs' })
    if ($unexpectedCodeBackend.Count -gt 0) {
        $paths = $unexpectedCodeBackend | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('new direct code.grok.com reference outside remote/client.rs requires review: ' + ($paths -join '; '))
    }

    Write-Host '[4/10] Verifying remote session sync and registry replication are fail-closed...'
    $remoteClientPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\remote\client.rs'
    $remoteSyncPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\remote\sync.rs'
    $agentInitPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\agent\init.rs'
    $sessionRegistryPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\agent\session_registry_client.rs'
    foreach ($path in @($remoteClientPath, $remoteSyncPath, $agentInitPath, $sessionRegistryPath)) {
        if (-not (Test-Path $path)) { Fail "missing expected remote-sync source: $path" }
    }
    $remoteClientText = Get-Content -Raw -LiteralPath $remoteClientPath
    $remoteSyncText = Get-Content -Raw -LiteralPath $remoteSyncPath
    $agentInitText = Get-Content -Raw -LiteralPath $agentInitPath
    $sessionRegistryText = Get-Content -Raw -LiteralPath $sessionRegistryPath
    Require-Contains $remoteClientText 'https://code.grok.com' 'upstream code backend constant moved/changed; review remote egress path'
    Require-Contains $remoteSyncText 'save_session_data' 'RemoteSync implementation changed; review session writeback path'
    Require-Contains $agentInitText 'StorageMode::resolve' 'storage-mode resolution changed; review Writeback gating'
    Require-Contains $sessionRegistryText 'async fn send_authed' 'SessionRegistryClient network sink moved/changed; review cross-host replication'
    Require-Contains $sessionRegistryText '/sessions/register' 'SessionRegistry register endpoint moved/changed; review replication metadata'
    Require-Contains $sessionRegistryText '/replicas/update' 'SessionRegistry update endpoint moved/changed; review summary/first_prompt replication'
    Require-Contains $sessionRegistryText '/replicas/finalize' 'SessionRegistry finalize endpoint moved/changed; review replication metadata'
    foreach ($marker in @(
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC',
        'grok-safe-remote-sync-blocked',
        'forcing local session storage',
        'blocked session-registry remote replication request'
    )) {
        Require-Contains $patchText $marker "remote-sync hardening marker missing: $marker"
    }

    Write-Host '[5/10] Verifying telemetry, analytics, feedback and embedding egress is fail-closed...'
    $telemetryClientPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\client.rs'
    $externalOtelPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\external\mod.rs'
    $internalOtelPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-telemetry\src\otel_layer\mod.rs'
    $feedbackExtensionPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\extensions\feedback.rs'
    $feedbackClientPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-shell\src\agent\feedback_client.rs'
    $memoryEmbeddingPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-memory\src\embedding.rs'
    foreach ($path in @($telemetryClientPath, $externalOtelPath, $internalOtelPath, $feedbackExtensionPath, $feedbackClientPath, $memoryEmbeddingPath)) {
        if (-not (Test-Path $path)) { Fail "missing expected auxiliary-egress source: $path" }
    }
    $telemetryClientText = Get-Content -Raw -LiteralPath $telemetryClientPath
    $externalOtelText = Get-Content -Raw -LiteralPath $externalOtelPath
    $internalOtelText = Get-Content -Raw -LiteralPath $internalOtelPath
    $feedbackExtensionText = Get-Content -Raw -LiteralPath $feedbackExtensionPath
    $feedbackClientText = Get-Content -Raw -LiteralPath $feedbackClientPath
    $memoryEmbeddingText = Get-Content -Raw -LiteralPath $memoryEmbeddingPath
    Require-Contains $telemetryClientText 'pub fn init(' 'telemetry client init moved/changed; review product telemetry sink'
    Require-Contains $telemetryClientText 'pub fn init_if_needed(' 'telemetry re-init moved/changed; review product telemetry sink'
    Require-Contains $externalOtelText 'pub fn init(cfg: Option<ExternalOtelConfig>)' 'external OTLP init moved/changed; review external exporter sink'
    Require-Contains $internalOtelText 'fn build_tracer_provider(' 'internal OTLP provider construction moved/changed; review internal exporter sink'
    Require-Contains $feedbackExtensionText 'async fn handle_feedback(' 'feedback extension moved/changed; review feedback egress sink'
    Require-Contains $feedbackClientText 'async fn send_json<T: DeserializeOwned>' 'FeedbackClient JSON send sink moved/changed; review session analytics egress'
    Require-Contains $feedbackClientText 'async fn send_empty' 'FeedbackClient empty send sink moved/changed; review session analytics egress'
    Require-Contains $feedbackClientText 'send_turn_delta' 'per-turn analytics path moved/changed; review session analytics egress'
    Require-Contains $memoryEmbeddingText 'impl EmbeddingProvider for ApiEmbeddingProvider' 'remote memory embedding provider moved/changed; review text egress'
    Require-Contains $memoryEmbeddingText 'async fn embed_batch' 'memory embedding network sink moved/changed; review text egress'
    foreach ($marker in @(
        'feedback network submission is disabled',
        'blocked feedback/session-signals auxiliary request',
        'blocked remote memory embedding text egress',
        'grok_safe_aux_egress_allowed'
    )) {
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

    Write-Host '[7/10] Verifying launcher protects Grok-owned auxiliary egress without poisoning child-tool OTEL...'
    $launcherRequirements = [ordered]@{
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
    }
    foreach ($entry in $launcherRequirements.GetEnumerator()) {
        $expectedLine = '$env:' + $entry.Key + " = '" + $entry.Value + "'"
        Require-Contains $runText $expectedLine "launcher does not force $($entry.Key)=$($entry.Value)"
    }
    foreach ($name in @(
        'GROK_INTERNAL_OTLP_TRACES_ENDPOINT','GROK_INTERNAL_OTLP_HEADERS',
        'GROK_TRACE_UPLOAD_URL','GROK_TRACE_UPLOAD_BUCKET','GROK_TRACE_UPLOAD_REGION',
        'GROK_TRACE_UPLOAD_CREDENTIALS_FILE','GROK_TRACE_UPLOAD_ENDPOINT_URL',
        'GROK_FEEDBACK_BASE_URL'
    )) {
        Require-Contains $runText ("'$name'") "launcher does not scrub inherited Grok-owned auxiliary endpoint/credential: $name"
    }
    foreach ($forbidden in @('OTEL_SDK_DISABLED','OTEL_TRACES_EXPORTER','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_HEADERS')) {
        if ($runText -match ('(?m)^\s*\$env:' + [regex]::Escape($forbidden) + '\s*=') -or
            $runText -match ("(?m)^\s*'" + [regex]::Escape($forbidden) + "'\s*,?\s*$")) {
            Fail "launcher globally mutates generic $forbidden; this can break explicitly configured MCP/hooks/shell child processes"
        }
    }

    Write-Host '[8/10] Verifying normal MCP/extensions are retained by default and strict isolation is opt-in...'
    Require-Contains $runText 'StrictExtensionIsolation' 'launcher lacks optional strict extension-isolation mode'
    Require-Contains $runText 'Native MCP/hooks/plugins: UPSTREAM BEHAVIOR RETAINED' 'launcher no longer documents normal extension behavior as retained'
    Require-Contains $runText "Join-Path `$HOME '.grok'" 'launcher does not keep the official Grok user home in normal mode'
    Require-Contains $runText 'IsolatedHome' 'launcher lacks explicit isolated-home opt-in'
    Require-Contains $runText '& $Preflight' 'launcher does not execute project extension preflight'
    foreach ($marker in @('.grok\hooks','.grok\plugins','.mcp.json','.cursor\mcp.json','.claude\settings.json')) {
        Require-Contains $preflightText $marker "preflight is missing extension surface: $marker"
    }
    Require-Contains $preflightText 'warning-only by default' 'preflight no longer treats explicit MCP configuration as non-blocking by default'

    Write-Host '[9/10] Verifying CI guardrails compile the patched security boundary...'
    foreach ($needle in @(
        '.\grok-safe\scripts\audit.ps1',
        '0002-block-feedback-session-signals.patch',
        '0003-block-session-registry-replication.patch',
        '0004-block-remote-memory-embeddings.patch',
        'cargo check -p xai-file-utils',
        'cargo check -p xai-grok-memory',
        'cargo check -p xai-grok-telemetry',
        'cargo check -p xai-grok-shell',
        'cargo check -p xai-grok-update',
        'cargo build -p xai-grok-pager-bin --release'
    )) {
        Require-Contains $workflowText $needle "CI guardrail is missing required step: $needle"
    }

    Write-Host '[10/10] Inventorying security-sensitive network/storage markers...'
    $riskPatterns = @(
        '/storage','storage.googleapis.com','https://code.grok.com','save_session_data',
        '/sessions/register','/replicas/update','/replicas/finalize',
        'turn-deltas','/signals','/embeddings','repo_state.upload','upload_multipart','batch_upload','TraceExportConfig',
        'aws_sdk_s3','gcloud_storage','reqwest::multipart',
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
        Require-Contains $patchText $marker "hardening marker missing from patch set: $marker"
    }

    Write-Host ''
    Write-Host 'grok-safe static audit PASSED.' -ForegroundColor Green
    Write-Host 'Known Grok-owned non-inference storage/session-sync/session-registry/telemetry/analytics/embedding/update sinks are fail-closed and upgrade drift is checked.'
    Write-Host 'Normal MCP/hooks/plugins remain available by default; explicitly configured tools may have their own network access by design.' -ForegroundColor Yellow
    Write-Host 'This does NOT prove that model inference contains no source code.' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
