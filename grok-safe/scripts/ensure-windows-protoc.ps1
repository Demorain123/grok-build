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

$realProtocExe = Join-Path $extractRoot 'bin\protoc.exe'
$includeDir = Join-Path $extractRoot 'include'
if (-not (Test-Path -LiteralPath $realProtocExe -PathType Leaf)) {
    throw "Verified protoc archive did not contain expected executable: $realProtocExe"
}
if (-not (Test-Path -LiteralPath $includeDir -PathType Container)) {
    throw "Verified protoc archive did not contain expected include directory: $includeDir"
}

$realVersionOutput = (& $realProtocExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $realVersionOutput -notmatch ([regex]::Escape($PinnedVersion))) {
    throw "Prepared protoc failed version verification: $realVersionOutput"
}

# Upstream xai-proto-build currently probes dependencies with Linux-only
# --dependency_out=/dev/stdout and --descriptor_set_out=/dev/null. Windows
# protoc.exe correctly rejects those paths. Keep that compatibility fix in the
# build wrapper rather than adding another Grok source patch: compile a tiny
# adapter that translates only those two probe arguments to temporary Windows
# files, prints the dependency file back to stdout in the shape upstream expects,
# and forwards every ordinary protoc invocation unchanged.
$adapterSource = Join-Path $CacheRoot 'protoc-windows-adapter.rs'
$adapterExe = Join-Path $extractRoot 'bin\protoc-grok-safe-adapter.exe'
$adapterRust = @'
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::time::{SystemTime, UNIX_EPOCH};

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code as u8),
        Err(err) => {
            eprintln!("grok-safe protoc adapter: {err}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<i32, Box<dyn std::error::Error>> {
    let real = env::var_os("GROK_SAFE_REAL_PROTOC")
        .ok_or("GROK_SAFE_REAL_PROTOC is not set")?;
    let args: Vec<String> = env::args().skip(1).collect();

    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let base = format!("grok-safe-protoc-{}-{nonce}", std::process::id());
    let temp: PathBuf = env::temp_dir();
    let dep_path = temp.join(format!("{base}.d"));
    let desc_path = temp.join(format!("{base}.pb"));

    let mut dependency_probe = false;
    let mut descriptor_probe = false;
    let mut forwarded = Vec::with_capacity(args.len());
    for arg in &args {
        if arg == "--dependency_out=/dev/stdout" {
            dependency_probe = true;
            forwarded.push(format!("--dependency_out={}", dep_path.display()));
        } else if arg == "--descriptor_set_out=/dev/null" {
            descriptor_probe = true;
            forwarded.push(format!("--descriptor_set_out={}", desc_path.display()));
        } else {
            forwarded.push(arg.clone());
        }
    }

    let output = Command::new(&real).args(&forwarded).output()?;
    io::stdout().write_all(&output.stdout)?;
    io::stderr().write_all(&output.stderr)?;

    if !output.status.success() {
        cleanup(&dep_path, &desc_path);
        return Ok(output.status.code().unwrap_or(1));
    }

    if dependency_probe {
        let dep = fs::read_to_string(&dep_path)?;
        // protoc's Makefile dependency output is `<target>: <deps>`. On Windows
        // the target itself contains the drive-letter colon, so skip that first
        // colon and rewrite the actual target separator to `/dev/null:` because
        // xai-proto-build validates that exact synthetic target name.
        let mut seen_drive_colon = false;
        let mut target_sep = None;
        for (idx, ch) in dep.char_indices() {
            if ch != ':' { continue; }
            if !seen_drive_colon {
                seen_drive_colon = true;
                continue;
            }
            target_sep = Some(idx);
            break;
        }
        let sep = target_sep.ok_or("unexpected protoc dependency output: target separator not found")?;
        print!("/dev/null{}", &dep[sep..]);
        io::stdout().flush()?;
    }

    if descriptor_probe && !desc_path.exists() {
        cleanup(&dep_path, &desc_path);
        return Err("protoc dependency probe did not create descriptor output".into());
    }

    cleanup(&dep_path, &desc_path);
    Ok(0)
}

fn cleanup(dep: &PathBuf, desc: &PathBuf) {
    let _ = fs::remove_file(dep);
    let _ = fs::remove_file(desc);
}
'@
Set-Content -LiteralPath $adapterSource -Value $adapterRust -Encoding utf8

Write-Host 'Compiling Windows protoc compatibility adapter...'
& rustc --edition=2021 -O $adapterSource -o $adapterExe
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $adapterExe -PathType Leaf)) {
    throw 'Failed to compile Windows protoc compatibility adapter.'
}

$env:GROK_SAFE_REAL_PROTOC = $realProtocExe
$adapterVersionOutput = (& $adapterExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $adapterVersionOutput -notmatch ([regex]::Escape($PinnedVersion))) {
    throw "Windows protoc adapter failed version verification: $adapterVersionOutput"
}

$env:PROTOC = $adapterExe
$env:GROK_SAFE_PROTOC_VERSION = $PinnedVersion
if ($env:GITHUB_ENV) {
    "GROK_SAFE_REAL_PROTOC=$realProtocExe" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "PROTOC=$adapterExe" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "GROK_SAFE_PROTOC_VERSION=$PinnedVersion" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Host "Windows protoc ready: $adapterExe"
Write-Host "Underlying protoc: $realProtocExe"
Write-Host "Version: $adapterVersionOutput"
Write-Host "Archive SHA256: $PinnedWin64ZipSha256"
