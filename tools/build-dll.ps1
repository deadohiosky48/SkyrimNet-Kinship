<#
    Builds the optional SKSE Menu Framework panel.

    Exists because the raw cmake invocation has three traps, two of which are
    PowerShell-specific and bit on first contact:

      1. cmake is NOT on PATH. Visual Studio bundles it under
         Common7/IDE/CommonExtensions/Microsoft/CMake, and only a *Developer*
         shell puts it on PATH. This finds it via vswhere instead of requiring
         one.
      2. %VCPKG_ROOT% is CMD syntax and expands to nothing in PowerShell, so
         the toolchain file silently resolves to a bare relative path and cmake
         reports something unrelated. PowerShell needs $env:VCPKG_ROOT.
      3. CommonLibSSE-NG must be cloned WITH SUBMODULES. Without --recursive it
         configures and then fails deep in a dependency with no obvious cause.

    -Setup fetches the prerequisites (vcpkg + CommonLibSSE-NG). Both are large
    downloads and are therefore opt-in rather than automatic.

    Usage:
        powershell -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Setup
        powershell -ExecutionPolicy Bypass -File "tools\build-dll.ps1"
        powershell -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Deploy
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Deploy,
    [string]$Config = 'Release',
    [string]$DeployDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'SKSE_Source'
$commonLib = Join-Path $src 'extern\CommonLibSSE-NG'

# --- locate Visual Studio's cmake ------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere not found. Install Visual Studio with the Desktop development with C++ workload."
}
$vsPath = & $vswhere -products * -latest -format value -property installationPath
if (-not $vsPath) { throw "No Visual Studio installation found." }

$cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (-not (Test-Path $cmake)) {
    # Fall back to a standalone install if the VS component was not selected.
    $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    if (-not $cmake) {
        throw "cmake.exe not found in $vsPath, and none on PATH. Add the 'C++ CMake tools for Windows' component."
    }
}
Write-Host "cmake : $cmake"
Write-Host "VS    : $vsPath"

# --- prerequisites ----------------------------------------------------------
if ($Setup) {
    if (-not $env:VCPKG_ROOT) {
        $vcpkgDir = Join-Path $repo '.tools\vcpkg'
        if (-not (Test-Path (Join-Path $vcpkgDir 'vcpkg.exe'))) {
            Write-Host "`nFetching vcpkg into $vcpkgDir ..."
            New-Item -ItemType Directory -Force -Path (Split-Path $vcpkgDir) | Out-Null
            if (-not (Test-Path $vcpkgDir)) {
                git clone --depth 1 https://github.com/microsoft/vcpkg $vcpkgDir
            }
            & (Join-Path $vcpkgDir 'bootstrap-vcpkg.bat') -disableMetrics
        }
        $env:VCPKG_ROOT = $vcpkgDir
        # Persist for future shells so this is a one-time cost.
        [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $vcpkgDir, 'User')
        Write-Host "VCPKG_ROOT set to $vcpkgDir (persisted for new shells)"
    }

    if (-not (Test-Path (Join-Path $commonLib 'CMakeLists.txt'))) {
        Write-Host "`nCloning CommonLibSSE-NG (large, with submodules)..."
        New-Item -ItemType Directory -Force -Path (Split-Path $commonLib) | Out-Null
        # --recursive is NOT optional; without it the build fails deep inside a
        # dependency rather than at configure time.
        git clone https://github.com/alandtse/CommonLibVR.git --branch ng --recursive $commonLib
    }
}

# Prefer the repo-local copy over the environment variable.
#
# SetEnvironmentVariable(..., 'User') only affects shells started AFTERWARDS, so
# a -Setup run followed immediately by a build in a fresh process still sees the
# old environment and would demand -Setup again in a loop. Looking for the
# directory we created is the fact; the variable is only a convenience.
$localVcpkg = Join-Path $repo '.tools\vcpkg'
if (Test-Path (Join-Path $localVcpkg 'vcpkg.exe')) {
    $env:VCPKG_ROOT = $localVcpkg
}
if (-not $env:VCPKG_ROOT) {
    throw "vcpkg not found. Run this script with -Setup first."
}
if (-not (Test-Path (Join-Path $commonLib 'CMakeLists.txt'))) {
    throw "CommonLibSSE-NG missing at $commonLib. Run this script with -Setup first."
}

# --- configure + build ------------------------------------------------------
$toolchain = Join-Path $env:VCPKG_ROOT 'scripts\buildsystems\vcpkg.cmake'
$build = Join-Path $src 'build'

$args = @(
    '-B', $build, '-S', $src,
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    '-DVCPKG_TARGET_TRIPLET=x64-windows-static'
)
if ($Deploy) { $args += "-DKINSHIP_DEPLOY_DIR=$DeployDir" }

Write-Host "`n--- configure ---"
& $cmake @args
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

Write-Host "`n--- build ---"
& $cmake --build $build --config $Config
if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

$dll = Get-ChildItem $build -Recurse -Filter 'SkyrimNetKinship.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dll) {
    Write-Host "`nBuilt: $($dll.FullName)" -ForegroundColor Green
    if ($Deploy) { Write-Host "Deployed to $DeployDir\SKSE\Plugins" -ForegroundColor Green }
} else {
    Write-Host "`nBuild reported success but no DLL found." -ForegroundColor Yellow
}
