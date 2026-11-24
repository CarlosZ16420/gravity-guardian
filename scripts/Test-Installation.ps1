$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskFixture = Join-Path $taskRoot ('.local/install-test/' + [Guid]::NewGuid().ToString('N') + '/Windows 测试 profile')
$taskGemini = Join-Path $taskFixture '.gemini'
$taskConfig = Join-Path $taskGemini 'config'
$taskData = Join-Path $taskFixture 'data'
# Start only the approval host, then use invalid-input hook checks. These application
# paths are placeholders and are never launched; no model or personal login is used.
$taskExecutables = @{ CodexPath = $env:ComSpec; AntigravityPath = $env:ComSpec }
New-Item -ItemType Directory -Path $taskConfig -Force | Out-Null
$taskOriginal = @{ userSettings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO'; globalPermissionGrants = @{ allow = @('command(git status)'); deny = @('write_file(private)') } }; sidecars = @{ other = @{ enabled = $true } } }
$taskOriginal | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath (Join-Path $taskConfig 'config.json') -Encoding utf8
$taskProjects = Join-Path $taskConfig 'projects'
New-Item -ItemType Directory -Path $taskProjects -Force | Out-Null
$taskProjectFile = Join-Path $taskProjects 'auto-project.json'
@{ id = 'auto-project'; projectResources = @{}; settings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO' }; permissionGrants = @{ permissionGrants = @{ ask = @('command(rm)') } } } | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskProjectFile -Encoding utf8
$taskUserModeFile = Join-Path $taskProjects 'later-user-selection.json'
@{ id = 'later-user-selection'; projectResources = @{}; settings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO' } } | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskUserModeFile -Encoding utf8

& (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData @taskExecutables
$taskInstalled = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskConfig 'config.json') -Raw | ConvertFrom-Json
if (!$taskInstalled.sidecars.other.enabled -or !$taskInstalled.sidecars.'codex-approval/reviewer'.enabled) { throw 'Sidecar merge failed' }
if ($taskInstalled.userSettings.globalPermissionGrants.deny[0] -ne 'write_file(private)') { throw 'User permission rules changed' }
if ($taskInstalled.userSettings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_DEFAULT' -or !$taskInstalled.userSettings.enableTerminalSandbox -or $taskInstalled.userSettings.autoExecutionPolicy -ne 'CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX') { throw 'Native Auto review was not replaced by sandboxed Default mode' }
$taskProject = Get-Content -Encoding UTF8 -LiteralPath $taskProjectFile -Raw | ConvertFrom-Json
if ($taskProject.settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_DEFAULT' -or $taskProject.permissionGrants.permissionGrants.ask[0] -ne 'command(rm)') { throw 'Project Auto migration changed explicit rules' }

$taskPlugin = Join-Path $taskConfig 'plugins/codex-approval'
$taskReview = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json
if ($taskReview.model -ne 'codex-auto-review' -or !$taskReview.enableNativeRouting -or !(Test-Path -LiteralPath $taskReview.policyDirectory)) { throw 'Installed runtime configuration invalid' }
if ($taskReview.reviewerBackend -ne 'NativeGuardian' -or !$taskReview.enableNativeState -or !(Test-Path -LiteralPath $taskReview.guardianPath)) { throw 'Native Guardian was not installed as the selected backend' }
if (![string]::IsNullOrEmpty($taskReview.proxy)) { throw 'Default open-source proxy must be empty' }
foreach ($expectedAsset in @('pricing.json', 'update-config.json', 'app/CodexApprovalPanel.exe', 'scripts/Apply-Update.ps1')) {
    if (!(Test-Path -LiteralPath (Join-Path $taskPlugin $expectedAsset) -PathType Leaf)) { throw ('Missing expected panel/update asset: ' + $expectedAsset) }
}
$taskInstalledHooks = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'hooks.json') -Raw | ConvertFrom-Json
if ($taskReview.reviewTimeoutSeconds -ne 90 -or $taskReview.hookTimeoutSeconds -ne 100 -or $taskInstalledHooks.'codex-approval'.PreToolUse[0].hooks[0].timeout -ne 120) { throw 'Nested review, client, and native hook deadlines are not coordinated' }

& (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin
& (Join-Path $PSScriptRoot 'Doctor.ps1') -DataDirectory $taskData -SkipCodexLoginCheck
& (Join-Path $PSScriptRoot 'Analyze-Logs.ps1') -DataDirectory $taskData

$taskManifestPath = Join-Path $taskData 'installation.json'
$taskFirstManifest = Get-Content -Encoding UTF8 -LiteralPath $taskManifestPath -Raw | ConvertFrom-JsonHashtable
$taskLegacyLauncher = Join-Path $taskFixture 'LegacyLauncher.bat'
[IO.File]::WriteAllText($taskLegacyLauncher, '@echo off' + "`r`n" + $taskPlugin)
[IO.File]::WriteAllText((Join-Path $taskFirstManifest.backupDirectory 'launcher.bat.original'), 'ORIGINAL_LAUNCHER')
$taskFirstManifest.launcherPath = $taskLegacyLauncher
$taskFirstManifest.installedLauncherHash = (Get-FileHash -LiteralPath $taskLegacyLauncher).Hash
$taskFirstManifest | ConvertTo-Json -Depth 20 | Set-Utf8NoBom -LiteralPath $taskManifestPath
$taskCustomConfig = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-JsonHashtable
$taskCustomConfig.futureCompatibleSetting = 'preserved-on-upgrade'
$taskCustomConfig | ConvertTo-Json -Depth 20 | Set-Utf8NoBom -LiteralPath (Join-Path $taskPlugin 'approval.json') -Encoding utf8
$taskGuardDirectory = Join-Path $taskData 'denial-guard'
New-Item -ItemType Directory -Path $taskGuardDirectory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $taskGuardDirectory 'test-state.txt'), 'persistent protection sentinel')

& (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData @taskExecutables -ReviewRouting ModelOnly -ReviewerBackend Cli -UseVerifiedCopyCommit
$taskUpgradeManifest = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskData 'installation.json') -Raw | ConvertFrom-Json
if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json).enableNativeRouting) { throw 'ModelOnly fallback did not disable routing' }
if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json).reviewerBackend -ne 'Cli') { throw 'Explicit CLI fallback was not selected' }
if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json).futureCompatibleSetting -ne 'preserved-on-upgrade') { throw 'Upgrade discarded an unknown compatible setting' }
if ([IO.File]::ReadAllText((Join-Path $taskGuardDirectory 'test-state.txt')) -ne 'persistent protection sentinel') { throw 'Upgrade reset persistent protection state' }
if ($taskUpgradeManifest.backupDirectory -ne $taskFirstManifest.backupDirectory) { throw 'Upgrade lost the original restoration backup' }
if (@($taskUpgradeManifest.reviewModeChanges).Count -ne 3) { throw 'Upgrade lost native review-mode restoration records' }

