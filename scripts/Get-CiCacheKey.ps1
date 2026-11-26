[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Release-Paths.ps1')
$taskCompiler=(& rustc +stable --version --verbose) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify Rust compiler' }
$taskVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$taskVs= & $taskVswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$taskVs) { throw 'Cannot identify MSVC' }
$taskCl=Get-ChildItem -LiteralPath (Join-Path $taskVs 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$taskPin=Get-Content -LiteralPath (Join-Path $taskRoot 'native/SOURCE.json') -Raw | ConvertFrom-Json
$taskEnvironment=(Get-ReleasePathSettings $taskRoot).environment
$taskFlagIdentity=($taskEnvironment.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Key+'='+$_.Value }) -join "`n"
$taskFlagIdentity+=(Get-ChildItem Env: | Where-Object Name -match '^(RUST.*|CARGO_(PROFILE_.*|BUILD_.*|TARGET_.*)|CC.*|CXX.*|CFLAGS.*|CXXFLAGS.*|V8_FROM_SOURCE)$' | Sort-Object Name | ForEach-Object { $_.Name+'='+$_.Value }) -join "`n"
$taskIdentity=$taskCompiler+'|'+$taskCl.Name+'|'+$env:ImageOS+'|'+$env:ImageVersion+'|'+$taskPin.commit+'|'+$taskPin.v8Commit+'|'+($taskPin.releaseOptions | ConvertTo-Json -Compress)+'|'+$taskFlagIdentity
function Hash-Bytes([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
$taskBase='guardian-v1-windows-x64-'+(Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($taskIdentity))).Substring(0,20)
$taskFiles=@(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'native/guardian-host/src'),(Join-Path $taskRoot 'native/guardian-host/tests') -Filter *.rs -File -Recurse)
$taskFiles+=@('native/SOURCE.json','native/guardian-host/Cargo.toml','native/patches/guardian-entry.patch','scripts/Build-Guardian.ps1','scripts/Release-Paths.ps1','scripts/Test-NativePrompt.mjs','policy/upstream-codex/SOURCE.json','scripts/dotnet-runtime.lock.json') | ForEach-Object { Get-Item -LiteralPath (Join-Path $taskRoot $_) }
$taskInput=($taskFiles | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($taskRoot,$_.FullName)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
[pscustomobject]@{key=$taskBase+'-'+(Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($taskInput)));restorePrefix=$taskBase+'-'}
