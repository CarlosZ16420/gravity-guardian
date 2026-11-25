$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskFixture = Join-Path $taskRoot ('.local/install-test/' + [Guid]::NewGuid().ToString('N') + '/Windows 测试 profile')
$taskGemini = Join-Path $taskFixture '.gemini'
$taskConfig = Join-Path $taskGemini 'config'
$taskData = Join-Path $taskFixture 'data'
# Start only the approval host, then use invalid-input hook checks. These application
# paths are placeholders and are never launched; no model or personal login is used.
$taskExecutables = @{ AntigravityPath = $env:ComSpec }
New-Item -ItemType Directory -Path $taskConfig -Force | Out-Null
$taskOriginal = @{ userSettings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO'; globalPermissionGrants = @{ allow = @('command(git status)'); deny = @('write_file(private)') } }; sidecars = @{ other = @{ enabled = $true } } }
$taskOriginal | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath (Join-Path $taskConfig 'config.json') -Encoding utf8
$taskProjects = Join-Path $taskConfig 'projects'
New-Item -ItemType Directory -Path $taskProjects -Force | Out-Null
$taskProjectFile = Join-Path $taskProjects 'auto-project.json'
@{ id = 'auto-project'; projectResources = @{}; settings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO' }; permissionGrants = @{ permissionGrants = @{ ask = @('command(rm)') } } } | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskProjectFile -Encoding utf8
$taskUserModeFile = Join-Path $taskProjects 'later-user-selection.json'
@{ id = 'later-user-selection'; projectResources = @{}; settings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_AUTO' } } | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskUserModeFile -Encoding utf8

$taskLegacyPlugin = Join-Path $taskConfig 'plugins/codex-approval'
New-Item -ItemType Directory -Path $taskLegacyPlugin -Force | Out-Null
$taskBeforeLegacyCheck = (Get-FileHash -LiteralPath (Join-Path $taskConfig 'config.json')).Hash
$taskLegacyFailure = $null
try {
    & (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData @taskExecutables
} catch { $taskLegacyFailure = $_.Exception.Message }
if ($taskLegacyFailure -notlike 'Legacy Gravity Steward installation detected.*' -or
    (Get-FileHash -LiteralPath (Join-Path $taskConfig 'config.json')).Hash -cne $taskBeforeLegacyCheck -or
    (Test-Path -LiteralPath $taskData) -or (Test-Path -LiteralPath (Join-Path $taskConfig 'plugins/gravity-guardian'))) {
    throw 'Legacy installation was not rejected before changing configuration or data'
}
[IO.Directory]::Delete($taskLegacyPlugin)
Write-Host 'PASS legacy plugin requires explicit migration before any installation changes'

& (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData @taskExecutables
$taskInstalled = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskConfig 'config.json') -Raw | ConvertFrom-Json
if (!$taskInstalled.sidecars.other.enabled -or !$taskInstalled.sidecars.'gravity-guardian/reviewer'.enabled) { throw 'Sidecar merge failed' }
if ($taskInstalled.userSettings.globalPermissionGrants.deny[0] -ne 'write_file(private)') { throw 'User permission rules changed' }
if ($taskInstalled.userSettings.globalPermissionGrants.allow -cnotcontains 'command(git status)' -or
    $taskInstalled.userSettings.globalPermissionGrants.allow -cnotcontains 'read_file(.git)' -or
    $taskInstalled.userSettings.globalPermissionGrants.allow -cnotcontains 'read_file(.cache)' -or
    $taskInstalled.userSettings.globalPermissionGrants.allow -cnotcontains 'write_file(.cache)' -or
    $taskInstalled.userSettings.globalPermissionGrants.allow -cnotcontains 'read_file(.vscode)') {
    throw 'Active host did not mount delegated protected-path grants'
}
if ($taskInstalled.userSettings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_DEFAULT' -or !$taskInstalled.userSettings.enableTerminalSandbox -or $taskInstalled.userSettings.autoExecutionPolicy -ne 'CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX') { throw 'Native Auto review was not replaced by sandboxed Default mode' }
$taskProject = Get-Content -Encoding UTF8 -LiteralPath $taskProjectFile -Raw | ConvertFrom-Json
if ($taskProject.settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_DEFAULT' -or $taskProject.permissionGrants.permissionGrants.ask[0] -ne 'command(rm)') { throw 'Project Auto migration changed explicit rules' }

$taskPlugin = Join-Path $taskConfig 'plugins/gravity-guardian'
$taskReview = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json
if ($taskReview.model -ne 'codex-auto-review' -or !$taskReview.enableNativeRouting -or !(Test-Path -LiteralPath $taskReview.policyDirectory)) { throw 'Installed runtime configuration invalid' }
if ($taskReview.reviewerBackend -ne 'NativeGuardian' -or !$taskReview.enableNativeState -or !(Test-Path -LiteralPath $taskReview.guardianPath)) { throw 'Native Guardian was not installed as the selected backend' }
if (![string]::IsNullOrEmpty($taskReview.proxy)) { throw 'Default open-source proxy must be empty' }
foreach ($expectedAsset in @('pricing.json', 'update-config.json', 'app/GravityGuardian.exe', 'scripts/Apply-Update.ps1')) {
    if (!(Test-Path -LiteralPath (Join-Path $taskPlugin $expectedAsset) -PathType Leaf)) { throw ('Missing expected panel/update asset: ' + $expectedAsset) }
}
if (Test-Path -LiteralPath (Join-Path $taskPlugin 'rules/project-authorizations.md')) { throw 'Deprecated project-authorizations rule file should not be installed' }
if (Test-Path -LiteralPath (Join-Path $taskPlugin 'rules/antigravity-scratch.md')) { throw 'Deprecated antigravity-scratch rule file should not be installed' }
if (!(Test-Path -LiteralPath (Join-Path $taskPlugin 'host-protected-paths.json') -PathType Leaf)) { throw 'Missing host-protected-paths.json catalog' }
$taskInstalledHooks = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'hooks.json') -Raw | ConvertFrom-Json
if ($null -ne $taskInstalledHooks.'gravity-guardian'.PreInvocation) { throw 'Installed hooks.json should not register PreInvocation' }
if ($taskReview.escalateAuthorizedDenials -ne $true -or $taskReview.delegateProtectedPaths -ne $true) { throw 'Default escalateAuthorizedDenials and delegateProtectedPaths must be true' }
if ($taskReview.reviewTimeoutSeconds -ne 90 -or $taskReview.hookTimeoutSeconds -ne 100 -or $taskInstalledHooks.'gravity-guardian'.PreToolUse[0].hooks[0].timeout -ne 120) { throw 'Nested review, client, and native hook deadlines are not coordinated' }

& (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin
$taskReviewPath = Join-Path $taskPlugin 'approval.json'
$taskFixtureHome = Join-Path $taskFixture '.codex'
New-Item -ItemType Directory -Path $taskFixtureHome -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $taskFixtureHome 'config.toml'), 'cli_auth_credentials_store = "file"')
[IO.File]::WriteAllText((Join-Path $taskFixtureHome 'auth.json'), '{"auth_mode":"apikey","OPENAI_API_KEY":"local-test-only"}')
$taskCustomConfig = Get-Content -Encoding UTF8 -LiteralPath $taskReviewPath -Raw | ConvertFrom-JsonHashtable
$taskCustomConfig.codexHome = $taskFixtureHome
$taskCustomConfig | ConvertTo-Json -Depth 20 | Set-Utf8NoBom -LiteralPath $taskReviewPath -Encoding utf8
& (Join-Path $PSScriptRoot 'Doctor.ps1') -DataDirectory $taskData
$taskRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
$taskAssembly = Join-Path $taskPlugin 'scripts/gravity-guardian.dll'
$taskDetect = & $taskRuntime $taskAssembly detect --config $taskReviewPath --gemini-root $taskGemini | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskDetect.nativeAuth.status -ne 'credentials_found' -or $taskDetect.nativeAuth.storeMode -ne 'file') {
    throw 'Native discovery did not read the isolated credential fixture'
}
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
$taskCustomConfig.reviewerBackend = 'Cli'
$taskCustomConfig.codexPath = $(if ($env:AG_TEST_CLI_TRIPWIRE) { $env:AG_TEST_CLI_TRIPWIRE } else { Join-Path $taskFixture 'missing-codex.exe' })
$taskCustomConfig.enableReviewerSessions = $true
$taskCustomConfig.enableNativeState = $false
$taskCustomConfig | ConvertTo-Json -Depth 20 | Set-Utf8NoBom -LiteralPath (Join-Path $taskPlugin 'approval.json') -Encoding utf8
$taskOldPanel = Join-Path $taskData 'panel-settings.json'
$taskOldPanelConfig = Get-Content -Encoding UTF8 -LiteralPath $taskOldPanel -Raw | ConvertFrom-JsonHashtable
$taskOldPanelConfig.codexPath = $taskCustomConfig.codexPath
$taskOldPanelConfig.autoCheckUpdates = $false
$taskOldPanelConfig | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskOldPanel
$taskDetect = & $taskRuntime $taskAssembly detect --config $taskReviewPath --gemini-root $taskGemini | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskDetect.nativeAuth.status -ne 'credentials_found') { throw 'Legacy configuration did not use the native credential check' }
$taskPanel = Join-Path $taskPlugin 'app/GravityGuardian.exe'
$taskPanelOutput = & $taskPanel --self-test --plugin-dir $taskPlugin --data-dir $taskData --gemini-root $taskGemini | ForEach-Object { $_ }
$taskPanelOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or !($taskPanelOutput -join "`n").Contains('PASS panel detected the installed Guardian')) {
    throw 'Panel discovery failed using the installed Guardian and legacy configuration'
}
$taskAfterPanel = Get-Content -Encoding UTF8 -LiteralPath $taskOldPanel -Raw | ConvertFrom-JsonHashtable
if ($taskAfterPanel.ContainsKey('codexPath') -or $taskAfterPanel.autoCheckUpdates) { throw 'Panel discovery lost a preference or retained a CLI path' }
$taskOldPanelConfig | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskOldPanel
$taskGuardDirectory = Join-Path $taskData 'denial-guard'
New-Item -ItemType Directory -Path $taskGuardDirectory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $taskGuardDirectory 'test-state.txt'), 'persistent protection sentinel')
$taskGrantDirectory = Join-Path $taskData 'project-authorizations'
$taskGrantFile = Join-Path $taskGrantDirectory (('a' * 64) + '.json')
$taskGrantFixture = '{"grants":{"0123456789ab":"fixture scope"},"handled":{}}'
New-Item -ItemType Directory -Path $taskGrantDirectory -Force | Out-Null
[IO.File]::WriteAllText($taskGrantFile, $taskGrantFixture)