& (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin

$taskUserMode = Get-Content -Encoding UTF8 -LiteralPath $taskUserModeFile -Raw | ConvertFrom-JsonHashtable
$taskUserMode.settings.permissionPreset = 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW'
$taskUserMode | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskUserModeFile -Encoding utf8

$taskInstalledUninstaller = Join-Path $taskPlugin 'scripts/Uninstall.ps1'
$taskHostPath = Join-Path $taskPlugin 'runtime/dotnet.exe'
$taskLog = Join-Path $taskData 'logs/uninstall-test.jsonl'
$taskOldArchive = Join-Path $taskData 'uninstalled-plugin-20261124-000000'
New-Item -ItemType Directory -Path (Split-Path $taskLog -Parent), $taskOldArchive -Force | Out-Null
[IO.File]::WriteAllText($taskLog, 'private log fixture')
[IO.File]::WriteAllText((Join-Path $taskOldArchive 'old-plugin.dll'), 'archived executable fixture')
$taskPersonalFile = Join-Path $taskData 'personal-file.txt'
[IO.File]::WriteAllText($taskPersonalFile, 'unrelated file fixture')
try {
    & $taskInstalledUninstaller -DataDirectory $taskData -PurgeData
    throw 'Complete uninstall accepted an unrelated file in its custom data directory'
} catch {
    if ($_.Exception.Message -notlike 'Unexpected item in the data directory.*') { throw }
}
if (!(Test-Path -LiteralPath $taskPersonalFile) -or (Test-Path -LiteralPath (Join-Path $taskData 'uninstalled'))) {
    throw 'Rejected uninstall changed the installation'
}
Move-Item -LiteralPath $taskPersonalFile -Destination $taskFixture
& $taskInstalledUninstaller -DataDirectory $taskData -PurgeData -WhatIf
if (!(Test-Path -LiteralPath $taskLog)) { throw 'Uninstall preview deleted a log' }
if (!(Get-Process -Name dotnet -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $taskHostPath })) {
    throw 'Approval host was not running before uninstall'
}

