[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [switch]$StrictExtensionIsolation,
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

# Native Grok project extensions. MCP is an explicit user/project feature, so it is
# warning-only by default; hooks/plugins remain higher-risk because they can execute
# code automatically. StrictExtensionIsolation is optional and never required for
# the core hidden-upload hardening provided by the Rust patches.
Test-NonEmptyDirectory '.grok\hooks' 'Project Grok hooks can execute scripts on lifecycle/tool events' $true
Test-NonEmptyDirectory '.grok\plugins' 'Project Grok plugins can add hooks, MCP servers, tools and skills' $true
Test-NonEmptyDirectory '.grok\skills' 'Project Grok skills/instructions are loaded into the agent context' $false

$grokConfig = Join-Path $root '.grok\config.toml'
if (Test-Path -LiteralPath $grokConfig -PathType Leaf) {
    $text = Get-Content -Raw -LiteralPath $grokConfig
    $declaresMcp = $text -match '(?im)^\s*\[mcp_servers(?:\.|\])' -or
        $text -match '(?im)^\s*mcp_servers\s*='
    $declaresPlugins = $text -match '(?im)^\s*\[plugins(?:\.|\])' -or
        $text -match '(?im)^\s*plugins\s*='
    if ($declaresPlugins) {
        Add-Finding $high 'Project .grok/config.toml declares plugins'
    }
    if ($declaresMcp) {
        Add-Finding $medium 'Project .grok/config.toml declares MCP servers (left enabled; review remote MCPs you do not trust)'
    }
    if (-not $declaresMcp -and -not $declaresPlugins -and $text -match '(?im)^\s*\[') {
        Add-Finding $medium 'Project .grok/config.toml exists (permissions/config should still be reviewed)'
    }
}

# Compatibility MCP sources are explicit MCP configuration and are therefore
# warning-only. The launcher preserves upstream compatibility unless strict
# extension isolation is explicitly requested.
foreach ($relative in @('.mcp.json', '.cursor\mcp.json')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Add-Finding $medium "MCP compatibility configuration exists ($relative); left available by default"
    }
}

# Claude Code compatibility. Hooks/plugins can execute code, so surface them as
# high-risk notices; skills/agents remain informational. They are only blocked
# when StrictExtensionIsolation is explicitly enabled.
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
    Write-Host 'Project extension execution surfaces detected:' -ForegroundColor Yellow
    $high | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'These are explicit repo/vendor extensions, not the hidden Grok storage/writeback channels blocked by the Rust patch.' -ForegroundColor Yellow
    if ($StrictExtensionIsolation -and -not $AllowProjectExtensions) {
        throw 'Strict extension isolation blocked startup. Review the hooks/plugins, then rerun with -AllowProjectExtensions only if you trust them.'
    }
    if ($StrictExtensionIsolation) {
        Write-Host 'Strict extension isolation override accepted for this launch.' -ForegroundColor Yellow
    } else {
        Write-Host 'Normal extension behavior is retained. Use -StrictExtensionIsolation if you want these execution surfaces blocked.' -ForegroundColor Yellow
    }
}

Write-Host 'Project extension preflight: PASSED' -ForegroundColor Green