$taskPaused = & $taskRuntime $taskAssembly takeover --config $taskReviewPath --enabled false | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskPaused.takeoverEnabled -ne $false) { throw 'Could not pause approval takeover before repair' }
$taskPausedConfig = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskConfig 'config.json') -Raw | ConvertFrom-Json
if ($taskPausedConfig.userSettings.globalPermissionGrants.allow -cnotcontains 'command(git status)' -or
    $taskPausedConfig.userSettings.globalPermissionGrants.allow -ccontains 'read_file(.git)' -or
    $taskPausedConfig.userSettings.globalPermissionGrants.allow -ccontains 'write_file(.cache)') {
    throw 'Pausing takeover did not revoke delegated protected-path grants cleanly'
}

& (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData @taskExecutables -ReviewRouting ModelOnly -UseVerifiedCopyCommit
$taskUpgradeManifest = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskData 'installation.json') -Raw | ConvertFrom-Json
if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json).enableNativeRouting) { throw 'ModelOnly fallback did not disable routing' }
$taskMigrated = Get-Content -Encoding UTF8 -LiteralPath $taskReviewPath -Raw | ConvertFrom-JsonHashtable
if ($taskMigrated.reviewerBackend -ne 'NativeGuardian' -or !$taskMigrated.enableNativeState -or
    $taskMigrated.ContainsKey('codexPath') -or $taskMigrated.ContainsKey('enableReviewerSessions') -or
    $taskMigrated.codexHome -ne $taskFixtureHome) { throw 'Legacy config migration did not preserve auth or remove CLI settings' }
