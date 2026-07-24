[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$PatchPath = Join-Path $SafeRoot 'patches\0001-disable-cloud-storage-uploads.patch'
$RunScript = Join-Path $ScriptDir 'run.ps1'

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
    if (-not (Test-Path $PatchPath)) { Fail "missing patch: $PatchPath" }
    if (-not (Test-Path $RunScript)) { Fail "missing launcher: $RunScript" }

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'repository root could not be verified' }

    $patchText = Get-Content -Raw -LiteralPath $PatchPath
    $runText = Get-Content -Raw -LiteralPath $RunScript

    $cratesRoot = Join-Path $RepoRoot 'crates'
    $rustPaths = @(
        Get-ChildItem $cratesRoot -Recurse -File -Filter '*.rs' |
            ForEach-Object { $_.FullName }
    )
    if ($rustPaths.Count -eq 0) { Fail 'no Rust source files found under crates/' }

    Write-Host '[1/8] Checking hardening patch applies cleanly...'
    & git apply --check -- $PatchPath
    if ($LASTEXITCODE -ne 0) {
        Fail 'hardening patch no longer applies cleanly; upstream security-sensitive code changed and needs review'
    }

    Write-Host '[2/8] Checking shared cloud-upload API surface...'
    $gcsPath = Join-Path $RepoRoot 'crates\codegen\xai-file-utils\src\gcs.rs'
    if (-not (Test-Path $gcsPath)) { Fail "missing expected file: $gcsPath" }
    $gcsText = Get-Content -Raw -LiteralPath $gcsPath
    $gcsMatches = [regex]::Matches($gcsText, 'pub\s+async\s+fn\s+(upload_[A-Za-z0-9_]+)')
    $actualGcs = @($gcsMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $expectedGcs = @('upload_bytes', 'upload_bytes_signed', 'upload_file', 'upload_stream')

    $unexpectedGcs = @($actualGcs | Where-Object { $_ -notin $expectedGcs })
    if ($unexpectedGcs.Count -gt 0) {
        Fail ('new public cloud-upload helper(s) require review: ' + ($unexpectedGcs -join ', '))
    }
    foreach ($name in $expectedGcs) {
        if ($name -notin $actualGcs) {
            Fail "expected upload helper disappeared or was renamed: $name; review the upstream refactor before building"
        }
        Require-Contains $patchText ('grok_safe_block_cloud_storage_upload("' + $name + '")') "patch has no fail-closed guard for $name"
    }

    Write-Host '[3/8] Checking storage bypasses with real file-content scanning...'
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

    Write-Host '[4/8] Verifying remote-session writeback is fail-closed...'
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
    foreach ($marker in @(
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC',
        'grok-safe-remote-sync-blocked',
        'forcing local session storage'
    )) {
        Require-Contains $patchText $marker "remote-sync hardening marker missing: $marker"
    }

    Write-Host '[5/8] Verifying in-app updater cannot replace the hardened binary...'
    $updaterPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-update\src\auto_update.rs'
    if (-not (Test-Path $updaterPath)) { Fail "missing updater source: $updaterPath" }
    $updaterText = Get-Content -Raw -LiteralPath $updaterPath
    Require-Contains $updaterText 'pub async fn get_installer()' 'updater installer resolution changed; review self-update path'
    Require-Contains $updaterText 'pub async fn run_install_script' 'updater install sink changed; review self-update path'
    Require-Contains $patchText 'GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE' 'self-update unsafe override guard is missing'
    Require-Contains $patchText 'in-app self-update is disabled' 'run_install_script fail-closed guard is missing'

    Write-Host '[6/8] Verifying launcher forces privacy-sensitive features off...'
    $launcherRequirements = @{
        'GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS' = "= '0'"
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC' = "= '0'"
        'GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE' = "= '0'"
        'GROK_STORAGE_MODE' = "= 'local'"
        'GROK_TELEMETRY_ENABLED' = "= 'false'"
        'GROK_TELEMETRY_TRACE_UPLOAD' = "= 'false'"
        'GROK_TELEMETRY_MIXPANEL_ENABLED' = "= 'false'"
        'GROK_FEEDBACK_ENABLED' = "= 'false'"
        'GROK_EXTERNAL_OTEL' = "= '0'"
        'OTEL_SDK_DISABLED' = "= 'true'"
    }
    foreach ($entry in $launcherRequirements.GetEnumerator()) {
        Require-Contains $runText ('$env:' + $entry.Key) "launcher does not set $($entry.Key)"
        Require-Contains $runText $entry.Value "launcher does not force a safe value for $($entry.Key)"
    }

    Write-Host '[7/8] Inventorying security-sensitive network/storage markers...'
    $riskPatterns = @(
        '/storage',
        'storage.googleapis.com',
        'https://code.grok.com',
        'save_session_data',
        'repo_state.upload',
        'upload_multipart',
        'batch_upload',
        'TraceExportConfig',
        'GROK_TELEMETRY_ENABLED',
        'run_install_script'
    )
    foreach ($pattern in $riskPatterns) {
        $hits = @(Select-String -Path $rustPaths -SimpleMatch $pattern)
        Write-Host ("  {0,-32} {1,5} hit(s)" -f $pattern, $hits.Count)
    }

    Write-Host '[8/8] Verifying defense-in-depth patch markers...'
    foreach ($marker in @(
        'GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS',
        'grok-safe-storage-blocked',
        'GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC',
        'grok-safe-remote-sync-blocked',
        'GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE'
    )) {
        Require-Contains $patchText $marker "hardening marker missing from patch: $marker"
    }

    Write-Host ''
    Write-Host 'grok-safe static audit PASSED.' -ForegroundColor Green
    Write-Host 'This proves the expected fail-closed guards are present and the known egress surfaces have not structurally drifted.'
    Write-Host 'It does NOT prove that model inference contains no source code, nor does it sandbox MCP/hooks/plugins/shell tools.' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
