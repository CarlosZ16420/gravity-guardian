[CmdletBinding()]
param([string]$DataDirectory=(Join-Path $env:USERPROFILE '.gemini/codex-approval-data'),[switch]$SkipCodexLoginCheck)
$ErrorActionPreference='Stop'
$taskManifest=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $DataDirectory 'installation.json') -Raw | ConvertFrom-Json
$taskPlugin=$taskManifest.pluginDirectory
$taskConfig=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json
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
Write-Host ('Reviewer backend: '+$taskConfig.reviewerBackend+'; native state binding: '+$taskConfig.enableNativeState)
Write-Host ('Native ask after eligible technical failure: '+$taskConfig.enableNativeAskHandoff)
if($taskConfig.reviewerBackend -eq 'NativeGuardian'){
    $taskVersionRaw=& $taskConfig.guardianPath --version
    if($LASTEXITCODE -ne 0){throw 'Native Guardian executable failed its offline version check'}
    $taskVersion=$taskVersionRaw|ConvertFrom-Json
    $taskGuardianManifest=Get-Content -Encoding UTF8 -LiteralPath (Join-Path (Split-Path $taskConfig.guardianPath) 'SOURCE.json') -Raw|ConvertFrom-Json
    if($taskVersion.protocol -cne $taskGuardianManifest.protocol -or $taskVersion.upstreamCommit -cne $taskGuardianManifest.upstreamCommit){throw 'Native runtime version differs from source manifest'}
    if((Get-FileHash -LiteralPath $taskConfig.guardianPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskGuardianManifest.binarySha256){throw 'Native Guardian binary integrity mismatch'}
    Write-Host ('Native Guardian protocol/upstream/SHA256: '+$taskVersion.protocol+'/'+$taskVersion.upstreamCommit+'/'+$taskGuardianManifest.binarySha256)
}
Write-Host ('Native read-only routing: '+$taskConfig.enableNativeRouting)
Write-Host ('Reviewer sessions: '+$taskConfig.enableReviewerSessions+'; evidence budget: '+$taskConfig.maxEvidenceBytes+' bytes')
$taskHooks=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'hooks.json') -Raw|ConvertFrom-Json
$taskOuterTimeout=$taskHooks.'codex-approval'.PreToolUse[0].hooks[0].timeout
Write-Host ('Deadlines (review/client/native hook): '+$taskConfig.reviewTimeoutSeconds+'/'+$taskConfig.hookTimeoutSeconds+'/'+$taskOuterTimeout+' seconds')
if($taskConfig.reviewTimeoutSeconds -ge $taskConfig.hookTimeoutSeconds -or $taskConfig.hookTimeoutSeconds -ge $taskOuterTimeout){Write-Warning 'Nested approval deadlines are out of order; the outer hook may discard the reviewer result.'}
if(!$SkipCodexLoginCheck){
    if($taskConfig.codexPath -and (Test-Path -LiteralPath $taskConfig.codexPath)){
        & $taskConfig.codexPath --version;& $taskConfig.codexPath login status
    }else{
        Write-Warning 'Codex CLI path is not configured; CLI fallback is disabled. NativeGuardian uses .codex credentials directly.'
    }
}
$taskRunningRaw=& (Join-Path $taskPlugin 'runtime/dotnet.exe') (Join-Path $taskPlugin 'scripts/ag-approval.dll') status --config (Join-Path $taskPlugin 'approval.json')
if($LASTEXITCODE -ne 0){throw 'Approval service is not responding; installed files do not prove a running upgrade'}
$taskRunning=($taskRunningRaw -join [Environment]::NewLine).Trim()|ConvertFrom-Json
$taskInstalled=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw|ConvertFrom-Json
Write-Host ('Installed/running version: '+$taskInstalled.version+'/'+$taskRunning.version)
if($taskRunning.version -ne $taskInstalled.version){Write-Warning 'The running service is older than the installed package. Completely exit Antigravity and restart.'}
$taskRunning|ConvertTo-Json -Depth 8
Write-Host 'Host limits: exact request replay protection only; native turn identity and effective runtime permissions are not fully observable.'
Write-Host ('Backup: '+$taskManifest.backupDirectory)
Write-Host ('Latest upgrade backup: '+$taskManifest.latestUpgradeBackup)
Write-Host ('Review logs: '+(Join-Path $DataDirectory 'logs'))
