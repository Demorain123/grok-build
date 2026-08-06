# Dot-source this file from a PowerShell profile to install the `grok-safe`
# function and the shorter `gsafe` alias. The function always launches through
# run.ps1, so workspace selection and session resume cannot accidentally bypass
# the privacy wrapper.

$script:GrokSafeRunScript = Join-Path $PSScriptRoot 'run.ps1'

function global:grok-safe {
    [CmdletBinding()]
    param(
        [Alias('w')]
        [string]$Workspace,

        [Alias('r')]
        [string]$Resume,

        [switch]$IsolatedHome,
        [Alias('OfficialHome')]
        [switch]$UseOfficialHome,
        [switch]$StrictExtensionIsolation,
        [switch]$AllowProjectExtensions,
        [switch]$AllowVendorCompatibility,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$GrokArgs
    )

    $runScript = $script:GrokSafeRunScript
    if (-not (Test-Path -LiteralPath $runScript -PathType Leaf)) {
        throw "grok-safe run.ps1 was not found: $runScript"
    }

    if ($Workspace) {
        if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
            throw "Workspace directory does not exist: $Workspace"
        }
        $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
    } else {
        $resolvedWorkspace = $null
    }

    $wrapperParams = @{}
    if ($IsolatedHome) { $wrapperParams['IsolatedHome'] = $true }
    if ($UseOfficialHome) { $wrapperParams['UseOfficialHome'] = $true }
    if ($StrictExtensionIsolation) { $wrapperParams['StrictExtensionIsolation'] = $true }
    if ($AllowProjectExtensions) { $wrapperParams['AllowProjectExtensions'] = $true }
    if ($AllowVendorCompatibility) { $wrapperParams['AllowVendorCompatibility'] = $true }

    $forwardArgs = @($GrokArgs)
    if ($forwardArgs.Count -gt 0 -and $forwardArgs[0] -eq '--') {
        $forwardArgs = @($forwardArgs | Select-Object -Skip 1)
    }
    if ($Resume) {
        $forwardArgs = @('--resume', $Resume) + $forwardArgs
    }

    $pushed = $false
    $childExitCode = 1
    try {
        if ($resolvedWorkspace) {
            Push-Location -LiteralPath $resolvedWorkspace
            $pushed = $true
        }

        & $runScript @wrapperParams -- @forwardArgs
        $childExitCode = $LASTEXITCODE
    } finally {
        if ($pushed) {
            Pop-Location
        }
    }

    $global:LASTEXITCODE = $childExitCode
}

Set-Alias -Name gsafe -Value grok-safe -Scope Global
