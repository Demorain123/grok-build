[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CommandScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'command.ps1')).Path
$ProfilePath = $PROFILE.CurrentUserAllHosts
$ProfileDir = Split-Path -Parent $ProfilePath
$MarkerStart = '# >>> grok-safe launcher >>>'
$MarkerEnd = '# <<< grok-safe launcher <<<'
$EscapedCommandScript = $CommandScript.Replace("'", "''")
$Block = @"
$MarkerStart
. '$EscapedCommandScript'
$MarkerEnd
"@

if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
}

if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
    $ProfileText = Get-Content -Raw -LiteralPath $ProfilePath
} else {
    $ProfileText = ''
}

$Pattern = '(?ms)^' + [regex]::Escape($MarkerStart) + '.*?^' + [regex]::Escape($MarkerEnd) + '\s*'
if ([regex]::IsMatch($ProfileText, $Pattern)) {
    $NewProfileText = [regex]::Replace($ProfileText, $Pattern, $Block + [Environment]::NewLine)
} else {
    if ($ProfileText.Length -gt 0 -and -not $ProfileText.EndsWith([Environment]::NewLine)) {
        $ProfileText += [Environment]::NewLine
    }
    $NewProfileText = $ProfileText + $Block + [Environment]::NewLine
}

[System.IO.File]::WriteAllText(
    $ProfilePath,
    $NewProfileText,
    [System.Text.UTF8Encoding]::new($false)
)

. $CommandScript

Write-Host 'grok-safe global command installed.' -ForegroundColor Green
Write-Host "PowerShell profile: $ProfilePath"
Write-Host ''
Write-Host 'Available commands:'
Write-Host '  gsafe                              # open current workspace'
Write-Host '  gsafe -w "V:\project"              # open a selected workspace'
Write-Host '  gsafe -w "V:\project" -r <id>      # resume a session in that workspace'
Write-Host '  gsafe -r <id>                      # resume in the current workspace'
Write-Host '  gsafe mcp doctor                   # forward normal Grok CLI arguments'
Write-Host ''
Write-Host 'The longer command name `grok-safe` is also available.'
