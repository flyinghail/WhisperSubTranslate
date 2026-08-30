param(
  [string]$WhisperVersion = '',
  [string]$OutputDir = '',
  [switch]$KeepBuild,
  [switch]$SkipRuntimeProbe
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $WhisperVersion) {
  $packageJson = Get-Content (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
  $WhisperVersion = $packageJson.whisperCppVersion
}
if ($WhisperVersion -notmatch '^v\d+\.\d+\.\d+$') {
  throw "Invalid whisper.cpp version in package.json: $WhisperVersion"
}
if (-not $OutputDir) {
  $OutputDir = Join-Path $repoRoot 'whisper-cpp\vulkan'
}
$buildParent = if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  $repoRoot
}
# The vulkan-shaders-gen ExternalProject creates deeply nested CMake scratch
# paths. Keep the CI root deliberately short to avoid MSVC FileTracker
# FTK1011 failures when its .tlog paths exceed the Windows tooling limit.
$buildRoot = Join-Path $buildParent ('wvk-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$normalizedBuildParent = [IO.Path]::GetFullPath($buildParent).TrimEnd('\')
$normalizedBuildRoot = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\')
if (-not $normalizedBuildRoot.StartsWith("$normalizedBuildParent\", [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to use a build directory outside its expected parent: $normalizedBuildRoot"
}
$manifest = Get-Content (Join-Path $repoRoot 'scripts\whisper-runtime.json') -Raw | ConvertFrom-Json
if ($manifest.version -ne $WhisperVersion -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') {
  throw 'The engine version and pinned source manifest must be updated together.'
}
$sourceDir = Join-Path $buildRoot 'source'
$cmakeBuildDir = Join-Path $sourceDir 'build'
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$stageDir = Join-Path $buildRoot 'runtime'
$backupDir = "$OutputDir.previous-$PID"
$outputParent = [IO.Path]::GetFullPath((Split-Path -Parent $OutputDir)).TrimEnd('\')
if (-not [IO.Path]::GetFullPath($backupDir).StartsWith("$outputParent\", [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Refusing to use a backup outside the runtime parent directory.'
}
$hadBackup = $false

if ($env:OS -ne 'Windows_NT') {
  throw 'This helper currently builds the Windows x64 Vulkan runtime only.'
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git is required to build whisper.cpp.'
}
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
  throw 'CMake is required. Install CMake and make sure cmake.exe is on PATH.'
}
if (-not $env:VULKAN_SDK) {
  throw 'VULKAN_SDK is not set. Install the LunarG Vulkan SDK, then open a new terminal.'
}
$glslc = Join-Path $env:VULKAN_SDK 'Bin\glslc.exe'
if (-not (Test-Path -LiteralPath $glslc)) {
  throw "glslc.exe was not found at $glslc. Repair or reinstall the Vulkan SDK."
}

try {
  if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

  Write-Host "Cloning whisper.cpp $WhisperVersion..."
  & git clone --depth 1 --branch $WhisperVersion https://github.com/ggml-org/whisper.cpp.git $sourceDir
  if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }

  $actualCommit = (& git -C $sourceDir rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $manifest.sourceCommit) {
    throw "Source commit does not match pinned manifest: $actualCommit"
  }

  Write-Host 'Configuring Vulkan backend...'
  & cmake -S $sourceDir -B $cmakeBuildDir `
    -DGGML_VULKAN=ON `
    -DGGML_NATIVE=OFF `
    -DBUILD_SHARED_LIBS=ON
  if ($LASTEXITCODE -ne 0) {
    throw "cmake configure failed with exit code $LASTEXITCODE"
  }

  Write-Host 'Building whisper.cpp Vulkan runtime...'
  & cmake --build $cmakeBuildDir --config Release --parallel
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }

  $cli = Get-ChildItem -LiteralPath $cmakeBuildDir -Recurse -Filter whisper-cli.exe |
    Where-Object { $_.FullName -match '[\\/]bin[\\/]' } |
    Select-Object -First 1
  if (-not $cli) {
    throw 'Build succeeded, but whisper-cli.exe was not found.'
  }

  New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
  Copy-Item -LiteralPath $cli.FullName -Destination (Join-Path $stageDir 'whisper-cli.exe') -Force

  $dlls = Get-ChildItem -LiteralPath $cmakeBuildDir -Recurse -Filter *.dll
  foreach ($dll in $dlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $stageDir $dll.Name) -Force
  }

  if (-not $SkipRuntimeProbe) {
    $installedCli = Join-Path $stageDir 'whisper-cli.exe'
    # whisper/ggml reports normal backend discovery on stderr. With the script's
    # ErrorActionPreference=Stop, PowerShell otherwise converts that output into
    # NativeCommandError even when whisper-cli exits successfully.
    $previousErrorAction = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & $installedCli --help *> $null
      $probeExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorAction
    }
    if ($probeExit -ne 0) {
      throw "The staged Vulkan runtime failed its --help probe with exit code $probeExit."
    }
  } else {
    Write-Host 'Skipping runtime probe (CI runner has no Vulkan GPU).'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $stageDir 'whisper.dll'))) {
    throw 'The staged runtime is missing whisper.dll.'
  }

  Get-ChildItem -LiteralPath $stageDir -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object Name |
    ForEach-Object {
      $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      "$hash  $($_.Name)"
    } | Set-Content (Join-Path $stageDir 'SHA256SUMS.txt')

  $required = @('whisper-cli.exe', 'whisper.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll', 'ggml-vulkan.dll')
  foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageDir $file))) { throw "Missing runtime file: $file" }
  }
  @{ version = $WhisperVersion; sourceCommit = $actualCommit } | ConvertTo-Json |
    Set-Content (Join-Path $stageDir 'build-info.json')
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputDir) -Force | Out-Null
  if (Test-Path -LiteralPath $backupDir) { throw "Backup already exists: $backupDir" }
  if (Test-Path -LiteralPath $OutputDir) {
    Move-Item -LiteralPath $OutputDir -Destination $backupDir
    $hadBackup = $true
  }
  try {
    Move-Item -LiteralPath $stageDir -Destination $OutputDir
  } catch {
    if ($hadBackup) { Move-Item -LiteralPath $backupDir -Destination $OutputDir; $hadBackup = $false }
    throw
  }
  if ($hadBackup) {
    Remove-Item -LiteralPath $backupDir -Recurse -Force
    $hadBackup = $false
  }
  Write-Host "Vulkan runtime staged at $OutputDir"
  Write-Host "Copied $($dlls.Count) runtime DLL(s)."
} finally {
  if (-not $KeepBuild -and (Test-Path -LiteralPath $buildRoot)) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
  }
}
