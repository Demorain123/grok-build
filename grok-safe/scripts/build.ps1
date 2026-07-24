[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$AuditScript = Join-Path $ScriptDir 'audit.ps1'
$PatchPath = Join-Path $SafeRoot 'patches\0001-disable-cloud-storage-uploads.patch'
$DistDir = Join-Path $SafeRoot 'dist'
$CacheDir = Join-Path $SafeRoot '.cache'
$TargetDir = Join-Path $CacheDir 'target'

foreach ($cmd in @('git', 'cargo', 'rustc', 'dotslash')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' was not found on PATH."
    }
}

if (-not (Test-Path $PatchPath)) { throw "Hardening patch not found: $PatchPath" }
if (-not (Test-Path $AuditScript)) { throw "Audit script not found: $AuditScript" }

Push-Location $RepoRoot
try {
    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
    if ($status) {
        throw 'Refusing to build from a dirty tree. Commit/stash changes so SOURCE_COMMIT and patch provenance are exact.'
    }

    $sourceCommit = (& git rev-parse HEAD).Trim()
    $sourceBranch = (& git branch --show-current).Trim()
    if (-not $sourceCommit) { throw 'Unable to resolve source commit.' }
    if ($sourceBranch -notmatch '^privacy-hardening-') {
        throw "Refusing hardened build from branch '$sourceBranch'. Use a privacy-hardening-* branch."
    }

    Write-Host 'Running mandatory static security audit...'
    & $AuditScript
    if ($LASTEXITCODE -ne 0) { throw 'grok-safe audit failed' }

    $patchHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PatchPath).Hash.ToLowerInvariant()
    $cargoVersion = (& cargo --version).Trim()
    $rustcVersion = (& rustc --version).Trim()

    New-Item -ItemType Directory -Force -Path $DistDir, $CacheDir, $TargetDir | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Worktree = Join-Path ([System.IO.Path]::GetTempPath()) "grok-safe-build-$stamp-$PID"

    Write-Host "Creating temporary build worktree from $sourceCommit"
    & git worktree add --detach -- $Worktree $sourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }

    try {
        $PatchInWorktree = Join-Path $Worktree 'grok-safe\patches\0001-disable-cloud-storage-uploads.patch'
        Write-Host 'Applying fail-closed egress/update hardening patch...'
        # The patch is deliberately hand-maintained as a small replay layer.
        # --recount recalculates hunk lengths but still requires source context to match.
        & git -C $Worktree apply --recount --check -- $PatchInWorktree
        if ($LASTEXITCODE -ne 0) { throw 'hardening patch context check failed in build worktree' }
        & git -C $Worktree apply --recount -- $PatchInWorktree
        if ($LASTEXITCODE -ne 0) { throw 'hardening patch apply failed in build worktree' }
        & git -C $Worktree diff --check
        if ($LASTEXITCODE -ne 0) { throw 'patched tree failed git diff --check' }

        # Verify the patched tree itself, not merely the patch text.
        $patchedAssertions = @(
            @{ Path='crates\codegen\xai-file-utils\src\gcs.rs'; Needle='grok_safe_block_cloud_storage_upload' },
            @{ Path='crates\codegen\xai-file-utils\src\storage_client.rs'; Needle='grok-safe-storage-blocked' },
            @{ Path='crates\codegen\xai-grok-shell\src\agent\init.rs'; Needle='forcing local session storage' },
            @{ Path='crates\codegen\xai-grok-shell\src\remote\client.rs'; Needle='grok-safe-remote-sync-blocked' },
            @{ Path='crates\codegen\xai-grok-shell\src\extensions\feedback.rs'; Needle='feedback network submission is disabled' },
            @{ Path='crates\codegen\xai-grok-telemetry\src\client.rs'; Needle='GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS' },
            @{ Path='crates\codegen\xai-grok-telemetry\src\external\mod.rs'; Needle='GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS' },
            @{ Path='crates\codegen\xai-grok-telemetry\src\otel_layer\mod.rs'; Needle='GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS' },
            @{ Path='crates\codegen\xai-grok-update\src\auto_update.rs'; Needle='in-app self-update is disabled' }
        )
        foreach ($assertion in $patchedAssertions) {
            $fullPath = Join-Path $Worktree $assertion.Path
            if (-not (Test-Path $fullPath)) { throw "patched source missing: $fullPath" }
            $text = Get-Content -Raw -LiteralPath $fullPath
            if (-not $text.Contains($assertion.Needle)) {
                throw "patched source is missing required hardening marker '$($assertion.Needle)' in $($assertion.Path)"
            }
        }

        $oldTargetDir = $env:CARGO_TARGET_DIR
        $oldIncremental = $env:CARGO_INCREMENTAL
        $env:CARGO_TARGET_DIR = $TargetDir
        $env:CARGO_INCREMENTAL = '0'
        try {
            Push-Location $Worktree
            try {
                Write-Host 'Compiling every crate modified by the security patch...'
                & cargo check -p xai-file-utils -p xai-grok-shell -p xai-grok-update -p xai-grok-telemetry
                if ($LASTEXITCODE -ne 0) { throw 'focused cargo check for hardened crates failed' }

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
            if ($null -eq $oldIncremental) {
                Remove-Item Env:CARGO_INCREMENTAL -ErrorAction SilentlyContinue
            } else {
                $env:CARGO_INCREMENTAL = $oldIncremental
            }
        }

        $builtExe = Join-Path $TargetDir 'release\xai-grok-pager.exe'
        if (-not (Test-Path $builtExe)) {
            throw "Expected Windows release binary was not found: $builtExe"
        }

        $destExe = Join-Path $DistDir 'grok-safe.exe'
        Copy-Item -Force $builtExe $destExe
        $exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destExe).Hash.ToLowerInvariant()

        Write-Host 'Running a no-session smoke check of the produced binary...'
        & $destExe version *> $null
        if ($LASTEXITCODE -ne 0) { throw 'built grok-safe.exe failed the version smoke check' }

        Set-Content -NoNewline -Encoding ascii -Path (Join-Path $DistDir 'grok-safe.exe.sha256') -Value "$exeHash  grok-safe.exe"
        Set-Content -NoNewline -Encoding ascii -Path (Join-Path $DistDir 'PATCH_SHA256.txt') -Value $patchHash
        Set-Content -NoNewline -Encoding ascii -Path (Join-Path $DistDir 'SOURCE_COMMIT.txt') -Value $sourceCommit

        $buildInfo = [ordered]@{
            schema = 2
            product = 'grok-safe'
            policy = 'fail-closed-non-inference-egress-v3'
            source_repository = 'https://github.com/xai-org/grok-build'
            safety_repository = 'https://github.com/Demorain123/grok-build'
            safety_branch = $sourceBranch
            source_commit = $sourceCommit
            hardening_patch_sha256 = $patchHash
            binary_sha256 = $exeHash
            cargo_version = $cargoVersion
            rustc_version = $rustcVersion
            built_at_utc = [DateTime]::UtcNow.ToString('o')
            blocked_by_default = @(
                'cloud-storage-artifact-uploads',
                'remote-session-writeback-and-sharing-backend',
                'product-telemetry-and-mixpanel',
                'internal-and-external-otlp-export',
                'feedback-network-submission',
                'in-app-self-update'
            )
        }
        $buildInfo | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -Path (Join-Path $DistDir 'BUILD_INFO.json')

        Write-Host ''
        Write-Host 'Hardened build completed.' -ForegroundColor Green
        Write-Host "Binary:        $destExe"
        Write-Host "Binary SHA256: $exeHash"
        Write-Host "Patch SHA256:  $patchHash"
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
