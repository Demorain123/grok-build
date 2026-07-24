[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [switch]$AllowProjectExtensions
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Add-Finding {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

$root = $ProjectPath
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitRoot = (& git -C $ProjectPath rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitRoot) {
        $root = ($gitRoot | Select-Object -First 1).Trim()
    }
}
$root = [System.IO.Path]::GetFullPath($root)

$high = [System.Collections.Generic.List[string]]::new()
$medium = [System.Collections.Generic.List[string]]::new()

function Test-NonEmptyDirectory([string]$RelativePath, [string]$Label, [bool]$HighRisk) {
    $path = Join-Path $root $RelativePath
    if (Test-Path -LiteralPath $path -PathType Container) {
        $hasFiles = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hasFiles) {
            if ($HighRisk) { Add-Finding $high "$Label ($RelativePath)" }
            else { Add-Finding $medium "$Label ($RelativePath)" }
        }
    }
}

# Native Grok project extensions.
Test-NonEmptyDirectory '.grok\hooks' 'Project Grok hooks can execute scripts on lifecycle/tool events' $true
Test-NonEmptyDirectory '.grok\plugins' 'Project Grok plugins can add hooks, MCP servers, tools and skills' $true
Test-NonEmptyDirectory '.grok\skills' 'Project Grok skills/instructions are loaded into the agent context' $false

$grokConfig = Join-Path $root '.grok\config.toml'
if (Test-Path -LiteralPath $grokConfig -PathType Leaf) {
    $text = Get-Content -Raw -LiteralPath $grokConfig
    if ($text -match '(?im)^\s*\[mcp_servers\.' -or $text -match '(?im)^\s*\[plugins(?:\.|\])') {
        Add-Finding $high 'Project .grok/config.toml declares MCP servers or plugins'
    } elseif ($text -match '(?im)^\s*\[') {
        Add-Finding $medium 'Project .grok/config.toml exists (permissions/config should still be reviewed)'
    }
}

# Compatibility MCP sources that Grok documents as auto-discovered.
foreach ($relative in @('.mcp.json', '.cursor\mcp.json')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Add-Finding $high "Auto-discovered MCP configuration exists ($relative)"
    }
}

# Claude Code compatibility: Grok can automatically read Claude hooks/plugins/
# skills/agents alongside its native .grok sources.
foreach ($relative in @('.claude\settings.json', '.claude\settings.local.json')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = Get-Content -Raw -LiteralPath $path
        if ($text -match '"hooks"\s*:' -or $text -match '"enabledPlugins"\s*:') {
            Add-Finding $high "Claude compatibility settings contain hooks/plugins ($relative)"
        } else {
            Add-Finding $medium "Claude compatibility settings exist ($relative)"
        }
    }
}
Test-NonEmptyDirectory '.claude\plugins' 'Claude-compatible project plugins may be discovered by Grok' $true
Test-NonEmptyDirectory '.claude\hooks' 'Claude-compatible project hooks may be discovered by Grok' $true
Test-NonEmptyDirectory '.claude\skills' 'Claude-compatible skills may alter agent instructions/tool usage' $false
Test-NonEmptyDirectory '.claude\agents' 'Claude-compatible agents may alter agent behavior' $false

Write-Host "grok-safe project preflight root: $root"
if ($medium.Count -gt 0) {
    Write-Host 'Review notices:' -ForegroundColor Yellow
    $medium | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

if ($high.Count -gt 0) {
    Write-Host 'Potential independent egress/command surfaces detected:' -ForegroundColor Yellow
    $high | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'These are not the hidden Grok storage/writeback channels blocked by the Rust patch.' -ForegroundColor Yellow
    Write-Host 'They are repo-controlled extensions that can legitimately start processes or contact remote services.' -ForegroundColor Yellow
    if (-not $AllowProjectExtensions) {
        throw 'grok-safe preflight blocked startup. Review the project extensions, then rerun run.ps1 with -AllowProjectExtensions only if you trust them.'
    }
    Write-Host 'Project extension override accepted for this launch.' -ForegroundColor Yellow
}

Write-Host 'Project extension preflight: PASSED' -ForegroundColor Green
