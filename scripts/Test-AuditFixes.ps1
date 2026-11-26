[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$auditRoot=Split-Path $PSScriptRoot -Parent
$auditScratch=Join-Path $auditRoot ('.local/af-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$auditScripts=Join-Path $auditScratch 'scripts'
New-Item -ItemType Directory -Path $auditScripts -Force|Out-Null
foreach($name in @('Install.ps1','Review-Mode.ps1','Portable.ps1','Uninstall.ps1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $auditScripts}
$auditInstall=Join-Path $auditScripts 'Install.ps1'
# Inject only into the isolated script copy, after review-mode writes and before manifest creation.
$auditSource=[IO.File]::ReadAllText($auditInstall)
$auditInjection=@'
if ($env:AG_AUDIT_FAILURE -eq 'throw') {
    $auditEdited=Read-PortableJson $taskAppConfig
    $auditEdited.theme='later-user-edit'
    Write-PortableJson $taskAppConfig $auditEdited
    throw 'audit injected after mode commit'
}
if ($env:AG_AUDIT_FAILURE -eq 'terminate') {
    [IO.File]::WriteAllText($env:AG_AUDIT_READY,'ready')
    while ($true) { Start-Sleep -Milliseconds 100 }
}
'@
[IO.File]::WriteAllText($auditInstall,$auditSource.Replace('$taskManifest = @{',$auditInjection+"`n"+'$taskManifest = @{'),[Text.UTF8Encoding]::new($false))
function Check-Audit([bool]$Value,[string]$Message) {if(!$Value){throw $Message}}
function New-AuditFixture([string]$Name) {
    $root=Join-Path $auditScratch $Name
    $bundle=Join-Path $root 'bundle'
    $gemini=Join-Path $root 'gemini'
    foreach($relative in @('scripts','runtime','native')){New-Item -ItemType Directory -Path (Join-Path $bundle $relative) -Force|Out-Null}
    # Inert Windows executable: no real service, model, login or user configuration.
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/where.exe') -Destination (Join-Path $bundle 'runtime/dotnet.exe')
    [IO.File]::WriteAllText((Join-Path $bundle 'scripts/gravity-guardian.dll'),'fixture')
    [IO.File]::WriteAllText((Join-Path $bundle 'native/ag-guardian-host.exe'),'fixture')
    foreach($name in @('plugin.json','hooks.json','pricing.json')){Copy-Item -LiteralPath (Join-Path $auditRoot ('plugin/'+$name)) -Destination $bundle}
    Write-PortableJson (Join-Path $gemini 'config/config.json') @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW';enableTerminalSandbox=$false};sidecars=@{other=@{enabled=$true}};theme='light'}
    @{root=$root;gemini=$gemini;bundle=$bundle;data=(Join-Path $root 'custom-data');plugin=(Join-Path $gemini 'config/plugins/gravity-guardian');config=(Join-Path $gemini 'config/config.json')}
}
function Invoke-AuditInstall($Fixture,[switch]$OmitData) {
    $arguments=@{BundlePath=$Fixture.bundle;GeminiRoot=$Fixture.gemini;AntigravityPath=$env:ComSpec;NoStart=$true}
    if(!$OmitData){$arguments.DataDirectory=$Fixture.data}
    & $auditInstall @arguments|Out-Null
}
$auditPriorFailure=$env:AG_AUDIT_FAILURE
$auditPriorReady=$env:AG_AUDIT_READY
try {
    $f=New-AuditFixture 'first-failure'
    Write-PortableJson (Join-Path $f.gemini 'config/projects/broken.json') @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO'}}
    [IO.File]::WriteAllText((Join-Path $f.gemini 'config/projects/broken.json'),'{bad json')
    try {Invoke-AuditInstall $f;throw 'Expected invalid project rejection'}catch{if($_.Exception.Message -eq 'Expected invalid project rejection'){throw}}
    Check-Audit ((Read-PortableJson $f.config).userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW') 'Prevalidation changed global mode'
    Check-Audit (!(Test-Path -LiteralPath $f.plugin)) 'Prevalidation installed plugin'
    Write-PortableJson (Join-Path $f.gemini 'config/projects/broken.json') @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO'}}
    $env:AG_AUDIT_FAILURE='throw'
    try {Invoke-AuditInstall $f;throw 'Expected injected failure'}catch{if($_.Exception.Message -notlike '*audit injected*'){throw}}
    $state=Read-PortableJson $f.config
    Check-Audit ($state.userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW' -and !$state.userSettings.enableTerminalSandbox) 'Failed first install lost initial settings'
    Check-Audit (!$state.sidecars.ContainsKey('gravity-guardian/reviewer') -and $state.sidecars.other.enabled -and !(Test-Path -LiteralPath $f.plugin)) 'Failed first install retained registration'
    Check-Audit ($state.theme -eq 'later-user-edit') 'Rollback overwrote an unrelated later edit'
    Check-Audit (!(Test-Path -LiteralPath (Join-Path $f.data 'installation.json'))) 'Failed first install retained manifest'
    $env:AG_AUDIT_FAILURE=''
    Invoke-AuditInstall $f
    [IO.File]::WriteAllText((Join-Path $f.data 'approval-takeover-paused'),'paused')
    Write-PortableJson (Join-Path $f.data 'logs/history.jsonl') @{sentinel='history'}
    $beforeManifest=[IO.File]::ReadAllText((Join-Path $f.data 'installation.json'))
    $beforeApproval=[IO.File]::ReadAllText((Join-Path $f.plugin 'approval.json'))
    $upgradeMode=Read-PortableJson $f.config
    $upgradeMode.userSettings.permissionPreset='AGENT_PERMISSION_PRESET_AUTO'
    $upgradeMode.userSettings.enableTerminalSandbox=$false
    Write-PortableJson $f.config $upgradeMode
    $env:AG_AUDIT_FAILURE='throw'
    try {Invoke-AuditInstall $f -OmitData;throw 'Expected upgrade failure'}catch{if($_.Exception.Message -notlike '*audit injected*'){throw}}
    Check-Audit ((Read-PortableJson $f.config).userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_AUTO' -and !(Read-PortableJson $f.config).userSettings.enableTerminalSandbox) 'Upgrade rollback used the first-install uninstall snapshot'
    Check-Audit ([IO.File]::ReadAllText((Join-Path $f.data 'installation.json')) -ceq $beforeManifest) 'Upgrade rollback lost original manifest'
    Check-Audit ([IO.File]::ReadAllText((Join-Path $f.plugin 'approval.json')) -ceq $beforeApproval) 'Upgrade rollback lost old plugin'
    $env:AG_AUDIT_FAILURE=''
    Invoke-AuditInstall $f -OmitData
    Check-Audit ((Read-PortableJson (Join-Path $f.plugin 'approval.json')).dataDirectory -eq $f.data) 'F06 repair reset custom data'
    Check-Audit ((Read-PortableJson (Join-Path $f.data 'panel-settings.json')).dataDirectory -eq $f.data) 'F06 panel path reset'
    Check-Audit ((Test-Path -LiteralPath (Join-Path $f.data 'logs/history.jsonl')) -and (Test-Path -LiteralPath (Join-Path $f.data 'approval-takeover-paused'))) 'F06 history or pause state lost'
    Remove-Item -LiteralPath (Join-Path $f.gemini 'config/projects/broken.json')
    Invoke-AuditInstall $f -OmitData
    Check-Audit (!(Test-Path -LiteralPath (Join-Path $f.gemini 'config/projects/broken.json'))) 'R03 repair recreated deleted project'
    $repairManifest=Read-PortableJson (Join-Path $f.data 'installation.json')
    Check-Audit (@($repairManifest.reviewModeChanges | Where-Object { $_.path -like '*broken.json' }).Count -eq 0) 'R03 deleted project retained as an active migration record'
    try { Set-CodexReviewMode -ConfigRoot (Join-Path $f.gemini 'config') -PreviousChanges @(@{path=(Join-Path $f.root 'outside.json')}) -ValidateOnly; throw 'Expected outside-path rejection' }
    catch { if ($_.Exception.Message -notlike '*outside the native configuration files*') { throw } }
    Write-Host 'PASS R03 deleted historical project permits repair, remains absent, and outside paths remain rejected'
    & (Join-Path $auditScripts 'Uninstall.ps1') -DataDirectory $f.data|Out-Null
    Check-Audit ((Read-PortableJson $f.config).userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW') 'Uninstall after retry lost first-install mode'
    Check-Audit (!(Read-PortableJson $f.config).sidecars.ContainsKey('gravity-guardian/reviewer')) 'Uninstall after retry lost initial sidecar state'
    Write-Host 'PASS F02 failed fresh/upgrade install, retry and uninstall; F06 custom data, history and pause retained'

    $f=New-AuditFixture 'binding'
    Write-PortableJson (Join-Path $f.plugin 'binding.json') @{storageMode='portable';portableRoot=(Join-Path $f.root 'portable')}
    $before=[IO.File]::ReadAllText($f.config)
    try {Invoke-AuditInstall $f;throw 'Expected binding precheck'}catch{if($_.Exception.Message -notlike '*请先断开便携版连接*'){throw}}
    Check-Audit ([IO.File]::ReadAllText($f.config) -ceq $before) 'F07 precheck changed configuration'
    Check-Audit (!(Test-Path -LiteralPath $f.data)) 'F07 precheck wrote data'
    Write-Host 'PASS F07 portable binding rejected before any installed writes'

    $f=New-AuditFixture 'disconnect-flow'
    $portableRoot=Join-Path $f.root 'portable'
    $portableApp=Join-Path $portableRoot 'app'
    New-Item -ItemType Directory -Path $portableRoot -Force|Out-Null
    Copy-Item -LiteralPath $f.bundle -Destination $portableApp -Recurse
    Write-PortableJson (Join-Path $portableApp 'native/SOURCE.json') @{binarySha256=(Get-FileHash -LiteralPath (Join-Path $portableApp 'native/ag-guardian-host.exe')).Hash}
    $layout=@{root=$portableRoot;app=$portableApp;data=(Join-Path $portableRoot 'data');config=(Join-Path $portableRoot 'config/approval.json');manifest=(Join-Path $portableRoot 'data/installation.json')}
    Connect-Portable $layout $f.gemini $env:ComSpec @{NoStart=$true}|Out-Null
    Write-PortableJson (Join-Path $layout.data 'logs/retained.jsonl') @{sentinel='portable-history'}
    $portableConfig=[IO.File]::ReadAllText($layout.config)
    try {Invoke-AuditInstall $f;throw 'Expected connected portable rejection'}catch{if($_.Exception.Message -notlike '*请先断开便携版连接*'){throw}}
    Disconnect-Portable $layout|Out-Null
    Invoke-AuditInstall $f
    Check-Audit ((Test-Path -LiteralPath (Join-Path $f.data 'installation.json')) -and (Test-Path -LiteralPath (Join-Path $layout.data 'logs/retained.jsonl'))) 'F07 supported switch lost portable data or did not install'
    Check-Audit ([IO.File]::ReadAllText($layout.config) -ceq $portableConfig) 'F07 supported switch changed portable settings'
    Write-Host 'PASS F07 disconnect then install succeeds and retains portable configuration and data'

    # Exercise the real Connect-Portable catch; only service calls are inert in this scope.
    & {
        $f=New-AuditFixture 'rollback'
        $portableRoot=Join-Path $f.root 'portable'
        $portableApp=Join-Path $portableRoot 'app'
        New-Item -ItemType Directory -Path $portableRoot -Force|Out-Null
        Copy-Item -LiteralPath $f.bundle -Destination $portableApp -Recurse
        Write-PortableJson (Join-Path $portableApp 'native/SOURCE.json') @{binarySha256=(Get-FileHash -LiteralPath (Join-Path $portableApp 'native/ag-guardian-host.exe')).Hash}
        $layout=@{root=$portableRoot;app=$portableApp;data=(Join-Path $portableRoot 'data');config=(Join-Path $portableRoot 'config/approval.json');manifest=(Join-Path $portableRoot 'data/installation.json')}
        function Stop-PortableService($Layout) {}
        function Invoke-PortableCore($Layout,$Command) {}
        Connect-Portable $layout $f.gemini $env:ComSpec @{NoStart=$true}|Out-Null
        $originalManifest=[IO.File]::ReadAllText($layout.manifest)
        $before=Read-PortableJson $f.config
        $before.userSettings.permissionPreset='AGENT_PERMISSION_PRESET_AUTO'
        $before.userSettings.enableTerminalSandbox=$false
        Write-PortableJson $f.config $before
        $faultedHelper=Join-Path $auditScripts 'Portable-Faulted.ps1'
        $injection=@'
        $changed=Read-PortableJson (Join-Path $configRoot 'config.json')
        $changed.theme='edit-after-connection-started'
        Write-PortableJson (Join-Path $configRoot 'config.json') $changed
        throw 'audit portable failure after mode commit'
'@
        $helperSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Portable.ps1'))
        [IO.File]::WriteAllText($faultedHelper,$helperSource.Replace('        if (!$Options.NoStart) {',$injection+"`n"+'        if (!$Options.NoStart) {'))
        . $faultedHelper
        function Stop-PortableService($Layout) {}
        function Invoke-PortableCore($Layout,$Command) {}
        try {Connect-Portable $layout $f.gemini $env:ComSpec @{NoStart=$true}|Out-Null;throw 'Expected portable rollback failure'}catch{if($_.Exception.Message -notlike '*audit portable failure after mode commit*'){throw}}
        $restored=Read-PortableJson $f.config
        Check-Audit ($restored.userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_AUTO' -and !$restored.userSettings.enableTerminalSandbox) 'D02 restored the first-install mode instead of the current attempt'
        Check-Audit ($restored.theme -eq 'edit-after-connection-started') 'D02 overwrote an unrelated later edit'
        Check-Audit ([IO.File]::ReadAllText($layout.manifest) -ceq $originalManifest) 'D02 changed the original uninstall record'
        Disconnect-Portable $layout|Out-Null
        $disconnected=Read-PortableJson $f.config
        Check-Audit ($disconnected.userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_AUTO') 'D02 disconnect overwrote a later user mode'
        # Retry with the original helper, then disconnect: the first-install baseline still works.
        . (Join-Path $PSScriptRoot 'Portable.ps1')
        function Stop-PortableService($Layout) {}
        function Invoke-PortableCore($Layout,$Command) {}
        Connect-Portable $layout $f.gemini $env:ComSpec @{NoStart=$true}|Out-Null
        Disconnect-Portable $layout|Out-Null
        Check-Audit ((Read-PortableJson $f.config).userSettings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_AUTO') 'D02 retry lost the disconnect restoration baseline'
        Write-Host 'PASS D02 portable connection failure restores this attempt, preserves later edits and retains disconnect recovery'
    }

    & {
        $f=New-AuditFixture 'lite-recovery'
        $registration=$f.plugin
        $systemRuntime=Join-Path $f.root 'system-dotnet.exe'
        [IO.File]::WriteAllText($systemRuntime,'inert runtime')
        Write-PortableJson (Join-Path $registration 'plugin.json') @{name='gravity-guardian'}
        Write-PortableJson (Join-Path $registration 'distribution.json') @{type='lite'}
        Write-PortableJson (Join-Path $registration 'approval.json') @{dataDirectory=$f.data}
        Write-PortableJson (Join-Path $registration 'sidecars/reviewer/sidecar.json') @{command=$systemRuntime}
        $portableRoot=Join-Path $f.root 'portable'
        New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
        Copy-Item -LiteralPath $f.bundle -Destination (Join-Path $portableRoot 'app') -Recurse
        $layout=@{root=$portableRoot;app=(Join-Path $portableRoot 'app');data=(Join-Path $portableRoot 'data');config=(Join-Path $portableRoot 'config/approval.json');manifest=(Join-Path $portableRoot 'data/installation.json')}
        Write-PortableJson (Join-Path $layout.app 'native/SOURCE.json') @{binarySha256=(Get-FileHash -LiteralPath (Join-Path $layout.app 'native/ag-guardian-host.exe')).Hash}
        function Stop-PortableService($Layout) {}
        function Set-CodexReviewMode { throw 'injected Lite migration failure' }
        $recoveryShouldFail=$false
        $recoveryStarts=[Collections.Generic.List[string]]::new()
        function Start-Process {
            param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru)
            $recoveryStarts.Add($FilePath)
            Check-Audit ($FilePath -eq $systemRuntime -and $RedirectStandardOutput.StartsWith((Join-Path $f.data 'service'))) 'R04 recovery used wrong runtime or log directory'
            if ($recoveryShouldFail) { throw 'injected recovery startup failure' }
            $process=[pscustomobject]@{ExitCode=0}
            $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
            $process | Add-Member ScriptMethod Dispose {}
            return $process
        }
        foreach ($recoveryShouldFail in @($false,$true)) {
            try { Connect-Portable $layout $f.gemini $env:ComSpec @{NoStart=$true} | Out-Null; throw 'Expected Lite migration failure' }
            catch {
                Check-Audit ($_.Exception.Message -like '*injected Lite migration failure*') 'R04 lost original failure'
                if ($recoveryShouldFail) { Check-Audit ($_.Exception.Message -like '*Previous service recovery failed*injected recovery startup failure*') 'R04 swallowed recovery failure' }
            }
        }
        Check-Audit ($recoveryStarts.Count -eq 2 -and (Read-PortableJson (Join-Path $registration 'distribution.json')).type -eq 'lite') 'R04 did not restore Lite registration and start its runtime'
        Write-Host 'PASS R04 failed Lite migration restores system runtime and original data logs; recovery errors remain visible'
    }

    $f=New-AuditFixture 'interrupted'
    $env:AG_AUDIT_FAILURE='terminate';$env:AG_AUDIT_READY=Join-Path $f.root 'ready'
    $args=@('-NoProfile','-File',('"'+$auditInstall+'"'),'-BundlePath',('"'+$f.bundle+'"'),'-GeminiRoot',('"'+$f.gemini+'"'),'-DataDirectory',('"'+$f.data+'"'),'-AntigravityPath',('"'+$env:ComSpec+'"'),'-NoStart')
    $child=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput (Join-Path $f.root 'out.log') -RedirectStandardError (Join-Path $f.root 'err.log') -PassThru
    try {
        for($i=0;$i -lt 200 -and !(Test-Path -LiteralPath $env:AG_AUDIT_READY) -and !$child.HasExited;$i++){Start-Sleep -Milliseconds 50}
        Check-Audit (Test-Path -LiteralPath $env:AG_AUDIT_READY) 'Interrupted installer did not reach commit point'
    } finally {if(!$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    $env:AG_AUDIT_FAILURE=''
    $before=[IO.File]::ReadAllText($f.config)
    try {Invoke-AuditInstall $f;throw 'Expected incomplete marker rejection'}catch{if($_.Exception.Message -notlike '*Previous installation did not finish*'){throw}}
    Check-Audit ([IO.File]::ReadAllText($f.config) -ceq $before) 'Interrupted retry changed settings'
    Write-Host 'PASS F02 terminated installer leaves an explicit recovery marker and retry aborts before writing'

    $lite=Join-Path $auditScratch 'lite'
    $systemRuntime=Join-Path $auditScratch 'system-runtime.cmd'
    [IO.File]::WriteAllText($systemRuntime,"@echo off`r`necho %2>>`"%~dp0runtime-calls.txt`"`r`necho {`"status`":`"stopped`"}`r`nexit /b 0`r`n")
    Write-PortableJson (Join-Path $lite 'distribution.json') @{type='lite'}
    Write-PortableJson (Join-Path $lite 'sidecars/reviewer/sidecar.json') @{command=$systemRuntime}
    Write-PortableJson (Join-Path $lite 'approval.json') @{}
    Stop-PortableService @{app=$lite;config=(Join-Path $lite 'approval.json');data=(Join-Path $lite 'data')}
    Check-Audit ([IO.File]::ReadAllText((Join-Path $auditScratch 'runtime-calls.txt')).Contains('status')) 'F08 system runtime was not invoked'
    $stopSignal=Join-Path $auditScratch 'stop-worker'
    $workerScript=Join-Path $auditScratch 'worker.ps1'
    [IO.File]::WriteAllText($workerScript,("while (!(Test-Path -LiteralPath '"+$stopSignal.Replace("'","''")+"')) { Start-Sleep -Milliseconds 50 }"))
    $worker=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',('"'+$workerScript+'"')) -WindowStyle Hidden -PassThru
    try {
        [IO.File]::WriteAllText($systemRuntime,("@echo off`r`necho %2>>`"%~dp0runtime-calls.txt`"`r`nif `"%2`"==`"stop`" type nul > `""+$stopSignal+"`"`r`necho {`"status`":`"running`",`"pid`":"+$worker.Id+"}`r`nexit /b 0`r`n"))
        Stop-PortableService @{app=$lite;config=(Join-Path $lite 'approval.json');data=(Join-Path $lite 'data')}
        Check-Audit ($worker.HasExited -and (Test-Path -LiteralPath $stopSignal)) 'F08 did not request stop and wait for exit'
    } finally {if(!$worker.HasExited){$worker.Kill();$worker.WaitForExit()};$worker.Dispose()}
    [IO.File]::WriteAllText($systemRuntime,"@echo off`r`necho {`"status`":`"unknown`"}`r`nexit /b 0`r`n")
    try {Stop-PortableService @{app=$lite;config=(Join-Path $lite 'approval.json');data=(Join-Path $lite 'data')};throw 'Expected unknown status abort'}catch{if($_.Exception.Message -notlike '*Unknown approval service state*'){throw}}
    Write-Host 'PASS F08 Lite helper uses system runtime, requests stop, waits for exit and aborts on unknown state'
} finally {$env:AG_AUDIT_FAILURE=$auditPriorFailure;$env:AG_AUDIT_READY=$auditPriorReady}
Write-Host ('Audit regression evidence: '+$auditScratch)
