[CmdletBinding()]
param(
    [string]$GeminiRoot = (Join-Path $env:USERPROFILE '.gemini'),
    [string]$DataDirectory = '',
    [string]$AntigravityPath = '',
    [string]$Proxy = '',
    [ValidateSet('Codex','Preserve')][string]$ReviewMode = 'Codex',
    [ValidateSet('Conservative','ModelOnly')][string]$ReviewRouting = 'Conservative',
    [switch]$EnableDetailedLogs,
    [switch]$PlanOnly,
    [switch]$NoStart,
    [switch]$UseVerifiedCopyCommit,
    [string]$BundlePath = '',
    [int]$WaitPid = 0,
    [switch]$RelaunchPanel,
    [switch]$ShowResult,
    [switch]$CleanupBundlePath
)
$ErrorActionPreference = 'Stop'

function Show-InstallResult([string]$Message, [bool]$Succeeded) {
    if (!$ShowResult) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($Succeeded) { 'Information' } else { 'Error' }
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Gravity Guardian', 'OK', $icon)
}

trap {
    if (!$ShowResult) { break }
    Show-InstallResult ("Install or repair did not finish." + [Environment]::NewLine + $_.Exception.Message) $false
    exit 1
}

. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
    $DataDirectory = Join-Path $GeminiRoot 'gravity-guardian-data'
}

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskBundle = if (![string]::IsNullOrWhiteSpace($BundlePath)) {
    [IO.Path]::GetFullPath($BundlePath)
} else {
    $candidate = Join-Path $taskRoot 'artifacts/gravity-guardian'
    if (!(Test-Path -LiteralPath (Join-Path $candidate 'scripts/gravity-guardian.dll')) -and (Test-Path -LiteralPath (Join-Path $taskRoot 'scripts/gravity-guardian.dll'))) {
        $taskRoot
    } else {
        $candidate
    }
}
$taskData = [IO.Path]::GetFullPath($DataDirectory)
$taskCleanupBundle = $false
if ($CleanupBundlePath -and ![string]::IsNullOrWhiteSpace($BundlePath)) {
    $taskRepairPrefix = [IO.Path]::GetFullPath((Join-Path $taskData 'updates')) + [IO.Path]::DirectorySeparatorChar
    if ($taskBundle.StartsWith($taskRepairPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $taskBundle -Leaf) -like 'repair-*') {
        $taskCleanupBundle = $true
    }
}

try {
if ($WaitPid -gt 0) {
    $taskWaitProc = $null
    try { $taskWaitProc = [Diagnostics.Process]::GetProcessById($WaitPid) } catch [ArgumentException] {}
    if ($taskWaitProc) {
        try {
            if (!$taskWaitProc.WaitForExit(15000)) {
                throw 'Timed out waiting for GravityGuardian to exit before repairing.'
            }
        } finally { $taskWaitProc.Dispose() }
    }
}
$taskDistribution = Get-ApprovalDistribution $taskBundle
$taskBundleAssembly = Join-Path $taskBundle 'scripts/gravity-guardian.dll'

$taskConfigRoot = [IO.Path]::GetFullPath((Join-Path $GeminiRoot 'config'))
$taskPlugin = [IO.Path]::GetFullPath((Join-Path $taskConfigRoot 'plugins/gravity-guardian'))
$taskLegacyPlugin = Join-Path $taskConfigRoot 'plugins/codex-approval'
if (Test-Path -LiteralPath $taskLegacyPlugin) {
    throw 'Legacy Gravity Steward installation detected. Exit Antigravity and run the OLD package scripts/Uninstall.ps1 WITHOUT -PurgeData first. Then install Gravity Guardian; use -DataDirectory with the retained data path to keep historical logs. See docs/release-0.6.6.md.'
}
$taskBundleRuntime = Resolve-ApprovalRuntime $taskBundle -Installed:($taskBundle -eq $taskPlugin)
$taskRuntime = if ($taskDistribution -eq 'lite') { $taskBundleRuntime } else { Join-Path $taskPlugin 'runtime/dotnet.exe' }
if ($taskPlugin -ne [IO.Path]::GetFullPath((Join-Path $taskConfigRoot 'plugins/gravity-guardian'))) { throw 'Invalid plugin target' }
$taskAppConfig = Join-Path $taskConfigRoot 'config.json'

foreach ($taskRequired in @($taskBundleAssembly, $taskBundleRuntime, $taskAppConfig)) {
    if (!(Test-Path -LiteralPath $taskRequired -PathType Leaf)) { throw ('Required file missing: ' + $taskRequired) }
}

$taskOldApprovalPath = Join-Path $taskPlugin 'approval.json'
$taskOldApproval = if (Test-Path -LiteralPath $taskOldApprovalPath) {
    Get-Content -Encoding UTF8 -LiteralPath $taskOldApprovalPath -Raw | ConvertFrom-JsonHashtable
}
if ($taskOldApproval -and !$PSBoundParameters.ContainsKey('DataDirectory') -and $taskOldApproval.dataDirectory) {
    $DataDirectory = [string]$taskOldApproval.dataDirectory
}
if ($taskOldApproval -and !$PSBoundParameters.ContainsKey('Proxy')) { $Proxy = [string]$taskOldApproval.proxy }
if ([string]::IsNullOrWhiteSpace($AntigravityPath)) {
    $taskPrevError = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $taskDetectRaw = & $taskBundleRuntime $taskBundleAssembly detect --gemini-root $GeminiRoot --data-dir $DataDirectory --skip-login-check 2>$null
        if ($LASTEXITCODE -eq 0 -and $taskDetectRaw) {
            $taskDetected = ($taskDetectRaw -join [Environment]::NewLine) | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($AntigravityPath) -and $taskDetected.antigravity.found) {
                $AntigravityPath = [string]$taskDetected.antigravity.path
            }
        }
    } catch {} finally { $ErrorActionPreference = $taskPrevError }
}

