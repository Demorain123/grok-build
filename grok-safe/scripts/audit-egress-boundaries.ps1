[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SafeRoot = Resolve-Path (Join-Path $ScriptDir '..')
$RepoRoot = Resolve-Path (Join-Path $SafeRoot '..')

function Fail([string]$Message) {
    throw "grok-safe egress audit FAILED: $Message"
}

function Require-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { Fail $Message }
}

Push-Location $RepoRoot
try {
    $queuePath = Join-Path $RepoRoot 'crates\codegen\xai-file-utils\src\queue.rs'
    $workspaceUploadPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-workspace\src\upload\mod.rs'
    $workspaceRecoveryPath = Join-Path $RepoRoot 'crates\codegen\xai-grok-workspace\src\recovery.rs'

    foreach ($path in @($queuePath, $workspaceUploadPath, $workspaceRecoveryPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Fail "expected reviewed egress-boundary source is missing: $path"
        }
    }

    $queueText = Get-Content -Raw -LiteralPath $queuePath
    $workspaceUploadText = Get-Content -Raw -LiteralPath $workspaceUploadPath
    $workspaceRecoveryText = Get-Content -Raw -LiteralPath $workspaceRecoveryPath

    Write-Host '[egress 1/3] Verifying UploadQueue still terminates at the guarded shared GCS dispatchers...'
    Require-Contains $queueText 'use crate::gcs::{StorageConfig, upload_bytes, upload_file, upload_stream};' `
        'UploadQueue no longer imports the reviewed shared GCS dispatchers; review for a new upload backend/bypass'

    foreach ($needle in @('upload_bytes(', 'upload_file(', 'upload_stream(')) {
        Require-Contains $queueText $needle "UploadQueue no longer references expected guarded dispatcher $needle; review queue refactor"
    }

    Write-Host '[egress 2/3] Verifying workspace artifact upload/recovery still funnels through UploadQueue...'
    Require-Contains $workspaceUploadText 'xai_file_utils::queue' `
        'workspace upload no longer depends on xai-file-utils UploadQueue; review for direct network egress'
    Require-Contains $workspaceRecoveryText 'UploadQueue' `
        'workspace recovery no longer re-enqueues through UploadQueue; review restart-recovery egress path'

    foreach ($artifact in @('tool_state.json', 'workspace_environment.json', 'session_artifact.tar.gz')) {
        if (-not ($workspaceUploadText.Contains($artifact) -or $workspaceRecoveryText.Contains($artifact))) {
            Fail "known workspace artifact marker '$artifact' disappeared; review upstream workspace upload redesign"
        }
    }

    Write-Host '[egress 3/3] Rejecting direct HTTP send sinks inside reviewed workspace upload/recovery modules...'
    foreach ($entry in @(
        @{ Name='workspace upload'; Text=$workspaceUploadText },
        @{ Name='workspace recovery'; Text=$workspaceRecoveryText }
    )) {
        foreach ($needle in @('.send().await', '.post(', '.put(', '.patch(', '.delete(')) {
            if ($entry.Text.Contains($needle)) {
                Fail "$($entry.Name) gained direct HTTP sink '$needle'; it may bypass xai-file-utils upload guards"
            }
        }
    }

    Write-Host 'grok-safe egress-boundary audit PASSED.' -ForegroundColor Green
    Write-Host 'Workspace artifacts and restart recovery still funnel through the fail-closed xai-file-utils upload boundary.'
}
finally {
    Pop-Location
}
