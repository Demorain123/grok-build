[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$PatchPath = Join-Path $SafeRoot 'patches\0001-disable-cloud-storage-uploads.patch'

function Fail([string]$Message) {
    throw "grok-safe audit FAILED: $Message"
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail 'git is not available on PATH'
    }

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'repository root could not be verified' }

    Write-Host '[1/5] Checking privacy patch applies cleanly...'
    & git apply --check -- $PatchPath
    if ($LASTEXITCODE -ne 0) {
        Fail 'hardening patch no longer applies cleanly; upstream upload code changed and needs review'
    }

    Write-Host '[2/5] Checking shared cloud-upload API surface...'
    $gcsPath = Join-Path $RepoRoot 'crates\codegen\xai-file-utils\src\gcs.rs'
    if (-not (Test-Path $gcsPath)) { Fail "missing expected file: $gcsPath" }

    $gcsText = Get-Content -Raw -LiteralPath $gcsPath
    $matches = [regex]::Matches($gcsText, 'pub\s+async\s+fn\s+(upload_[A-Za-z0-9_]+)')
    $actual = @($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $expected = @('upload_bytes', 'upload_bytes_signed', 'upload_file', 'upload_stream')

    $unexpected = @($actual | Where-Object { $_ -notin $expected })
    if ($unexpected.Count -gt 0) {
        Fail ('new public cloud-upload helper(s) require review: ' + ($unexpected -join ', '))
    }

    foreach ($name in $expected) {
        if ($name -notin $actual) {
            Fail "expected upload helper disappeared or was renamed: $name; review the upstream refactor before building"
        }
    }

    $patchText = Get-Content -Raw -LiteralPath $PatchPath
    foreach ($name in $expected) {
        $guard = 'grok_safe_block_cloud_storage_upload("' + $name + '")'
        if (-not $patchText.Contains($guard)) {
            Fail "patch does not contain a fail-closed guard for $name"
        }
    }

    Write-Host '[3/5] Checking for direct S3 upload bypasses...'
    $rustFiles = Get-ChildItem (Join-Path $RepoRoot 'crates') -Recurse -File -Filter '*.rs'
    $directS3 = @(
        $rustFiles |
            Select-String -Pattern '(^|[^A-Za-z0-9_])(crate::s3::upload_|xai_file_utils::s3::upload_)' |
            Where-Object { $_.Path -notlike '*\xai-file-utils\src\gcs.rs' }
    )
    if ($directS3.Count -gt 0) {
        $paths = $directS3 | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        Fail ('direct S3 upload bypass found outside gcs.rs: ' + ($paths -join '; '))
    }

    Write-Host '[4/5] Inventorying storage/network-risk markers...'
    $riskPatterns = @(
        '/storage',
        'storage.googleapis.com',
        'grok-code-session-traces',
        'repo_state.upload',
        'upload_multipart',
        'batch_upload',
        'TraceExportConfig'
    )
    foreach ($pattern in $riskPatterns) {
        $hits = @($rustFiles | Select-String -SimpleMatch $pattern)
        Write-Host ("  {0,-28} {1,5} hit(s)" -f $pattern, $hits.Count)
    }

    Write-Host '[5/5] Verifying defense-in-depth patch marker...'
    if ($patchText -notmatch 'grok-safe-storage-blocked') {
        Fail 'StorageClient loopback defense marker is missing from the patch'
    }
    if ($patchText -notmatch 'GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS') {
        Fail 'explicit unsafe override marker is missing from the patch'
    }

    Write-Host ''
    Write-Host 'grok-safe audit PASSED.' -ForegroundColor Green
    Write-Host 'Important: this is a static guardrail check, not proof that inference requests contain no source code.'
}
finally {
    Pop-Location
}
