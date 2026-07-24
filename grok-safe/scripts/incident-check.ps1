[CmdletBinding()]
param(
    [string]$GrokHome = (Join-Path $HOME '.grok')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$log = Join-Path $GrokHome 'logs\unified.jsonl'
if (-not (Test-Path $log)) {
    Write-Host "No unified log found at: $log"
    exit 0
}

Write-Host "Inspecting historical Grok Build log: $log"
Write-Host 'This script is read-only and does not upload or modify anything.'
Write-Host ''

$patterns = @(
    'repo_state.upload',
    'grok-code-session-traces',
    '/v1/storage',
    'file upload failed',
    'session_state'
)

$found = $false
foreach ($pattern in $patterns) {
    $hits = @(Select-String -LiteralPath $log -SimpleMatch $pattern)
    Write-Host ("{0,-26} {1,6} hit(s)" -f $pattern, $hits.Count)
    if ($hits.Count -gt 0) { $found = $true }
}

Write-Host ''
if ($found) {
    Write-Host 'Upload/storage-related markers exist in the historical log.' -ForegroundColor Yellow
    Write-Host 'This does not by itself prove every marked operation completed successfully, but it is a reason to inspect the affected dates and rotate any secrets that were committed or readable at that time.'
} else {
    Write-Host 'No known upload/storage markers were found in this unified log.' -ForegroundColor Green
    Write-Host 'Absence of log markers is not cryptographic proof that no data left the machine.'
}