# The native panel starts Windows PowerShell from outside the installation and then exits.
$taskWindowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$taskPanelAsset = Join-Path $taskPlugin 'app/CodexApprovalPanel.exe'
$taskPanelLockReady = Join-Path $taskFixture 'panel-lock-ready'
$taskHoldPanelAsset = @'
$taskFile = [IO.File]::Open('{0}', 'Open', 'Read', 'Read')
try {{
    [IO.File]::WriteAllText('{1}', 'ready')
    Start-Sleep -Seconds 5
}} finally {{
    $taskFile.Dispose()
}}
'@
$taskHoldPanelAsset = $taskHoldPanelAsset -f $taskPanelAsset.Replace("'", "''"), $taskPanelLockReady.Replace("'", "''")
$taskEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskHoldPanelAsset))
$taskInitiator = Start-Process -FilePath $taskWindowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$taskEncodedCommand) -WindowStyle Hidden -PassThru
try {
    for ($attempt = 0; $attempt -lt 40 -and !(Test-Path -LiteralPath $taskPanelLockReady); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path -LiteralPath $taskPanelLockReady) -or $taskInitiator.HasExited) { throw 'The simulated panel did not lock its executable' }
    & $taskWindowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $taskInstalledUninstaller `
        -DataDirectory $taskData -PurgeData -WaitPid $taskInitiator.Id -PanelExecutablePath $taskWindowsPowerShell
    if ($LASTEXITCODE -ne 0) { throw ('The installed uninstall script failed in Windows PowerShell with exit code ' + $LASTEXITCODE) }
    if (!$taskInitiator.HasExited) { throw 'Uninstaller did not wait for its originating process to exit' }
} finally {
    $taskInitiator.Dispose()
}
if ((Test-Path -LiteralPath $taskPlugin) -or (Test-Path -LiteralPath $taskData)) { throw 'Complete uninstall left program files or data' }
if (Get-Process -Name dotnet -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $taskHostPath }) {
    throw 'Complete uninstall left the approval host running'
}
if (!(Test-Path -LiteralPath (Join-Path $taskFixture 'personal-file.txt'))) { throw 'Uninstaller removed a file outside the installation' }
if ([IO.File]::ReadAllText($taskLegacyLauncher) -ne 'ORIGINAL_LAUNCHER') { throw 'Uninstaller did not restore the launcher from the background-only edition' }
$taskRestored = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskConfig 'config.json') -Raw | ConvertFrom-Json
if (!$taskRestored.sidecars.other.enabled -or $null -ne $taskRestored.sidecars.'codex-approval/reviewer') { throw 'Uninstall affected another sidecar' }
if ($taskRestored.userSettings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_AUTO' -or $null -ne $taskRestored.userSettings.enableTerminalSandbox -or $null -ne $taskRestored.userSettings.autoExecutionPolicy) { throw 'Uninstall lost original native mode or absent fields' }
$taskRestoredProject = Get-Content -Encoding UTF8 -LiteralPath $taskProjectFile -Raw | ConvertFrom-Json
if ($taskRestoredProject.settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_AUTO' -or $null -ne $taskRestoredProject.settings.enableTerminalSandbox) { throw 'Project native mode was not restored' }
if ((Get-Content -Encoding UTF8 -LiteralPath $taskUserModeFile -Raw | ConvertFrom-Json).settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW') { throw 'Uninstall overwrote later user mode selection' }

Write-Host 'PASS Windows PowerShell installed uninstaller removed the program and all app data, and restored original settings'
$global:LASTEXITCODE = 0
