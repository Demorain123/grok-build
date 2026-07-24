[CmdletBinding()]
param(
    [switch]$SkipAudit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$AuditScript = Join-Path $ScriptDir 'audit.ps1'
$DistDir = Join-Path $SafeRoot 'dist'
$CacheDir = Join-Path $SafeRoot '.cache'
$TargetDir = Join-Path $CacheDir 'target'

foreach ($cmd in @('git', 'cargo', 'dotslash')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' was not found on PATH."
    }
}

if (-not $SkipAudit) {
    & $AuditScript
    if ($LASTEXITCODE -ne 0) { throw 'grok-safe audit failed' }
}

New-Item -ItemType Directory -Force -Path $DistDir, $CacheDir, $TargetDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Worktree = Join-Path ([System.IO.Path]::GetTempPath()) "grok-safe-build-$stamp-$PID"

Push-Location $RepoRoot
try {
    $sourceCommit = (& git rev-parse HEAD).Trim()
    if (-not $sourceCommit) { throw 'Unable to resolve source commit.' }

    Write-Host "Creating temporary build worktree from $sourceCommit"
    & git worktree add --detach -- $Worktree $sourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }

    try {
        $PatchInWorktree = Join-Path $Worktree 'grok-safe\patches\0001-disable-cloud-storage-uploads.patch'
        Write-Host 'Applying fail-closed cloud-storage patch...'
        & git -C $Worktree apply --check -- $PatchInWorktree
        if ($LASTEXITCODE -ne 0) { throw 'hardening patch check failed in build worktree' }
        & git -C $Worktree apply -- $PatchInWorktree
        if ($LASTEXITCODE -ne 0) { throw 'hardening patch apply failed in build worktree' }

        $gcsPatched = Get-Content -Raw (Join-Path $Worktree 'crates\codegen\xai-file-utils\src\gcs.rs')
        $storagePatched = Get-Content -Raw (Join-Path $Worktree 'crates\codegen\xai-file-utils\src\storage_client.rs')
        if ($gcsPatched -notmatch 'grok_safe_block_cloud_storage_upload') {
            throw 'patched worktree is missing the GCS fail-closed guard'
        }
        if ($storagePatched -notmatch 'grok-safe-storage-blocked') {
            throw 'patched worktree is missing the StorageClient loopback defense'
        }

        $oldTargetDir = $env:CARGO_TARGET_DIR
        $env:CARGO_TARGET_DIR = $TargetDir
        try {
            Push-Location $Worktree
            try {
                Write-Host 'Running focused compile check for xai-file-utils...'
                & cargo check -p xai-file-utils
                if ($LASTEXITCODE -ne 0) { throw 'cargo check -p xai-file-utils failed' }

                Write-Host 'Building hardened Grok Build release...'
                & cargo build -p xai-grok-pager-bin --release
                if ($LASTEXITCODE -ne 0) { throw 'cargo release build failed' }
            }
            finally {
                Pop-Location
            }
        }
        finally {
            if ($null -eq $oldTargetDir) {
                Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
            } else {
                $env:CARGO_TARGET_DIR = $oldTargetDir
            }
        }

        $builtExe = Join-Path $TargetDir 'release\xai-grok-pager.exe'
        if (-not (Test-Path $builtExe)) {
            throw "Expected Windows release binary was not found: $builtExe"
        }

        $destExe = Join-Path $DistDir 'grok-safe.exe'
        Copy-Item -Force $builtExe $destExe
        $hash = (Get-FileHash -Algorithm SHA256 $destExe).Hash.ToLowerInvariant()
        Set-Content -NoNewline -Encoding ascii -Path (Join-Path $DistDir 'grok-safe.exe.sha256') -Value "$hash  grok-safe.exe"
        Set-Content -Encoding utf8 -Path (Join-Path $DistDir 'SOURCE_COMMIT.txt') -Value $sourceCommit

        Write-Host ''
        Write-Host 'Hardened build completed.' -ForegroundColor Green
        Write-Host "Binary: $destExe"
        Write-Host "SHA256: $hash"
        Write-Host "Source commit: $sourceCommit"
    }
    finally {
        if (Test-Path $Worktree) {
            & git worktree remove --force -- $Worktree *> $null
            if (Test-Path $Worktree) {
                Remove-Item -Recurse -Force $Worktree -ErrorAction SilentlyContinue
            }
        }
        & git worktree prune *> $null
    }
}
finally {
    Pop-Location
}