if (![string]::IsNullOrWhiteSpace($AntigravityPath) -and !(Test-Path -LiteralPath $AntigravityPath -PathType Leaf)) {
    throw ('Specified Antigravity executable not found: ' + $AntigravityPath)
}

$taskConfigHash = (Get-FileHash -LiteralPath $taskAppConfig -Algorithm SHA256).Hash
$taskAppState = Get-Content -Encoding UTF8 -LiteralPath $taskAppConfig -Raw | ConvertFrom-JsonHashtable
if (!$taskAppState.ContainsKey('userSettings')) { throw 'Unknown Antigravity settings layout' }
$taskSidecarId = 'gravity-guardian/reviewer'
$taskOldSidecar = if ($taskAppState.sidecars) { $taskAppState.sidecars[$taskSidecarId] } else { $null }

$taskPlan = @{
    pluginDirectory = $taskPlugin; applicationConfig = $taskAppConfig; dataDirectory = $DataDirectory
    antigravityPath = $AntigravityPath; proxy = $Proxy
    distribution = $taskDistribution; dotnetPath = $taskRuntime
    model = 'codex-auto-review'; effort = 'low'; reviewMode = $ReviewMode; reviewRouting = $ReviewRouting; reviewerBackend = 'NativeGuardian'
    commitMethod = $(if ($UseVerifiedCopyCommit) { 'verified-copy' } else { 'directory-move' })
    changes = @('Install official plugin folder', 'Enable only gravity-guardian/reviewer sidecar', 'Keep Antigravity network and proxy untouched')
    preserved = @('All existing Allow/Ask/Deny rules', 'Unrelated project settings', 'Existing Codex config and login')
}
if ($ReviewMode -eq 'Codex') { $taskPlan.changes += 'Use Default + sandbox globally and for explicit Auto project overrides; Codex Hook owns automatic review' }
if ($PlanOnly) { $taskPlan | ConvertTo-Json -Depth 8; return }

if (!(Test-Path -LiteralPath (Join-Path $taskBundle 'native/ag-guardian-host.exe'))) {
    throw 'Native Guardian executable is missing; build the complete package first'
}
$taskDefaultConfig = Join-Path $env:USERPROFILE '.gemini/config'
$taskRunningApps = @(Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue | Where-Object {
    if (![string]::IsNullOrWhiteSpace($AntigravityPath)) {
        [IO.Path]::GetFileName($AntigravityPath) -ieq 'Antigravity.exe' -and $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($AntigravityPath)
    } else {
        $taskConfigRoot -ieq $taskDefaultConfig
    }
})
if ($taskRunningApps.Count) { throw 'Antigravity is still running. Finish active tasks and fully exit before upgrading; no files were replaced.' }

