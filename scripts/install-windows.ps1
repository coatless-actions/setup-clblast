<#
.SYNOPSIS
    Install CLBlast from its upstream Windows release archive, then print the
    resulting paths as key=value lines.

.DESCRIPTION
    Upstream publishes a prebuilt CLBlast-<version>-windows-x64 archive whose
    clblast.dll imports only OpenCL.dll and KERNEL32.dll -- the MSVC CRT is
    statically linked -- so only bin\ needs to reach PATH. lib\clblast.lib is
    a COFF short-import library exposing undecorated CLBlastSgemm alongside
    __imp_CLBlastSgemm; GNU ld's PE search order for -lxxx includes xxx.lib,
    which is why mingw and Rtools link it with a bare -lclblast.

    The archive extension is NOT stable across releases: 1.7.0, 1.6.3 and
    1.6.0 are .7z; 1.6.2 and 1.6.1 are .zip; 1.5.x are Windows-x64.zip with a
    capital W. The asset name is therefore resolved from the GitHub Releases
    API rather than templated, exactly as setup-opencl resolves the oclcpuexp
    asset. Extraction uses 7z, which is preinstalled on the runner images --
    Expand-Archive cannot read .7z at all.

    Every archive is verified against a SHA-256 digest before extraction, and
    a download with nothing to verify against is refused rather than
    installed. The GitHub API reports a 'digest' field for CLBlast 1.7.0 and
    for nothing older, so $KnownDigests carries values computed out of band
    for the versions this action supports beyond the newest. Adding a version
    means adding a row here deliberately; there is no fallback that skips the
    check.

    The upstream lib\cmake\CLBlast\CLBlastConfig.cmake is broken as shipped:
    it bakes the build machine's vcpkg tree into INTERFACE_INCLUDE_DIRECTORIES
    and INTERFACE_LINK_LIBRARIES ("C:/vcpkg/packages/opencl_x64-windows/..."),
    paths that do not exist on a runner, so find_package(CLBlast) imports a
    target that fails at link time. Those two lines are rewritten to point at
    the loader setup-opencl installed. The rewrite is fail-closed: if either
    line is absent, CLBlast_DIR is not emitted and a warning names the
    version, rather than exporting a config known to be wrong.

    A pristine copy of the shipped file (CLBlastConfig.cmake.orig) is saved
    the first time the tree is extracted, and every rewrite reads from that
    copy rather than from CLBlastConfig.cmake itself. The tree this runs
    against is frequently a cache hit, not a fresh extraction: without the
    pristine copy, a run against a tree an earlier run already rewrote (or
    already stubbed, on the OpenCL_INCLUDE_DIR/OpenCL_LIBRARY-unset path)
    would find nothing left to match -- the vcpkg text is gone either way --
    and mis-declare the config unusable. Reading from the untouched copy
    every time makes the rewrite idempotent no matter how many times it runs
    against the same cached tree.
#>

[CmdletBinding()]
param(
    [string] $Source     = $env:SC_SOURCE,
    [string] $Version    = $env:SC_VERSION,
    [string] $InstallDir = "$env:RUNNER_TEMP\clblast"
)

$ErrorActionPreference = 'Stop'

$DefaultVersion = '1.7.0'

# SHA-256 digests computed out of band by downloading each asset and running
# 'shasum -a 256'. The GitHub API reports a digest for 1.7.0 only; every
# older asset predates the field.
$KnownDigests = @{
    '1.7.0' = 'fd41418c7689dcf1d2a52f2b3b2394772aac0a864ee613cabe881151eec7c61b'
    '1.6.3' = '8168d9f2b557259b4b32acd5b0fe743a55573bec5ee5b52f2928c01277beef92'
}

if (-not $Version) { $Version = $DefaultVersion }
if (-not $Source)  { $Source  = 'package' }

function Emit([string] $Key, [string] $Value) {
    Write-Output "$Key=$Value"
}

function Fail([string] $Message, [string] $Remediation) {
    Write-Output "::error::$Message"
    Write-Output $Remediation
    exit 1
}

