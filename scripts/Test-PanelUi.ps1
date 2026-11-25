[CmdletBinding()]
param([switch]$NoBuild, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
if (!$NoBuild) { & (Join-Path $PSScriptRoot 'Build-Panel.ps1') }
$taskBuildDir = Join-Path $taskRoot '.local/panel-build'
$taskTestDir = Join-Path $taskRoot '.local/panel-ui-tests'
New-Item -ItemType Directory -Path $taskTestDir -Force | Out-Null
$taskBuildBatch = [IO.File]::ReadAllLines((Join-Path $taskBuildDir 'build-panel.cmd'))
$taskVcvarsLine = $taskBuildBatch | Where-Object { $_.StartsWith('call "') } | Select-Object -First 1
if (!$taskVcvarsLine) { throw 'Build-Panel.ps1 must generate its compiler setup first.' }
$taskExe = Join-Path $taskTestDir 'PanelUiTests.exe'
$taskSource = Join-Path $taskRoot 'tests/AgApproval.Panel.UiTests.cpp'
$taskBatch = Join-Path $taskTestDir 'build-tests.cmd'
$taskCommands = @"
@echo off
setlocal
set "TMP=$taskTestDir"
set "TEMP=$taskTestDir"
$taskVcvarsLine
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /O2 /MT /W4 /WX /EHsc /utf-8 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Fo"$taskTestDir\\" /Fe"$taskExe" "$taskSource" "$taskBuildDir\util.obj" "$taskBuildDir\updater.obj" "$taskBuildDir\resource.res" /link /SUBSYSTEM:CONSOLE user32.lib gdi32.lib gdiplus.lib comctl32.lib shell32.lib advapi32.lib ole32.lib comdlg32.lib winhttp.lib bcrypt.lib dwmapi.lib
"@
[IO.File]::WriteAllText($taskBatch, $taskCommands, [Text.UTF8Encoding]::new($false))
& $env:ComSpec /d /c "`"$taskBatch`""
if ($LASTEXITCODE -ne 0) { throw 'Panel UI test compilation failed.' }
if ($Interactive) { & $taskExe --interactive } else { & $taskExe }
if ($LASTEXITCODE -ne 0) { throw 'Panel UI regression tests failed.' }
