[CmdletBinding()]
param(
    [string]$UpstreamUrl = 'https://github.com/xai-org/grok-build.git'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')
$AuditScript = Join-Path $ScriptDir 'audit.ps1'

Push-Location $RepoRoot
try {
    $status = & git status --porcelain
    if ($status) {
        throw 'Working tree is not clean. Commit/stash local changes before syncing upstream.'
    }

    $branch = (& git branch --show-current).Trim()
    if (-not $branch) { throw 'Could not determine the current branch.' }
    if ($branch -eq 'main') {
        throw 'Run this on the privacy-hardening branch, not main.'
    }

    $remotes = @(& git remote)
    if ('upstream' -notin $remotes) {
        Write-Host "Adding upstream remote: $UpstreamUrl"
        & git remote add upstream $UpstreamUrl
        if ($LASTEXITCODE -ne 0) { throw 'git remote add upstream failed' }
    } else {
        & git remote set-url upstream $UpstreamUrl
        if ($LASTEXITCODE -ne 0) { throw 'git remote set-url upstream failed' }
    }

    Write-Host 'Fetching official upstream main + tags...'
    & git fetch upstream main --tags
    if ($LASTEXITCODE -ne 0) { throw 'git fetch upstream failed' }

    $before = (& git rev-parse HEAD).Trim()
    $upstream = (& git rev-parse upstream/main).Trim()
    Write-Host "Current safety branch: $before"
    Write-Host "Upstream main:        $upstream"

    Write-Host 'Rebasing thin safety layer onto upstream/main...'
    & git rebase upstream/main
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Rebase stopped because upstream changed something that conflicts with the safety layer.' -ForegroundColor Yellow
        Write-Host 'Do NOT resolve upload-related conflicts mechanically. Review them first.' -ForegroundColor Yellow
        Write-Host 'Abort with: git rebase --abort'
        exit 2
    }

    Write-Host 'Running post-sync security audit...'
    & $AuditScript
    if ($LASTEXITCODE -ne 0) {
        throw 'post-sync security audit failed; do not build/release this upstream revision yet'
    }

    $after = (& git rev-parse HEAD).Trim()
    Write-Host ''
    Write-Host 'Upstream sync + audit completed.' -ForegroundColor Green
    Write-Host "New safety branch HEAD: $after"
    Write-Host 'Review `git log --oneline --decorate -n 20` and then push explicitly when satisfied.'
}
finally {
    Pop-Location
}