# Fails the run when a downloaded archive does not match its expected digest.
# This is the last line of defense before the archive is trusted: its .lib
# ends up on the link line and its .dll on PATH.
function Assert-FileHash([string] $Path, [string] $Expected, [string] $Label) {
    $actual   = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $Expected.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -Force $Path -ErrorAction SilentlyContinue
        Fail "SHA-256 mismatch for ${Label}: expected $expected, got $actual" `
             "The downloaded file does not match its expected digest. This can mean the download was corrupted or intercepted in transit, or that upstream replaced the asset in place without changing its tag. Do not trust this file. If upstream genuinely republished the asset, verify the new digest out of band before updating the table in install-windows.ps1."
    }
}

# Resolves the Windows asset's name, download URL, and SHA-256 for a given
# CLBlast tag. Digest resolution order is deliberate: the hardcoded table
# first (a true pin, fixed ahead of time and independent of the download),
# then the GitHub API's own digest field (a transport check -- it catches
# corruption between the API call and the download, not authenticity against
# a value fixed in advance), then failure.
function Resolve-Asset([string] $Tag) {
    $headers = @{ 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    $apiUrl = "https://api.github.com/repos/CNugteren/CLBlast/releases/tags/$Tag"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    } catch {
        Fail "CNugteren/CLBlast has no release tagged '$Tag' (or the GitHub API request failed: $($_.Exception.Message))" `
             "CLBlast tags carry no 'v' prefix -- use '1.7.0', not 'v1.7.0'. Check https://github.com/CNugteren/CLBlast/releases for a valid tag."
    }

    $asset = $release.assets |
             Where-Object { $_.name -like '*indows-x64*' -and ($_.name -like '*.7z' -or $_.name -like '*.zip') } |
             Select-Object -First 1
    if (-not $asset) {
        Fail "CLBlast release '$Tag' has no Windows x64 archive asset" `
             "Check the assets listed at https://github.com/CNugteren/CLBlast/releases/tag/$Tag. Releases before 1.5.0 may not publish one at all."
    }

    $sha256 = $KnownDigests[$Tag]
    if (-not $sha256) {
        if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
            $sha256 = $Matches[1]
        } else {
            Fail "CLBlast release '$Tag' asset '$($asset.name)' has no SHA-256 digest, from the GitHub API or from this action's table" `
                 "There is nothing to verify this download against, so it is refused rather than installed unverified. Use the default version ($DefaultVersion), use a version listed in `$KnownDigests in scripts/install-windows.ps1, or add its digest there after verifying it out of band."
        }
    }

    return [PSCustomObject]@{
        Name   = $asset.name
        Url    = $asset.browser_download_url
        Sha256 = $sha256
    }
}

if ($Source -ne 'package') {
    Fail "source '$Source' is not available on Windows" `
         "Upstream already publishes a Windows binary for the newest release. Use 'source: package', or leave 'source' as 'auto'."
}

$resolved = Resolve-Asset -Tag $Version
Write-Host "Resolved CLBlast release: tag=$Version asset=$($resolved.Name)"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$treeDir = Join-Path $InstallDir 'tree'

# Complete-tree gate. Every file below is one a consumer reaches for: the C
# header, the import library -lclblast resolves, the DLL that must be on
# PATH, and the CMake package config. A tree missing any one of them is not a
# cache hit and must be re-extracted. This runs BEFORE the download decision,
# not after, so one code path decides both.
function Test-TreeComplete([string] $Dir) {
    (Test-Path (Join-Path $Dir 'include\clblast_c.h')) -and
    (Test-Path (Join-Path $Dir 'lib\clblast.lib')) -and
    (Test-Path (Join-Path $Dir 'bin\clblast.dll')) -and
    (Test-Path (Join-Path $Dir 'lib\cmake\CLBlast\CLBlastConfig.cmake'))
}

if (-not (Test-TreeComplete $treeDir)) {
    $archive = Join-Path $InstallDir $resolved.Name
    Invoke-WebRequest -Uri $resolved.Url -OutFile $archive
    Assert-FileHash -Path $archive -Expected $resolved.Sha256 -Label "CLBlast archive ($Version)"

    $stage = Join-Path $InstallDir 'stage'
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # 7z, not Expand-Archive: the newest assets are .7z, which
    # Expand-Archive cannot read. 7-Zip is preinstalled on windows-2022 and
    # windows-2025, and handles .zip as well, so one tool covers every asset
    # extension upstream has ever shipped.
    & 7z x $archive "-o$stage" -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "7z failed to extract '$($resolved.Name)' (exit $LASTEXITCODE)" `
             "The archive may be corrupt despite matching its digest, or 7z may be missing from this image. Check https://github.com/actions/runner-images for the image's tool list."
    }
    Remove-Item -Force $archive

    $extracted = Get-ChildItem -Path $stage -Directory |
                 Where-Object { $_.Name -like 'CLBlast-*' } |
                 Select-Object -First 1
    if (-not $extracted) {
        Fail "CLBlast archive did not contain the expected top-level directory" `
             "The archive layout may have changed for release $Version. Check https://github.com/CNugteren/CLBlast/releases/tag/$Version."
    }

    if (Test-Path $treeDir) { Remove-Item -Recurse -Force $treeDir }
    Move-Item -Path $extracted.FullName -Destination $treeDir
    Remove-Item -Recurse -Force $stage

    # Re-run the same gate used for the cache-hit decision. Without this, a
    # layout drift that drops one required file would not fail loudly -- it
    # would make every future run look like a cache miss forever, silently
    # re-downloading on every run with no error.
    if (-not (Test-TreeComplete $treeDir)) {
        Fail "Extracted CLBlast tree at '$treeDir' is missing one of: include\clblast_c.h, lib\clblast.lib, bin\clblast.dll, lib\cmake\CLBlast\CLBlastConfig.cmake" `
             "The archive layout may have changed for release $Version. Check https://github.com/CNugteren/CLBlast/releases/tag/$Version."
    }
}

# ---------- repair the shipped CMake package config ----------

