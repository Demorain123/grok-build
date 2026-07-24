[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$CacheRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    Write-Host 'Windows protoc bootstrap skipped on non-Windows host.'
    return
}

if (-not $RepoRoot) {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
} else {
    $RepoRoot = Resolve-Path $RepoRoot
}
if (-not $CacheRoot) {
    $CacheRoot = Join-Path $RepoRoot 'grok-safe\.cache\protoc'
}

$dotSlashProtoc = Join-Path $RepoRoot 'bin\protoc'
if (-not (Test-Path -LiteralPath $dotSlashProtoc -PathType Leaf)) {
    throw "Upstream bin/protoc was not found: $dotSlashProtoc"
}

# Keep this Windows bootstrap coupled to the exact protoc version selected by
# upstream's DotSlash manifest. If upstream changes protoc, fail closed and
# require an explicit checksum review instead of silently downloading a new tool.
$manifestText = Get-Content -Raw -LiteralPath $dotSlashProtoc
$versionMatches = [regex]::Matches(
    $manifestText,
    'protocolbuffers/protobuf/releases/download/v(?<version>[0-9]+\.[0-9]+)/protoc-(?<assetVersion>[0-9]+\.[0-9]+)-'
)
$manifestVersions = @(
    $versionMatches |
        ForEach-Object { $_.Groups['version'].Value } |
        Sort-Object -Unique
)
if ($manifestVersions.Count -ne 1) {
    throw "Could not resolve one upstream protoc version from bin/protoc; found: $($manifestVersions -join ', ')"
}

$PinnedVersion = '29.3'
$PinnedWin64ZipSha256 = '57ea59e9f551ad8d71ffaa9b5cfbe0ca1f4e720972a1db7ec2d12ab44bff9383'
$upstreamVersion = $manifestVersions[0]
if ($upstreamVersion -ne $PinnedVersion) {
    throw "Upstream protoc changed from reviewed v$PinnedVersion to v$upstreamVersion. Review the new official Windows asset and update its pinned SHA256 before building."
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($arch -ne 'X64') {
    throw "grok-safe Windows protoc bootstrap currently supports x86_64 only; detected architecture: $arch"
}

New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
$assetName = "protoc-$PinnedVersion-win64.zip"
$assetUrl = "https://github.com/protocolbuffers/protobuf/releases/download/v$PinnedVersion/$assetName"
$zipPath = Join-Path $CacheRoot $assetName
$extractRoot = Join-Path $CacheRoot "protoc-$PinnedVersion-win64"

function Test-VerifiedZip([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    return $actual -eq $PinnedWin64ZipSha256
}

if (-not (Test-VerifiedZip $zipPath)) {
    Remove-Item -Force -LiteralPath $zipPath -ErrorAction SilentlyContinue
    $partial = "$zipPath.part-$PID"
    Remove-Item -Force -LiteralPath $partial -ErrorAction SilentlyContinue
    try {
        Write-Host "Downloading upstream-matched protoc v$PinnedVersion for Windows x64..."
        Invoke-WebRequest -Uri $assetUrl -OutFile $partial
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash.ToLowerInvariant()
        if ($actual -ne $PinnedWin64ZipSha256) {
            throw "Downloaded protoc archive SHA256 mismatch. Expected $PinnedWin64ZipSha256, got $actual"
        }
        Move-Item -Force -LiteralPath $partial -Destination $zipPath
    }
    finally {
        Remove-Item -Force -LiteralPath $partial -ErrorAction SilentlyContinue
    }
}

# Re-extract from the verified archive for every build. This avoids trusting a
# stale or modified cached protoc.exe while keeping the network download cached.
if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -Recurse -Force -LiteralPath $extractRoot
}
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

$protocExe = Join-Path $extractRoot 'bin\protoc.exe'
$includeDir = Join-Path $extractRoot 'include'
if (-not (Test-Path -LiteralPath $protocExe -PathType Leaf)) {
    throw "Verified protoc archive did not contain expected executable: $protocExe"
}
if (-not (Test-Path -LiteralPath $includeDir -PathType Container)) {
    throw "Verified protoc archive did not contain expected include directory: $includeDir"
}

$versionOutput = (& $protocExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch ([regex]::Escape($PinnedVersion))) {
    throw "Prepared protoc failed version verification: $versionOutput"
}

$env:PROTOC = $protocExe
$env:GROK_SAFE_PROTOC_VERSION = $PinnedVersion
if ($env:GITHUB_ENV) {
    "PROTOC=$protocExe" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "GROK_SAFE_PROTOC_VERSION=$PinnedVersion" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Host "Windows protoc ready: $protocExe"
Write-Host "Version: $versionOutput"
Write-Host "Archive SHA256: $PinnedWin64ZipSha256"