$taskMigratedPanel = Get-Content -Encoding UTF8 -LiteralPath $taskOldPanel -Raw | ConvertFrom-JsonHashtable
if ($taskMigratedPanel.ContainsKey('codexPath') -or $taskMigratedPanel.autoCheckUpdates) { throw 'Panel config migration lost a preference or retained a CLI path' }
Write-Host 'PASS install/repair migrated a CLI configuration and retained the native credential location'
if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'approval.json') -Raw | ConvertFrom-Json).futureCompatibleSetting -ne 'preserved-on-upgrade') { throw 'Upgrade discarded an unknown compatible setting' }
if ([IO.File]::ReadAllText((Join-Path $taskGuardDirectory 'test-state.txt')) -ne 'persistent protection sentinel') { throw 'Upgrade reset persistent protection state' }
if ([IO.File]::ReadAllText($taskGrantFile) -cne $taskGrantFixture) { throw 'Upgrade changed stored project authorizations' }
if ($taskUpgradeManifest.backupDirectory -ne $taskFirstManifest.backupDirectory) { throw 'Upgrade lost the original restoration backup' }
if (@($taskUpgradeManifest.reviewModeChanges).Count -ne 3) { throw 'Upgrade lost native review-mode restoration records' }
$taskAfterRepair = & $taskRuntime $taskAssembly takeover --config $taskReviewPath | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskAfterRepair.takeoverEnabled -ne $false) { throw 'Repair resumed paused approval takeover' }
$taskResumed = & $taskRuntime $taskAssembly takeover --config $taskReviewPath --enabled true | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskResumed.takeoverEnabled -ne $true) { throw 'Could not resume approval takeover after repair' }
$taskResumedConfig = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskConfig 'config.json') -Raw | ConvertFrom-Json
if ($taskResumedConfig.userSettings.globalPermissionGrants.allow -cnotcontains 'read_file(.git)' -or
    $taskResumedConfig.userSettings.globalPermissionGrants.allow -cnotcontains 'write_file(.cache)') {
    throw 'Resuming takeover did not restore delegated protected-path grants'
}

