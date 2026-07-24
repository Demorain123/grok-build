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
$EgressAuditScript = Join-Path $ScriptDir 'audit-egress-boundaries.ps1'

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
        '^crates/codegen/xai-grok-shell/src/session/acp_session\.rs$',
        '^crates/codegen/xai-grok-shell/src/agent/(init|feedback_client|session_registry_client)\.rs$',
        '^crates/codegen/xai-grok-shell/src/http(\.rs|/)',
        '^crates/codegen/xai-grok-shell/src/extensions/(feedback|share|privacy)\.rs$',
        '^crates/codegen/xai-grok-memory/',
        '^crates/codegen/xai-grok-update/',
        '^crates/codegen/xai-grok-telemetry/',
        '^crates/codegen/xai-grok-workspace/src/(upload/|recovery\.rs$)',
        '^crates/codegen/xai-grok-http/',
        '^crates/codegen/xai-grok-sampler/',
        '^crates/codegen/xai-mixpanel/',
        '^crates/common/xai-tracing/src/http_client\.rs$',
        '^prod/mc/cli-chat-proxy-types/',
        '(^|/)Cargo\.toml$',
        '^Cargo\.lock$',
        '^rust-toolchain\.toml$'
    )
    foreach ($pattern in $patterns) {
        if ($p -match $pattern) { return $true }
    }
    return $false
}

function Restore-PreSyncHead([string]$Commit, [string]$Reason) {
    Write-Host ''
    Write-Host "Safety gate failed: $Reason" -ForegroundColor Red
    Write-Host "Rolling branch back to exact pre-sync commit $Commit ..." -ForegroundColor Yellow
    & git reset --hard $Commit *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "safety gate failed and automatic rollback also failed; intended rollback commit: $Commit"
    }
    Write-Host 'Rollback completed.' -ForegroundColor Green
}

function Invoke-SafetyAudits {
    & $AuditScript
    if (Test-Path -LiteralPath $EgressAuditScript -PathType Leaf) {
        & $EgressAuditScript
    } else {
        throw "egress audit script not found: $EgressAuditScript"
    }
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is not available on PATH'
    }
    if (-not (Test-Path $AuditScript)) {
        throw "audit script not found: $AuditScript"
    }
    if (-not (Test-Path $EgressAuditScript)) {
        throw "egress audit script not found: $EgressAuditScript"
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
        Write-Host 'No new upstream commits to replay. Running the current audits only.'
        Invoke-SafetyAudits
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
        if ($LASTEXITCODE -ne 0) { throw 'Unable to show security-sensitive upstream diff stat.' }

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
        throw 'upstream rebase failed and was aborted'
    }

    $postRebase = (& git rev-parse HEAD).Trim()
    Write-Host "Rebased HEAD:          $postRebase"
    Write-Host 'Running post-sync security audits...'

    try {
        Invoke-SafetyAudits
    }
    catch {
        $auditMessage = $_.Exception.Message
        Restore-PreSyncHead -Commit $before -Reason "post-sync audit failed: $auditMessage"
        throw "post-sync security audit failed; branch was rolled back to $before"
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