New-Item -ItemType Directory -Path $taskData -Force | Out-Null
$taskPreviousManifestPath = Join-Path $taskData 'installation.json'
$taskPreviousManifest = if (Test-Path -LiteralPath $taskPreviousManifestPath) { Get-Content -Encoding UTF8 -LiteralPath $taskPreviousManifestPath -Raw | ConvertFrom-JsonHashtable } else { $null }
if ($taskPreviousManifest -and [IO.Path]::GetFullPath($taskPreviousManifest.pluginDirectory) -ne $taskPlugin) { throw 'Existing install manifest belongs to another target' }

$taskBackup = Join-Path $taskData ('backups/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $taskBackup -Force | Out-Null
Copy-Item -LiteralPath $taskAppConfig -Destination (Join-Path $taskBackup 'config.json.original')

$taskStage = Join-Path $taskData ('staging-' + [Guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $taskBundle -Destination $taskStage -Recurse
Set-ApprovalHookRuntime -Bundle $taskStage -Runtime $taskRuntime
$taskInstalledPricing = Join-Path $taskPlugin 'pricing.json'
if ($taskOldApproval -and (Test-Path -LiteralPath $taskInstalledPricing -PathType Leaf)) {
    Copy-Item -LiteralPath $taskInstalledPricing -Destination (Join-Path $taskStage 'pricing.json') -Force
}

$taskResolvedAntigravity = if ([string]::IsNullOrWhiteSpace($AntigravityPath)) { '' } else { [IO.Path]::GetFullPath($AntigravityPath) }
$taskCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

$taskApproval = @{
    model = 'codex-auto-review'; effort = 'low'; proxy = $Proxy
    codexHome = $taskCodexHome; dataDirectory = $taskData
    antigravityConfigDirectory = $taskConfigRoot; policyDirectory = (Join-Path $taskPlugin 'policy/effective-codex')
    transcriptRoots = @((Join-Path $GeminiRoot 'antigravity/brain'), (Join-Path $GeminiRoot 'antigravity-cli/brain'), (Join-Path $GeminiRoot 'antigravity-ide/brain'))
    reviewTimeoutSeconds = 90; hookTimeoutSeconds = 100; maxInputBytes = 1048576; maxQueue = 8
    enableNativeRouting = ($ReviewRouting -eq 'Conservative')
    enableNativeState = $true; nativeStateLogPath = (Join-Path $env:APPDATA 'Antigravity/logs/main.log'); nativeStateTimeoutMilliseconds = 4000; maxNativeHistoryBytes = 8388608
    enableNativeAskHandoff = $false
    escalateAuthorizedDenials = $true
    delegateProtectedPaths = $true
    enableDetailedLogs = [bool]$EnableDetailedLogs; maxLogSegmentBytes = 16777216
}

if ($taskOldApproval) {
    $taskInstallOptions = @{
        proxy = 'Proxy'; enableDetailedLogs = 'EnableDetailedLogs'; enableNativeRouting = 'ReviewRouting'
    }
    foreach ($taskKey in $taskOldApproval.Keys) {
        if ($taskKey -in @('dataDirectory','antigravityConfigDirectory','model','effort')) { continue }
        if ($taskInstallOptions.ContainsKey($taskKey) -and $PSBoundParameters.ContainsKey($taskInstallOptions[$taskKey])) { continue }
        $taskApproval[$taskKey] = $taskOldApproval[$taskKey]
    }
}
Update-ApprovalReviewerConfig -Config $taskApproval -PluginDirectory $taskPlugin
$taskApproval | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath (Join-Path $taskStage 'approval.json') -Encoding utf8

$taskSidecar = Join-Path $taskStage 'sidecars/reviewer'
New-Item -ItemType Directory -Path $taskSidecar -Force | Out-Null
@{command = $taskRuntime; args = @((Join-Path $taskPlugin 'scripts/gravity-guardian.dll'), 'supervise', '--config', (Join-Path $taskPlugin 'approval.json')); restart_policy = 'on-failure'; display_name = 'Gravity Guardian'; description = 'Native codex-auto-review permission reviewer'} |
    ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath (Join-Path $taskSidecar 'sidecar.json') -Encoding utf8

$taskAssembly = Join-Path $taskPlugin 'scripts/gravity-guardian.dll'
$taskReviewConfig = Join-Path $taskPlugin 'approval.json'

$taskHadPrevious = Test-Path -LiteralPath $taskPlugin
if ($taskHadPrevious) {
    $taskExisting = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw | ConvertFrom-Json
    if ($taskExisting.name -ne 'gravity-guardian') { throw 'Refusing to replace a different plugin' }
    $taskOldRuntime = Resolve-ApprovalRuntime $taskPlugin -Installed
    if ((Get-FileHash -LiteralPath $taskAppConfig -Algorithm SHA256).Hash -ne $taskConfigHash) { throw 'Application settings changed during install; rerun without overwriting them' }
    [IO.File]::WriteAllText((Join-Path $taskData 'uninstalled'), 'upgrade in progress')
    Start-Sleep -Milliseconds 2200
    $taskOldHostId = $null
    $taskPrevError = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $taskOldStatus = & $taskOldRuntime $taskAssembly status --config $taskReviewConfig 2>$null
        if ($LASTEXITCODE -eq 0 -and $taskOldStatus) { $taskOldHostId = (($taskOldStatus -join [Environment]::NewLine) | ConvertFrom-Json).pid }
        & $taskOldRuntime $taskAssembly stop --config $taskReviewConfig 2>$null | Out-Null
    } catch {} finally { $ErrorActionPreference = $taskPrevError }
    if ($taskOldHostId) {
        $taskOldProcess = $null
        try { $taskOldProcess = [Diagnostics.Process]::GetProcessById([int]$taskOldHostId) } catch [ArgumentException] {}
        if ($taskOldProcess) { try { if (!$taskOldProcess.WaitForExit(10000)) { throw 'Approval host is still shutting down; no plugin files were replaced' } } finally { $taskOldProcess.Dispose() } }
    }
    # Stop any running tray panel from the plugin folder before replacing files.
    Get-Process -Name 'GravityGuardian' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($taskPlugin + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        try { $_.Kill(); $_.WaitForExit(5000) } catch {}
    }
    Clear-DelegatedProtectedGrants -ConfigRoot $taskConfigRoot -DataDirectory $taskData
    $taskConfigHash = (Get-FileHash -LiteralPath $taskAppConfig -Algorithm SHA256).Hash
    $taskAppState = Get-Content -Encoding UTF8 -LiteralPath $taskAppConfig -Raw | ConvertFrom-JsonHashtable
    if (!$taskAppState.ContainsKey('userSettings')) { throw 'Unknown Antigravity settings layout' }
    $taskOldSidecar = if ($taskAppState.sidecars) { $taskAppState.sidecars[$taskSidecarId] } else { $null }
    Copy-Item -LiteralPath $taskAppConfig -Destination (Join-Path $taskBackup 'config.json.original') -Force
}

if ((Get-FileHash -LiteralPath $taskAppConfig -Algorithm SHA256).Hash -ne $taskConfigHash) { throw 'Application settings changed during install; rerun without overwriting them' }

if ($taskHadPrevious) {
    $taskReplacedName = if ($taskPreviousManifest) { 'replaced-plugin' } else { 'previous-plugin' }
    $taskReplacedPath = [IO.Path]::GetFullPath((Join-Path $taskBackup $taskReplacedName))
    if (!$taskReplacedPath.StartsWith($taskBackup + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $taskReplacedPath)) { throw 'Invalid previous-plugin backup target' }
    Move-Item -LiteralPath $taskPlugin -Destination $taskReplacedPath
}
New-Item -ItemType Directory -Path (Split-Path $taskPlugin) -Force | Out-Null

$taskCopyStarted = $false
try {
    if ($UseVerifiedCopyCommit) {
        if (Test-Path -LiteralPath $taskPlugin) { throw 'Plugin target unexpectedly exists before verified copy' }
        $taskCopyStarted = $true
        Copy-Item -LiteralPath $taskStage -Destination $taskPlugin -Recurse
        $taskStageFiles = @(Get-ChildItem -LiteralPath $taskStage -Recurse -File -Force)
        foreach ($taskFile in $taskStageFiles) {
            $taskRelative = Get-RelativePathCompat $taskStage $taskFile.FullName
            $taskInstalledFile = [IO.Path]::GetFullPath((Join-Path $taskPlugin $taskRelative))
            if (!$taskInstalledFile.StartsWith($taskPlugin + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Copy verification target escaped plugin directory' }
            if (!(Test-Path -LiteralPath $taskInstalledFile -PathType Leaf) -or (Get-FileHash -LiteralPath $taskInstalledFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $taskFile.FullName -Algorithm SHA256).Hash) { throw ('Installed copy integrity mismatch: ' + $taskRelative) }
        }
        if (@(Get-ChildItem -LiteralPath $taskPlugin -Recurse -File -Force).Count -ne $taskStageFiles.Count) { throw 'Installed copy contains unexpected files' }
        Remove-Item -LiteralPath $taskStage -Recurse -Force
    } else {
        Move-Item -LiteralPath $taskStage -Destination $taskPlugin
    }
}
catch {
    if ($UseVerifiedCopyCommit -and $taskCopyStarted -and (Test-Path -LiteralPath $taskPlugin)) {
        $taskFailedCopy = [IO.Path]::GetFullPath((Join-Path $taskBackup 'failed-plugin-copy'))
        if ($taskPlugin -ne [IO.Path]::GetFullPath((Join-Path $taskConfigRoot 'plugins/gravity-guardian')) -or !$taskFailedCopy.StartsWith($taskBackup + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Rollback target escaped installation directories' }
        Move-Item -LiteralPath $taskPlugin -Destination $taskFailedCopy
    }
    if ($taskHadPrevious -and !(Test-Path -LiteralPath $taskPlugin)) { Move-Item -LiteralPath $taskReplacedPath -Destination $taskPlugin }
    throw
}

if (!$taskAppState.sidecars) { $taskAppState.sidecars = @{} }
$taskAppState.sidecars[$taskSidecarId] = @{ enabled = $true }
$taskTemp = $taskAppConfig + '.gravity-guardian.tmp'
$taskAppState | ConvertTo-Json -Depth 100 | Set-Utf8NoBom -LiteralPath $taskTemp -Encoding utf8
if ((Get-FileHash -LiteralPath $taskAppConfig -Algorithm SHA256).Hash -ne $taskConfigHash) { throw 'Application settings changed before commit; original backup is available' }
Move-Item -LiteralPath $taskTemp -Destination $taskAppConfig -Force

$taskStopMarker = Join-Path $taskData 'uninstalled'
if (Test-Path -LiteralPath $taskStopMarker) { Remove-Item -LiteralPath $taskStopMarker }

$taskRestoreBackup = if ($taskPreviousManifest) { $taskPreviousManifest.backupDirectory } else { $taskBackup }
$taskRestorePreviousPlugin = if ($taskPreviousManifest) { [bool]$taskPreviousManifest.hadPreviousPlugin } else { [bool]$taskHadPrevious }
$taskRestoreSidecar = if ($taskPreviousManifest) { $taskPreviousManifest.oldSidecar } else { $taskOldSidecar }
$taskModeChanges = if ($taskPreviousManifest.reviewModeChanges) { @($taskPreviousManifest.reviewModeChanges) } else { @() }
if ($ReviewMode -eq 'Codex') { $taskModeChanges = @(Set-CodexReviewMode -ConfigRoot $taskConfigRoot -BackupDirectory $taskBackup -PreviousChanges $taskModeChanges) }

$taskManifest = @{
    installedAt = [DateTime]::UtcNow.ToString('O'); pluginDirectory = $taskPlugin; configRoot = $taskConfigRoot
    geminiRoot = [IO.Path]::GetFullPath($GeminiRoot); antigravityPath = $taskResolvedAntigravity
    distribution = $taskDistribution; dotnetPath = $taskRuntime
    backupDirectory = $taskRestoreBackup; latestUpgradeBackup = $taskBackup
    hadPreviousPlugin = $taskRestorePreviousPlugin; oldSidecar = $taskRestoreSidecar; sidecarId = $taskSidecarId
    reviewMode = $ReviewMode; reviewModeChanges = @($taskModeChanges)
}
# A prior background-only installation may have installed or modified a desktop launcher.
foreach ($key in @('launcherPath', 'installedLauncherHash', 'launcherExisted')) {
    if ($taskPreviousManifest -and $taskPreviousManifest.ContainsKey($key)) {
        $taskManifest[$key] = $taskPreviousManifest[$key]
    }
}
$taskManifest | ConvertTo-Json -Depth 20 | Set-Utf8NoBom -LiteralPath (Join-Path $taskData 'installation.json') -Encoding utf8

# Sync panel-settings.json while preserving existing panel preferences.
$taskPanelPath = Join-Path $taskData 'panel-settings.json'
$taskPanel = if (Test-Path -LiteralPath $taskPanelPath) { Get-Content -Encoding UTF8 -LiteralPath $taskPanelPath -Raw | ConvertFrom-JsonHashtable } else { @{} }
$taskPanel.pluginDirectory = $taskPlugin
$taskPanel.dataDirectory = $taskData
$taskPanel.geminiRoot = [IO.Path]::GetFullPath($GeminiRoot)
if ($taskResolvedAntigravity) { $taskPanel.antigravityPath = $taskResolvedAntigravity }
elseif (!$taskPanel.ContainsKey('antigravityPath')) { $taskPanel.antigravityPath = '' }
$taskPanel.Remove('codexPath')
if (!$taskPanel.ContainsKey('autoCheckUpdates')) { $taskPanel.autoCheckUpdates = $true }
if (!$taskPanel.ContainsKey('autoUpdate')) { $taskPanel.autoUpdate = $true }
$taskPanel | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath $taskPanelPath -Encoding utf8

if (!$NoStart) {
    $taskServiceLogs = Join-Path $taskData 'service'
    New-Item -ItemType Directory -Path $taskServiceLogs -Force | Out-Null
    $taskStartupId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
    $taskStartupArgs = @(('"' + $taskAssembly + '"'), 'ensure', '--config', ('"' + $taskReviewConfig + '"'))
    $taskStartup = Start-Process -FilePath $taskRuntime -ArgumentList $taskStartupArgs -WorkingDirectory $taskPlugin -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskServiceLogs ($taskStartupId + '.stdout.log')) -RedirectStandardError (Join-Path $taskServiceLogs ($taskStartupId + '.stderr.log')) -PassThru
    try {
        if (!$taskStartup.WaitForExit(30000)) { try { $taskStartup.Kill() } catch {}; throw 'Installed, but approval service startup timed out; run Doctor.ps1' }
        if ($null -ne $taskStartup.ExitCode -and $taskStartup.ExitCode -ne 0) { throw 'Installed, but approval service could not start; run Doctor.ps1' }
    } finally { $taskStartup.Dispose() }
    $taskPrevError = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & $taskRuntime $taskAssembly status --config $taskReviewConfig 2>$null } finally { $ErrorActionPreference = $taskPrevError }
    if ($LASTEXITCODE -ne 0) { throw 'Installed, but approval service could not start; run Doctor.ps1' }
}

if ($RelaunchPanel) {
    $panelExe = Join-Path $taskPlugin 'app/GravityGuardian.exe'
    if (Test-Path -LiteralPath $panelExe -PathType Leaf) {
        Start-Process -FilePath $panelExe -WorkingDirectory (Split-Path $panelExe -Parent) -ArgumentList @('--plugin-dir', ('"' + $taskPlugin + '"'), '--data-dir', ('"' + $taskData + '"'), '--gemini-root', ('"' + [IO.Path]::GetFullPath($GeminiRoot) + '"')) | Out-Null
    }
} elseif ($ShowResult) {
    Show-InstallResult 'Gravity Guardian 已完成安装并启用审批服务。' $true
}

$taskPlan | ConvertTo-Json -Depth 8
Write-Host "Installed. Backup: $taskBackup"
$global:LASTEXITCODE = 0
} finally {
    if ($taskCleanupBundle -and (Test-Path -LiteralPath $taskBundle)) {
        Remove-Item -LiteralPath $taskBundle -Recurse -Force -ErrorAction SilentlyContinue
    }
}
