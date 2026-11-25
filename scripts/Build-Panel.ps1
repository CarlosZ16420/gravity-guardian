[CmdletBinding()]
param([switch]$SkipSelfTest)
$ErrorActionPreference = 'Stop'

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskPanelSrc = Join-Path $taskRoot 'src/AgApproval.Panel'
$taskOutDir = Join-Path $taskRoot '.local/panel-build'
$taskBuildTemp = Join-Path $taskRoot '.local/build-temp'
New-Item -ItemType Directory -Path $taskOutDir, $taskBuildTemp -Force | Out-Null

# Locate MSVC BuildTools vcvars64.bat
$taskVcvarsCandidates = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat'
)
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $taskVswhere) {
    $taskVsPath = (& $taskVswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
    if ($taskVsPath) {
        $taskVcvarsCandidates = @((Join-Path $taskVsPath 'VC\Auxiliary\Build\vcvars64.bat')) + $taskVcvarsCandidates
    }
}
$taskVcvars = $taskVcvarsCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$taskVcvars) { throw 'Visual Studio 2022 x64 C++ BuildTools (vcvars64.bat) not found.' }

$taskExe = Join-Path $taskOutDir 'GravityGuardian.exe'
$taskRes = Join-Path $taskOutDir 'resource.res'
$taskRc = Join-Path $taskPanelSrc 'resource.rc'

$taskBatch = Join-Path $taskOutDir 'build-panel.cmd'
$taskSources = @(
    (Join-Path $taskPanelSrc 'main.cpp'),
    (Join-Path $taskPanelSrc 'util.cpp'),
    (Join-Path $taskPanelSrc 'updater.cpp')
)

# Keep the linked panel binary stable across builds with the same inputs and MSVC toolchain.
$taskCmdContent = @"
@echo off
setlocal
set "TMP=$taskBuildTemp"
set "TEMP=$taskBuildTemp"
call "$taskVcvars" >nul
if errorlevel 1 exit /b 1
rc /nologo /fo "$taskRes" "$taskRc"
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /O2 /MT /W4 /WX /EHsc /utf-8 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Fo"$taskOutDir\\" /Fe"$taskExe" "$($taskSources[0])" "$($taskSources[1])" "$($taskSources[2])" "$taskRes" /link /Brepro /SUBSYSTEM:WINDOWS /MANIFEST:NO user32.lib gdi32.lib gdiplus.lib comctl32.lib shell32.lib advapi32.lib ole32.lib comdlg32.lib winhttp.lib bcrypt.lib dwmapi.lib
if errorlevel 1 exit /b 1
dumpbin /nologo /dependents "$taskExe"
"@
[IO.File]::WriteAllText($taskBatch, $taskCmdContent, [Text.UTF8Encoding]::new($false))

$taskOut = & $env:ComSpec /d /c "`"$taskBatch`""
if ($LASTEXITCODE -ne 0) {
    $taskOut | ForEach-Object { Write-Host $_ }
    throw "Native Win32 panel compilation failed with exit code $LASTEXITCODE"
}

$taskOut | ForEach-Object { Write-Host $_ }

# Verify zero non-system DLL dependencies (no VCRUNTIME, no .NET, no WebView2).
$taskDeps = @($taskOut | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' })
$taskAllowed = @('KERNEL32.dll','USER32.dll','GDI32.dll','gdiplus.dll','COMCTL32.dll','SHELL32.dll','ADVAPI32.dll','OLE32.dll','COMDLG32.dll','WINHTTP.dll','bcrypt.dll','dwmapi.dll')
foreach ($dep in $taskDeps) {
    if ($taskAllowed -inotcontains $dep) {
        throw "Unexpected non-system DLL dependency in GravityGuardian.exe: $dep"
    }
}

$taskBytes = (Get-Item -LiteralPath $taskExe).Length
Write-Host ("Built native panel: $taskExe (" + [Math]::Round($taskBytes / 1KB, 1) + " KB)")

if (!$SkipSelfTest) {
    $taskSelfOut = & $taskExe --self-test | ForEach-Object { $_ }
    $taskSelfOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or !($taskSelfOut -join "`n").Contains('PASS Windows CNG BCrypt SHA-256')) {
        throw "Native panel self-test failed with exit code $LASTEXITCODE"
    }
}