& (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin

$taskUserMode = Get-Content -Encoding UTF8 -LiteralPath $taskUserModeFile -Raw | ConvertFrom-JsonHashtable
$taskUserMode.settings.permissionPreset = 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW'
$taskUserMode | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskUserModeFile -Encoding utf8

$taskInstalledUninstaller = Join-Path $taskPlugin 'scripts/Uninstall.ps1'
$taskPaused = & $taskRuntime $taskAssembly takeover --config $taskReviewPath --enabled false | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskPaused.takeoverEnabled -ne $false) { throw 'Could not pause approval takeover before uninstall' }
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
if (!(Test-Path -LiteralPath $taskGrantFile)) { throw 'Uninstall preview deleted project authorizations' }
if (!(Test-Path -LiteralPath (Join-Path $taskData 'approval-takeover-paused') -PathType Leaf)) { throw 'Uninstall preview removed the takeover setting' }
if (!(Get-Process -Name dotnet -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $taskHostPath })) {
    throw 'Approval host was not running before uninstall'
}

# The native panel starts Windows PowerShell from outside the installation and then exits.
$taskWindowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$taskPanelAsset = Join-Path $taskPlugin 'app/GravityGuardian.exe'
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
if (!$taskRestored.sidecars.other.enabled -or $null -ne $taskRestored.sidecars.'gravity-guardian/reviewer') { throw 'Uninstall affected another sidecar' }
if ($taskRestored.userSettings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_AUTO' -or $null -ne $taskRestored.userSettings.enableTerminalSandbox -or $null -ne $taskRestored.userSettings.autoExecutionPolicy) { throw 'Uninstall lost original native mode or absent fields' }
if (@($taskRestored.userSettings.globalPermissionGrants.allow) -cne @('command(git status)')) { throw 'Uninstall left delegated protected-path grants or removed user allow rule' }
$taskRestoredProject = Get-Content -Encoding UTF8 -LiteralPath $taskProjectFile -Raw | ConvertFrom-Json
if ($taskRestoredProject.settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_AUTO' -or $null -ne $taskRestoredProject.settings.enableTerminalSandbox) { throw 'Project native mode was not restored' }
if ((Get-Content -Encoding UTF8 -LiteralPath $taskUserModeFile -Raw | ConvertFrom-Json).settings.permissionPreset -ne 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW') { throw 'Uninstall overwrote later user mode selection' }

Write-Host 'PASS Windows PowerShell installed uninstaller removed the program and all app data, and restored original settings'
$global:LASTEXITCODE = 0
