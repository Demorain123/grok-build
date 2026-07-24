[CmdletBinding()]
param(
    [string]$UpstreamUrl = 'https://github.com/xai-org/grok-build.git',
    [switch]$ReviewedRiskyChanges
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$AuditScript = Join-Path $ScriptDir 'audit.ps1'

function Invoke-Git([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args) {
    & git @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git command failed: git $($Args -join ' ')"
    }
}

function Normalize-RepoPath([string]$Path) {
    return ($Path -replace '\\', '/')
}

function Test-SecuritySensitivePath([string]$Path) {
    $p = Normalize-RepoPath $Path
    $patterns = @(
        '^crates/codegen/xai-file-utils/',
        '^crates/codegen/xai-grok-shell/src/upload/',
        '^crates/codegen/xai-grok-shell/src/remote/',
        '^crates/codegen/xai-grok-shell/src/session/storage/',
        '^crates/codegen/xai-grok-shell/src/agent/init\.rs$',
        '^crates/codegen/xai-grok-shell/src/http(\.rs|/)',
        '^crates/codegen/xai-grok-shell/src/extensions/(feedback|share|privacy)\.rs$',
        '^crates/codegen/xai-grok-update/',
        '^crates/codegen/xai-grok-telemetry/',
        '^prod/mc/cli-chat-proxy-types/',
        '^Cargo\.lock$',
        '^rust-toolchain\.toml$'
    )
    foreach ($pattern in $patterns) {
        if ($p -match $pattern) { return $true }
    }
    return $false
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is not available on PATH'
    }
    if (-not (Test-Path $AuditScript)) {
        throw "audit script not found: $AuditScript"
    }

    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
    if ($status) {
        throw 'Working tree is not clean. Commit/stash local changes before syncing upstream.'
    }

    $branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'Could not determine the current branch.' }
    if ($branch -notmatch '^privacy-hardening-') {
        throw "Refusing to sync branch '$branch'. Run this only on a privacy-hardening-* branch."
    }

    $remotes = @(& git remote)
    if ($LASTEXITCODE -ne 0) { throw 'git remote failed' }
    if ('upstream' -notin $remotes) {
        Write-Host "Adding upstream remote: $UpstreamUrl"
        Invoke-Git remote add upstream $UpstreamUrl
    } else {
        Invoke-Git remote set-url upstream $UpstreamUrl
    }

    Write-Host 'Fetching official upstream/main + tags...'
    Invoke-Git fetch --prune upstream main --tags

    $before = (& git rev-parse HEAD).Trim()
    $upstream = (& git rev-parse upstream/main).Trim()
    $mergeBase = (& git merge-base HEAD upstream/main).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $mergeBase) {
        throw 'Unable to determine merge-base with upstream/main.'
    }

    Write-Host "Current safety branch: $before"
    Write-Host "Upstream main:        $upstream"
    Write-Host "Common base:          $mergeBase"

    if ($mergeBase -eq $upstream) {
        Write-Host 'No new upstream commits to replay. Running the current audit only.'
        & $AuditScript
        if ($LASTEXITCODE -ne 0) { throw 'security audit failed' }
        return
    }

    $changedPaths = @(& git diff --name-only "$mergeBase..$upstream")
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list upstream changes.' }
    $changedPaths = @($changedPaths | Where-Object { $_ } | Sort-Object -Unique)
    $riskyPaths = @($changedPaths | Where-Object { Test-SecuritySensitivePath $_ })

    Write-Host ''
    Write-Host ("Upstream changed {0} path(s); {1} security-sensitive." -f $changedPaths.Count, $riskyPaths.Count)
    if ($riskyPaths.Count -gt 0) {
        Write-Host 'Security-sensitive upstream changes:' -ForegroundColor Yellow
        $riskyPaths | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host ''
        & git diff --stat "$mergeBase..$upstream" -- @riskyPaths

        if (-not $ReviewedRiskyChanges) {
            Write-Host ''
            Write-Host 'SYNC STOPPED BEFORE REBASE.' -ForegroundColor Yellow
            Write-Host 'Review the listed upstream diffs first. Then rerun with -ReviewedRiskyChanges.' -ForegroundColor Yellow
            exit 3
        }
    }

    Write-Host ''
    Write-Host 'Rebasing the thin safety layer onto upstream/main...'
    & git rebase upstream/main
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Rebase failed; automatically aborting so the previous branch remains intact.' -ForegroundColor Yellow
        & git rebase --abort *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'WARNING: git rebase --abort also failed; inspect repository state manually.' -ForegroundColor Red
        }
        exit 2
    }

    $postRebase = (& git rev-parse HEAD).Trim()
    Write-Host "Rebased HEAD:          $postRebase"
    Write-Host 'Running post-sync security audit...'
    & $AuditScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Post-sync audit FAILED. Rolling the branch back to its exact pre-sync commit.' -ForegroundColor Red
        & git reset --hard $before *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "audit failed and automatic rollback failed; intended rollback commit: $before"
        }
        throw 'post-sync security audit failed; branch was rolled back and must not be released'
    }

    $after = (& git rev-parse HEAD).Trim()
    Write-Host ''
    Write-Host 'Upstream sync + audit completed.' -ForegroundColor Green
    Write-Host "Previous safety HEAD: $before"
    Write-Host "Upstream reviewed:    $upstream"
    Write-Host "New safety HEAD:      $after"
    Write-Host 'Push explicitly only after reviewing the rebase result.'
}
finally {
    Pop-Location
}
