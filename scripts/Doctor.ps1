[CmdletBinding()]
param([string]$DataDirectory=(Join-Path $env:USERPROFILE '.gemini/gravity-guardian-data'),[Alias('SkipCodexLoginCheck')][switch]$SkipGuardianAuthCheck)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$taskPortable = Get-PortableLayout
if ($taskPortable -and !$PSBoundParameters.ContainsKey('DataDirectory')) { $DataDirectory=$taskPortable.data }
$taskManifest=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $DataDirectory 'installation.json') -Raw | ConvertFrom-Json
$taskPlugin=if ($taskPortable) { $taskPortable.app } else { $taskManifest.pluginDirectory }
$taskConfigPath=if ($taskPortable) { $taskPortable.config } else { Join-Path $taskPlugin 'approval.json' }
$taskConfig=Get-Content -Encoding UTF8 -LiteralPath $taskConfigPath -Raw | ConvertFrom-Json
if ($taskPortable) {
    Write-Host ('Portable application: '+$taskPortable.root)
    if ($null -eq $taskConfig.reviewTimeoutSeconds) { $taskConfig | Add-Member -NotePropertyName reviewTimeoutSeconds -NotePropertyValue 90 }
    if ($null -eq $taskConfig.hookTimeoutSeconds) { $taskConfig | Add-Member -NotePropertyName hookTimeoutSeconds -NotePropertyValue 100 }
}
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskNative=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskManifest.configRoot 'config.json') -Raw|ConvertFrom-JsonHashtable
$taskExpected=Get-CodexNativeSettings
Write-Host ('Native permission preset: '+$taskNative.userSettings.permissionPreset)
foreach($taskKey in $taskExpected.Keys){
    if($taskNative.userSettings[$taskKey] -cne $taskExpected[$taskKey]){Write-Warning ('Native review conflict: '+$taskKey+' should be '+$taskExpected[$taskKey]+' for Codex review mode. Reinstall with -ReviewMode Codex.')}
}
$taskProjects=Join-Path $taskManifest.configRoot 'projects'
if(Test-Path -LiteralPath $taskProjects){
    Get-ChildItem -LiteralPath $taskProjects -Filter '*.json' -File|ForEach-Object{
        try{$taskProject=Get-Content -Encoding UTF8 -LiteralPath $_.FullName -Raw|ConvertFrom-Json}
        catch{Write-Warning ('Cannot read project settings: '+$_.Name);return}
        if($taskProject.settings.permissionPreset -eq 'AGENT_PERMISSION_PRESET_AUTO'){Write-Warning ('Project still enables native Auto review: '+$_.Name)}
    }
}
Write-Host ('Reviewer: '+$taskConfig.model+' / '+$taskConfig.effort)
Write-Host ('Reviewer backend: NativeGuardian; native state binding: '+$taskConfig.enableNativeState)
Write-Host ('Native ask after eligible technical failure: '+$taskConfig.enableNativeAskHandoff)
$taskGuardian = if ($taskConfig.guardianPath) { $taskConfig.guardianPath } else { Join-Path $taskPlugin 'native/ag-guardian-host.exe' }
$taskGuardianManifest=Get-Content -Encoding UTF8 -LiteralPath (Join-Path (Split-Path $taskGuardian) 'SOURCE.json') -Raw|ConvertFrom-Json
if((Get-FileHash -LiteralPath $taskGuardian -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskGuardianManifest.binarySha256){throw 'Native Guardian binary integrity mismatch'}
$taskVersionRaw=& $taskGuardian --version
if($LASTEXITCODE -ne 0){throw 'Native Guardian executable failed its offline version check'}
$taskVersion=$taskVersionRaw|ConvertFrom-Json
if($taskVersion.protocol -cne $taskGuardianManifest.protocol -or $taskVersion.upstreamCommit -cne $taskGuardianManifest.upstreamCommit){throw 'Native runtime version differs from source manifest'}
Write-Host ('Native Guardian protocol/upstream/SHA256: '+$taskVersion.protocol+'/'+$taskVersion.upstreamCommit+'/'+$taskGuardianManifest.binarySha256)
Write-Host ('Native read-only routing: '+$taskConfig.enableNativeRouting)
$taskProtectedDelegation = if ($null -eq $taskConfig.delegateProtectedPaths) { $true } else { [bool]$taskConfig.delegateProtectedPaths }
Write-Host ('Protected-path delegation: '+$taskProtectedDelegation)
$taskLedgerPath = Join-Path $DataDirectory 'delegated-grants.json'
$taskOwnedCount = 0
if (Test-Path -LiteralPath $taskLedgerPath -PathType Leaf) {
    $taskLedger = Get-Content -Encoding UTF8 -LiteralPath $taskLedgerPath -Raw | ConvertFrom-Json
    if ($taskLedger.ownedGrants) { $taskOwnedCount = @($taskLedger.ownedGrants).Count }
}
Write-Host ('Active delegated protected grants: '+$taskOwnedCount)
$taskHooks=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskManifest.pluginDirectory 'hooks.json') -Raw|ConvertFrom-Json
$taskOuterTimeout=$taskHooks.'gravity-guardian'.PreToolUse[0].hooks[0].timeout
Write-Host ('Deadlines (review/client/native hook): '+$taskConfig.reviewTimeoutSeconds+'/'+$taskConfig.hookTimeoutSeconds+'/'+$taskOuterTimeout+' seconds')
if($taskConfig.reviewTimeoutSeconds -ge $taskConfig.hookTimeoutSeconds -or $taskConfig.hookTimeoutSeconds -ge $taskOuterTimeout){Write-Warning 'Nested approval deadlines are out of order; the outer hook may discard the reviewer result.'}
$taskRuntime = Resolve-ApprovalRuntime $taskPlugin -Installed
Write-Host ('Distribution: ' + (Get-ApprovalDistribution $taskPlugin) + '; .NET: ' + $taskRuntime)
$taskAssembly = Join-Path $taskPlugin 'scripts/gravity-guardian.dll'
if(!$SkipGuardianAuthCheck){
    $taskDetectionRaw = & $taskRuntime $taskAssembly detect --config $taskConfigPath --gemini-root $taskManifest.geminiRoot --data-dir $DataDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Native authentication probe failed' }
    $taskDetection = ($taskDetectionRaw -join [Environment]::NewLine) | ConvertFrom-Json
    Write-Host ('Native authentication: ' + ($taskDetection.nativeAuth | ConvertTo-Json -Depth 4 -Compress))
}
$taskRunningRaw=& $taskRuntime $taskAssembly status --config $taskConfigPath
if($LASTEXITCODE -ne 0){throw 'Approval service is not responding; installed files do not prove a running upgrade'}
$taskRunning=($taskRunningRaw -join [Environment]::NewLine).Trim()|ConvertFrom-Json
$taskTakeoverRaw=& $taskRuntime $taskAssembly takeover --config $taskConfigPath
$taskTakeoverEnabled=$LASTEXITCODE -eq 0 -and ($taskTakeoverRaw | ConvertFrom-Json).takeoverEnabled
if ($taskOwnedCount -gt 0 -and (!$taskTakeoverEnabled -or $taskRunning.status -ne 'running')) {
    Write-Warning 'Delegated protected-path grants exist while takeover is paused or the service is not running.'
}
$taskInstalled=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw|ConvertFrom-Json
Write-Host ('Installed/running version: '+$taskInstalled.version+'/'+$taskRunning.version)
if($taskRunning.version -ne $taskInstalled.version){Write-Warning 'The running service is older than the installed package. Completely exit Antigravity and restart.'}
$taskRunning|ConvertTo-Json -Depth 8
Write-Host 'Host limits: exact request replay protection only; native turn identity and effective runtime permissions are not fully observable.'
Write-Host ('Backup: '+$taskManifest.backupDirectory)
Write-Host ('Latest upgrade backup: '+$taskManifest.latestUpgradeBackup)
Write-Host ('Review logs: '+(Join-Path $DataDirectory 'logs'))
