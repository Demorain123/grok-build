[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$AuditScript = Join-Path $ScriptDir 'audit.ps1'
$EgressAuditScript = Join-Path $ScriptDir 'audit-egress-boundaries.ps1'
$ProtocBootstrapScript = Join-Path $ScriptDir 'ensure-windows-protoc.ps1'
$PatchDir = Join-Path $SafeRoot 'patches'
$DistDir = Join-Path $SafeRoot 'dist'
$CacheDir = Join-Path $SafeRoot '.cache'
$TargetDir = Join-Path $CacheDir 'target'
$oldProtoc = $env:PROTOC
$oldSafeProtocVersion = $env:GROK_SAFE_PROTOC_VERSION
$oldAwsLcPrebuiltNasm = $env:AWS_LC_SYS_PREBUILT_NASM

# On Windows, ensure-windows-protoc.ps1 sets PROTOC to a verified native
# protoc adapter before Cargo runs. Upstream xai-proto-build checks PROTOC
# first, so the DotSlash bin/protoc wrapper is not required on Windows.
$requiredCommands = @('git', 'cargo', 'rustc')
if (-not $IsWindows) {
    $requiredCommands += 'dotslash'
}
foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' was not found on PATH."
    }
}

foreach ($audit in @($AuditScript, $EgressAuditScript, $ProtocBootstrapScript)) {
    if (-not (Test-Path -LiteralPath $audit -PathType Leaf)) {
        throw "Required build/safety script not found: $audit"
    }
}
$PatchFiles = @(
    Get-ChildItem -LiteralPath $PatchDir -File -Filter '*.patch' -ErrorAction Stop |
        Sort-Object Name
)
if ($PatchFiles.Count -eq 0) { throw "No hardening patches found under: $PatchDir" }

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

    Write-Host 'Running mandatory static security audits...'
    & $AuditScript
    & $EgressAuditScript

    New-Item -ItemType Directory -Force -Path $DistDir, $CacheDir, $TargetDir | Out-Null

    $protocVersion = $null
    if ($IsWindows) {
        Write-Host 'Preparing upstream-matched verified Windows protoc...'
        & $ProtocBootstrapScript -RepoRoot $RepoRoot -CacheRoot (Join-Path $CacheDir 'protoc')
        if (-not $env:PROTOC) { throw 'Windows protoc bootstrap did not set PROTOC.' }
        $protocVersion = (& $env:PROTOC --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Prepared Windows protoc failed its version check.' }

        # aws-lc-sys requires NASM for native x86/x86-64 assembly builds. For
        # non-FIPS Windows x86-64 builds it officially supports crate-provided
        # prebuilt NASM objects when NASM is absent. Allow that fallback so a
        # clean Windows machine does not need a separate NASM installation.
        $env:AWS_LC_SYS_PREBUILT_NASM = '1'
        Write-Host 'AWS-LC Windows NASM fallback: crate-provided prebuilt NASM objects are allowed.'
    }

    $patchHashes = [ordered]@{}
    foreach ($patch in $PatchFiles) {
        $patchHashes[$patch.Name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $patch.FullName).Hash.ToLowerInvariant()
    }
    $cargoVersion = (& cargo --version).Trim()
    $rustcVersion = (& rustc --version).Trim()

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Worktree = Join-Path ([System.IO.Path]::GetTempPath()) "grok-safe-build-$stamp-$PID"

    Write-Host "Creating temporary build worktree from $sourceCommit"
    & git worktree add --detach -- $Worktree $sourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }

    try {
        $PatchFilesInWorktree = @(
            Get-ChildItem -LiteralPath (Join-Path $Worktree 'grok-safe\patches') -File -Filter '*.patch' |
                Sort-Object Name
        )
        if ($PatchFilesInWorktree.Count -ne $PatchFiles.Count) {
            throw 'hardening patch count changed between source and detached build worktree'
        }

        Write-Host ("Applying {0} ordered fail-closed hardening patch(es)..." -f $PatchFilesInWorktree.Count)
        foreach ($patch in $PatchFilesInWorktree) {
            Write-Host ("  -> {0}" -f $patch.Name)
            & git -C $Worktree apply --recount --check -- $patch.FullName
            if ($LASTEXITCODE -ne 0) { throw "hardening patch context check failed: $($patch.Name)" }
            & git -C $Worktree apply --recount -- $patch.FullName
            if ($LASTEXITCODE -ne 0) { throw "hardening patch apply failed: $($patch.Name)" }
        }
        & git -C $Worktree diff --check
        if ($LASTEXITCODE -ne 0) { throw 'patched tree failed git diff --check' }

        $patchedAssertions = @(
            @{ Path='crates\codegen\xai-file-utils\src\gcs.rs'; Needle='grok_safe_block_cloud_storage_upload' },
            @{ Path='crates\codegen\xai-file-utils\src\storage_client.rs'; Needle='grok-safe-storage-blocked' },
            @{ Path='crates\codegen\xai-grok-shell\src\agent\init.rs'; Needle='forcing local session storage' },
            @{ Path='crates\codegen\xai-grok-shell\src\remote\client.rs'; Needle='grok-safe-remote-sync-blocked' },
            @{ Path='crates\codegen\xai-grok-shell\src\extensions\feedback.rs'; Needle='feedback network submission is disabled' },
            @{ Path='crates\codegen\xai-grok-shell\src\agent\feedback_client.rs'; Needle='blocked feedback/session-signals auxiliary request' },
            @{ Path='crates\codegen\xai-grok-shell\src\agent\session_registry_client.rs'; Needle='blocked session-registry remote replication request' },
            @{ Path='crates\codegen\xai-grok-memory\src\embedding.rs'; Needle='blocked remote memory embedding text egress' },
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
                # xai-file-utils is the lowest shared upload boundary and remains a
                # focused hard gate. Other standalone crate checks are diagnostic on
                # Windows because upstream documents source builds there as best-effort.
                # The actual production hard gate is the final pager release link.
                Write-Host 'Compiling shared upload hardening boundary...'
                & cargo check -p xai-file-utils
                if ($LASTEXITCODE -ne 0) { throw 'xai-file-utils hardening cargo check failed' }

                foreach ($crate in @('xai-grok-memory','xai-grok-telemetry','xai-grok-shell','xai-grok-update')) {
                    Write-Host "Diagnostic: checking $crate standalone crate..."
                    & cargo check -p $crate
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Standalone $crate cargo check failed; continuing to the production Windows release hard gate."
                    }
                }

                Write-Host 'Building hardened Grok Build Windows release (production hard gate)...'
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
        Set-Content -NoNewline -Encoding ascii -Path (Join-Path $DistDir 'SOURCE_COMMIT.txt') -Value $sourceCommit
        $patchHashes | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -Path (Join-Path $DistDir 'PATCH_SHA256.json')

        $buildInfo = [ordered]@{
            schema = 5
            product = 'grok-safe'
            policy = 'fail-closed-non-inference-egress-v5'
            source_repository = 'https://github.com/xai-org/grok-build'
            safety_repository = 'https://github.com/Demorain123/grok-build'
            safety_branch = $sourceBranch
            source_commit = $sourceCommit
            hardening_patches_sha256 = $patchHashes
            binary_sha256 = $exeHash
            cargo_version = $cargoVersion
            rustc_version = $rustcVersion
            protoc_version = $protocVersion
            built_at_utc = [DateTime]::UtcNow.ToString('o')
            blocked_by_default = @(
                'cloud-storage-artifact-uploads',
                'remote-session-writeback-and-sharing-backend',
                'cross-host-session-registry-replication',
                'product-telemetry-and-mixpanel',
                'internal-and-external-otlp-export',
                'feedback-and-session-analytics-egress',
                'remote-memory-embedding-text-egress',
                'in-app-self-update'
            )
        }
        $buildInfo | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -Path (Join-Path $DistDir 'BUILD_INFO.json')

        Write-Host ''
        Write-Host 'Hardened build completed.' -ForegroundColor Green
        Write-Host "Binary:        $destExe"
        Write-Host "Binary SHA256: $exeHash"
        foreach ($entry in $patchHashes.GetEnumerator()) {
            Write-Host ("Patch SHA256:  {0}  {1}" -f $entry.Value, $entry.Key)
        }
        Write-Host "Source commit: $sourceCommit"
        if ($protocVersion) { Write-Host "Protoc:        $protocVersion" }
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
    if ($null -eq $oldProtoc) {
        Remove-Item Env:PROTOC -ErrorAction SilentlyContinue
    } else {
        $env:PROTOC = $oldProtoc
    }
    if ($null -eq $oldSafeProtocVersion) {
        Remove-Item Env:GROK_SAFE_PROTOC_VERSION -ErrorAction SilentlyContinue
    } else {
        $env:GROK_SAFE_PROTOC_VERSION = $oldSafeProtocVersion
    }
    if ($null -eq $oldAwsLcPrebuiltNasm) {
        Remove-Item Env:AWS_LC_SYS_PREBUILT_NASM -ErrorAction SilentlyContinue
    } else {
        $env:AWS_LC_SYS_PREBUILT_NASM = $oldAwsLcPrebuiltNasm
    }
    Pop-Location
}