$cmakeDir    = Join-Path $treeDir 'lib\cmake\CLBlast'
$cmakeConfig = Join-Path $cmakeDir 'CLBlastConfig.cmake'
$cmakeOrig   = Join-Path $cmakeDir 'CLBlastConfig.cmake.orig'
$cmakeUsable = $false

# Saved once, from whatever is on disk the first time this runs against a
# given tree, and never touched again. Every rewrite below reads from this
# copy instead of from CLBlastConfig.cmake, so re-running this script
# against an already-repaired or already-stubbed tree (a cache hit, or a
# second invocation in the same job) still has the original vcpkg text to
# match against, rather than reading back its own previous output -- or a
# previous FATAL_ERROR stub -- and matching nothing. This is a no-op after
# the first run against a given tree.
if (-not (Test-Path $cmakeOrig)) {
    Copy-Item -Path $cmakeConfig -Destination $cmakeOrig
}

$loaderInclude = $env:OpenCL_INCLUDE_DIR
$loaderLibrary = $env:OpenCL_LIBRARY

# CMake's find_package(CLBlast) auto-recognizes a CLBlast_ROOT environment
# variable as a search hint (CMP0074), and this action exports CLBlast_ROOT
# unconditionally for callers who never touch CMake at all. Withholding
# CLBlast_DIR alone therefore is not enough: find_package(CLBlast) would
# still walk in through CLBlast_ROOT and load the very file being withheld.
# The only way to make the fail-closed guarantee hold regardless of which
# hint CMake was pointed at is to make the file itself refuse to load.
function Disable-CMakeConfig([string] $Reason) {
    $stub = 'message(FATAL_ERROR "setup-clblast could not safely repair CLBlastConfig.cmake for CLBlast ' +
            $Version + ': ' + $Reason +
            '. Use the CLBLAST_CPPFLAGS and CLBLAST_LIBS environment variables instead of find_package(CLBlast) in this job.")'
    Set-Content -Path $cmakeConfig -Value $stub -NoNewline
}

if ($loaderInclude -and $loaderLibrary) {
    $content = Get-Content -Raw -Path $cmakeOrig
    $incFwd = $loaderInclude -replace '\\', '/'
    $libFwd = $loaderLibrary -replace '\\', '/'

    $patched = $content `
        -replace 'INTERFACE_INCLUDE_DIRECTORIES "\$\{_IMPORT_PREFIX\}/include;[^"]*"', `
                 "INTERFACE_INCLUDE_DIRECTORIES `"`${_IMPORT_PREFIX}/include;$incFwd`"" `
        -replace 'INTERFACE_LINK_LIBRARIES "[^"]*"', `
                 "INTERFACE_LINK_LIBRARIES `"$libFwd`""

    if ($patched -match [regex]::Escape($incFwd) -and $patched -match [regex]::Escape($libFwd)) {
        Set-Content -Path $cmakeConfig -Value $patched -NoNewline
        $cmakeUsable = $true
    } else {
        Write-Output "::warning::Could not rewrite the vcpkg paths baked into CLBlastConfig.cmake for CLBlast $Version, so CLBlast_DIR is not being exported. find_package(CLBlast) would import a target pointing at C:/vcpkg paths that do not exist on this runner. Use CLBLAST_CPPFLAGS and CLBLAST_LIBS instead."
        Disable-CMakeConfig 'the vcpkg paths were not both found in the two properties this rewrite targets (CLBlast 1.6.3, for example, moves the OpenCL library path into IMPORTED_LINK_INTERFACE_LIBRARIES_RELEASE in a companion file instead)'
    }
} else {
    Write-Output "::warning::OpenCL_INCLUDE_DIR or OpenCL_LIBRARY is not set, so the vcpkg paths baked into CLBlastConfig.cmake could not be rewritten and CLBlast_DIR is not being exported. Run setup-opencl before this action."
    Disable-CMakeConfig 'OpenCL_INCLUDE_DIR or OpenCL_LIBRARY was not set in the job environment when this ran'
}

# ---------- emit ----------

# Forward slashes throughout: shell consumers such as RcppBandicoot's
# configure.win read CLBLAST_CPPFLAGS and CLBLAST_LIBS directly, and a
# backslash would be eaten as an escape.
$treeFwd    = $treeDir -replace '\\', '/'
$includeFwd = (Join-Path $treeDir 'include') -replace '\\', '/'
$libFwd     = (Join-Path $treeDir 'lib') -replace '\\', '/'

Emit 'clblast-root'        $treeFwd
Emit 'clblast-include-dir' $includeFwd
Emit 'clblast-library'     ((Join-Path $treeDir 'lib\clblast.lib') -replace '\\', '/')
Emit 'clblast-cppflags'    "-I$includeFwd"
Emit 'clblast-libs'        "-L$libFwd -lclblast"
Emit 'clblast-bin-dir'     (Join-Path $treeDir 'bin')
Emit 'clblast-version'     $Version
Emit 'source-used'         'package'

if ($cmakeUsable) {
    Emit 'clblast-cmake-dir' ($cmakeDir -replace '\\', '/')
} else {
    Emit 'clblast-cmake-dir' ''
}
