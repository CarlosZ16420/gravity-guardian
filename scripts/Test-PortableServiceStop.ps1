[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ge 6) {
    & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell portable stop regression failed' }
    return
}
. (Join-Path $PSScriptRoot 'Portable.ps1')
$portableStopFixture=Join-Path (Split-Path $PSScriptRoot -Parent) ('.local/portable-stop-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $portableStopFixture -Force | Out-Null
$portableStopRuntime=Join-Path $portableStopFixture 'status.cmd'
[IO.File]::WriteAllText($portableStopRuntime,"@echo off`r`necho OperationCanceledException: The operation was canceled. 1>&2`r`nexit /b 1`r`n")
$portableStopLayout=@{app=$portableStopFixture;config=(Join-Path $portableStopFixture 'approval.json');data=(Join-Path $portableStopFixture 'data')}
[IO.File]::WriteAllText($portableStopLayout.config,'{}')
$portableStopMatching=$false
$portableStopQueryFailure=$false
$portableStopQueries=0
function Resolve-ApprovalRuntime { param($PluginDirectory,[switch]$Installed) return $portableStopRuntime }
function Start-Sleep { param($Milliseconds) }
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)
    $script:portableStopQueries++
    if ($portableStopQueryFailure) { throw 'Injected process query failure' }
    if ($portableStopMatching) {
        @{ExecutablePath=$portableStopRuntime;CommandLine=('"'+(Join-Path $portableStopFixture 'scripts/gravity-guardian.dll')+'" host --config "'+$portableStopLayout.config+'"')}
    }
}
Stop-PortableService $portableStopLayout
if ($portableStopQueries -ne 1 -or !(Test-Path -LiteralPath (Join-Path $portableStopLayout.data 'uninstalled')) -or $ErrorActionPreference -ne 'Stop') { throw 'Stopped service did not reach process confirmation' }
$portableStopMatching=$true
try { Stop-PortableService $portableStopLayout; throw 'Expected live-process refusal' }
catch { if ($_.Exception.Message -notlike '*Cannot confirm approval service state*') { throw } }
$portableStopMatching=$false
$portableStopQueryFailure=$true
try { Stop-PortableService $portableStopLayout; throw 'Expected process-query refusal' }
catch { if ($_.Exception.Message -notlike '*Injected process query failure*') { throw } }
Write-Host 'PASS Windows PowerShell native stderr reaches stopped-process confirmation; live or unknown processes abort switching'
$global:LASTEXITCODE=0
