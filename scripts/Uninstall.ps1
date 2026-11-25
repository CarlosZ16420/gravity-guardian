[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DataDirectory = (Join-Path $env:USERPROFILE '.gemini/codex-approval-data'),
    [switch]$PurgeData,
    [int]$WaitPid,
    [string]$PanelExecutablePath,
    [switch]$ShowResult
)
$ErrorActionPreference = 'Stop'

function Show-UninstallResult([string]$Message, [bool]$Succeeded) {
    if (!$ShowResult) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($Succeeded) { 'Information' } else { 'Error' }
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Gravity Steward', 'OK', $icon)
}

trap {
    if (!$ShowResult) { break }
    Show-UninstallResult ("Uninstall did not finish." + [Environment]::NewLine + $_.Exception.Message) $false
    exit 1
}

. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

function Test-WithinDirectory([string]$Path, [string]$Directory) {
    $prefix = $Directory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint([string]$Path) {
    for ($pathToCheck = $Path; $pathToCheck; $pathToCheck = [IO.Path]::GetDirectoryName($pathToCheck)) {
        $item = Get-Item -LiteralPath $pathToCheck -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Uninstall path contains a symbolic link or junction: $pathToCheck"
        }
    }
}

$taskData = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\', '/')
if ($taskData -eq [IO.Path]::GetPathRoot($taskData).TrimEnd('\', '/')) { throw 'DataDirectory cannot be a drive root' }
$taskManifestPath = Join-Path $taskData 'installation.json'
Assert-NoReparsePoint $taskManifestPath
$taskManifest = Get-Content -Encoding UTF8 -LiteralPath $taskManifestPath -Raw | ConvertFrom-JsonHashtable
$taskConfigRoot = [IO.Path]::GetFullPath($taskManifest.configRoot)
$taskPlugin = [IO.Path]::GetFullPath($taskManifest.pluginDirectory)
$taskExpected = [IO.Path]::GetFullPath((Join-Path $taskConfigRoot 'plugins/codex-approval'))
if ($taskPlugin -ine $taskExpected -or $taskManifest.sidecarId -cne 'codex-approval/reviewer') {
    throw 'Invalid installation manifest target'
}
if ($taskData -ieq $taskConfigRoot -or (Test-WithinDirectory $taskConfigRoot $taskData) -or (Test-WithinDirectory $taskData $taskConfigRoot) -or
    $PSScriptRoot -ieq $taskData -or (Test-WithinDirectory $PSScriptRoot $taskData)) {
    throw 'DataDirectory overlaps application configuration or the uninstall scripts'
}
$taskConfig = Join-Path $taskConfigRoot 'config.json'
$taskBackup = [IO.Path]::GetFullPath($taskManifest.backupDirectory)
$taskBackups = Join-Path $taskData 'backups'
if ([IO.Path]::GetDirectoryName($taskBackup) -ine $taskBackups) { throw 'Invalid installation backup target' }
$taskStopMarker = Join-Path $taskData 'uninstalled'
$taskApproval = Join-Path $taskPlugin 'approval.json'
$taskPluginManifest = Join-Path $taskPlugin 'plugin.json'
foreach ($path in @($taskConfig, $taskStopMarker, $taskApproval, $taskPluginManifest, $taskBackup)) { Assert-NoReparsePoint $path }
if (Test-Path -LiteralPath $taskPluginManifest) {
    $pluginName = (Get-Content -Encoding UTF8 -LiteralPath $taskPluginManifest -Raw | ConvertFrom-Json).name
    if ($pluginName -cne 'codex-approval') { throw 'Refusing to remove a different plugin' }
} elseif ((Test-Path -LiteralPath $taskPlugin) -and !(Test-Path -LiteralPath $taskStopMarker)) {
    throw 'Cannot verify ownership of the installed plugin directory'
}
if (Test-Path -LiteralPath $taskApproval) {
    $taskApprovalSettings = Get-Content -Encoding UTF8 -LiteralPath $taskApproval -Raw | ConvertFrom-JsonHashtable
    if ([IO.Path]::GetFullPath($taskApprovalSettings.dataDirectory).TrimEnd('\', '/') -ine $taskData) {
        throw 'The installed plugin points to a different data directory'
    }
}

if ($PurgeData) {
    # DataDirectory can be custom. Require a known app directory layout before deleting its contents.
    $ownedDirectories = @('backups', 'denial-guard', 'guardian-workspace', 'logs', 'panel', 'project-authorizations', 'reviewer-sessions', 'runtime', 'service', 'updates')
    $ownedFiles = @('approval-takeover-paused', 'delegated-grants.json', 'delegated-grants.lock', 'installation.json', 'panel-settings.json', 'panel-settings.json.tmp', 'stats-cache.json', 'uninstalled')
    $taskDataEntries = @(Get-ChildItem -LiteralPath $taskData -Force)
    foreach ($item in $taskDataEntries) {
        $owned = if ($item.PSIsContainer) {
            $item.Name -in $ownedDirectories -or $item.Name -match '^(staging-[a-f0-9]{32}|uninstalled-plugin-\d{8}-\d{6})$'
        } else {
            $item.Name -in $ownedFiles -or $item.Name -match '^(ag-codex-[a-f0-9]{20}\.lock|stats-cache\.json\.[a-f0-9]{32}\.tmp)$'
        }
        if (!$owned) { throw "Unexpected item in the data directory. Move it out before purging: $($item.FullName)" }
    }
    foreach ($directory in @($taskData, $taskPlugin)) {
        if (!(Test-Path -LiteralPath $directory)) { continue }
        $link = Get-ChildItem -LiteralPath $directory -Force -Recurse |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
        if ($link) { throw "Uninstall directory contains a symbolic link or junction: $($link.FullName)" }
    }
}

$taskLauncher = if ($taskManifest.launcherPath) { [IO.Path]::GetFullPath($taskManifest.launcherPath) }
$taskOriginal = Join-Path $taskBackup 'launcher.bat.original'
$taskRestoreLauncher = $false
$taskCleanLauncher = $null
if ($taskLauncher) {
    Assert-NoReparsePoint $taskLauncher
    Assert-NoReparsePoint $taskOriginal
    if (Test-Path -LiteralPath $taskLauncher -PathType Leaf) {
        $taskRestoreLauncher = (Get-FileHash -LiteralPath $taskLauncher -Algorithm SHA256).Hash -eq $taskManifest.installedLauncherHash
        if (!$taskRestoreLauncher -and $PurgeData -and ([IO.File]::ReadAllText($taskLauncher).IndexOf($taskPlugin, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            throw "The edited launcher still refers to this installation. Remove its plugin references or restore its original from $taskOriginal"
        }
        if ($taskRestoreLauncher -and !(Test-Path -LiteralPath $taskOriginal -PathType Leaf) -and $taskManifest.launcherExisted -ne $false) {
            # Older manifests did not distinguish a new launcher from a missing backup.
            # Preserve the verified launcher and strip the installer's approval startup block.
            $taskLauncherText = [IO.File]::ReadAllText($taskLauncher)
            $taskLine = '"{0}" "{1}" ensure --config "{2}"' -f (Resolve-ApprovalRuntime $taskPlugin -Installed), (Join-Path $taskPlugin 'scripts/ag-approval.dll'), $taskApproval
            $taskBlock = (@($taskLine, 'if errorlevel 1 (', '  echo Codex automatic approval is unavailable. Antigravity has not been started.', '  pause', '  exit /b 1', ')') -join "`r`n") + "`r`n"
            if (!$taskLauncherText.Contains($taskBlock)) { throw 'Launcher backup is missing and its approval startup block could not be identified' }
            $taskCleanLauncher = $taskLauncherText.Replace($taskBlock, '')
        }
    }
}

$taskAction = if ($PurgeData) { 'Uninstall and permanently delete all plug-in data' } else { 'Uninstall and archive plug-in files' }
if (!$PSCmdlet.ShouldProcess("$taskPlugin and $taskData", $taskAction)) { return }

if ($WaitPid) {
    $taskInitiator = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if ($taskInitiator -and $taskInitiator.Path -ieq $PanelExecutablePath -and !$taskInitiator.WaitForExit(10000)) {
        throw 'Close the Gravity Steward panel and retry.'
    }
}

$taskAntigravity = $taskManifest.antigravityPath
$taskDefaultConfig = Join-Path $env:USERPROFILE '.gemini/config'
if (Get-Process -Name Antigravity -ErrorAction SilentlyContinue | Where-Object {
    if ($taskAntigravity) { $_.Path -ieq $taskAntigravity } else { $taskConfigRoot -ieq $taskDefaultConfig }
}) { throw 'Fully exit Antigravity before uninstalling the plugin' }

[IO.File]::WriteAllText($taskStopMarker, 'disabled')
$taskRuntime = if (Test-Path -LiteralPath $taskPlugin) {
    try { Resolve-ApprovalRuntime $taskPlugin -Installed } catch { Write-Warning $_.Exception.Message }
}
$taskAssembly = Join-Path $taskPlugin 'scripts/ag-approval.dll'
$taskGuardian = Join-Path $taskPlugin 'native/ag-guardian-host.exe'
$taskDataPanel = Join-Path $taskData 'panel/CodexApprovalPanel.exe'
$taskInstalledPanel = Join-Path $taskPlugin 'app/CodexApprovalPanel.exe'
$taskPanels = @($taskDataPanel, $taskInstalledPanel, $PanelExecutablePath)
$taskRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$taskRunName = 'AntigravityCodexApproval'
$taskRunEntry = (Get-ItemProperty -LiteralPath $taskRunKey -Name $taskRunName -ErrorAction SilentlyContinue).$taskRunName
if ($taskRunEntry -match '^"([^"]+)" --minimized$' -and ($Matches[1] -in $taskPanels -or $taskConfigRoot -ieq $taskDefaultConfig)) {
    Remove-ItemProperty -LiteralPath $taskRunKey -Name $taskRunName
}
Get-Process -Name CodexApprovalPanel,GravitySteward -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -in $taskPanels } | ForEach-Object {
    if (!$_.HasExited) { $_.Kill() }
    if (!$_.WaitForExit(5000)) { throw 'The approval panel is still running. Close it and retry.' }
}
$taskHostId = $null
if ($taskRuntime -and (Test-Path -LiteralPath $taskApproval -PathType Leaf)) {
    $taskPrevError = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $taskStatus = & $taskRuntime $taskAssembly status --config $taskApproval 2>$null
        if ($LASTEXITCODE -eq 0 -and $taskStatus) { $taskHostId = ($taskStatus | ConvertFrom-Json).pid }
        & $taskRuntime $taskAssembly stop --config $taskApproval 2>$null | Out-Null
    } finally { $ErrorActionPreference = $taskPrevError }
}
$taskBundledRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
Get-Process -Name dotnet,ag-guardian-host -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -in @($taskBundledRuntime, $taskGuardian) -or ($taskHostId -and $_.Id -eq $taskHostId -and $_.Path -ieq $taskRuntime)
} | ForEach-Object {
    if (!$_.WaitForExit(12000)) { throw "The approval process is still running. Close it and retry: $($_.Path)" }
}

Clear-DelegatedProtectedGrants -ConfigRoot $taskConfigRoot -DataDirectory $taskData

if (Test-Path -LiteralPath $taskConfig -PathType Leaf) {
    $taskConfigHash = (Get-FileHash -LiteralPath $taskConfig -Algorithm SHA256).Hash
    $taskState = Get-Content -Encoding UTF8 -LiteralPath $taskConfig -Raw | ConvertFrom-JsonHashtable
    if ($taskState.sidecars -and $taskState.sidecars.ContainsKey($taskManifest.sidecarId)) {
        if ($PurgeData -or $null -eq $taskManifest.oldSidecar) {
            $taskState.sidecars.Remove($taskManifest.sidecarId)
        } else {
            $taskState.sidecars[$taskManifest.sidecarId] = $taskManifest.oldSidecar
        }
        $taskTemp = $taskConfig + '.codex-approval.tmp'
        Assert-NoReparsePoint $taskTemp
        try {
            $taskState | ConvertTo-Json -Depth 100 | Set-Utf8NoBom -LiteralPath $taskTemp -Encoding utf8
            if ((Get-FileHash -LiteralPath $taskConfig -Algorithm SHA256).Hash -ne $taskConfigHash) {
                throw 'Antigravity configuration changed during uninstall. Retry with Antigravity closed.'
            }
            Move-Item -LiteralPath $taskTemp -Destination $taskConfig -Force
        } finally {
            if (Test-Path -LiteralPath $taskTemp) { Remove-Item -LiteralPath $taskTemp -Force }
        }
    }
}
if ($taskManifest.reviewModeChanges) { Restore-CodexReviewMode -ConfigRoot $taskConfigRoot -Changes @($taskManifest.reviewModeChanges) }
if ($taskRestoreLauncher) {
    if ((Get-FileHash -LiteralPath $taskLauncher -Algorithm SHA256).Hash -ne $taskManifest.installedLauncherHash) {
        throw 'The launcher changed during uninstall. Check its plugin references before retrying.'
    }
    if (Test-Path -LiteralPath $taskOriginal -PathType Leaf) {
        Copy-Item -LiteralPath $taskOriginal -Destination $taskLauncher -Force
    } elseif ($null -ne $taskCleanLauncher) {
        [IO.File]::WriteAllText($taskLauncher, $taskCleanLauncher, [Text.UTF8Encoding]::new($false))
        Write-Warning 'Original launcher backup was missing. The launcher now starts Antigravity directly.'
    } else {
        Remove-Item -LiteralPath $taskLauncher -Force
    }
} elseif ($taskLauncher -and (Test-Path -LiteralPath $taskLauncher)) {
    Write-Warning 'Launcher has changed since installation and was preserved.'
}

if ($PurgeData) {
    if (Test-Path -LiteralPath $taskPlugin) { Remove-Item -LiteralPath $taskPlugin -Recurse -Force }
    foreach ($item in $taskDataEntries) {
        if ($item.FullName -notin @($taskManifestPath, $taskStopMarker) -and (Test-Path -LiteralPath $item.FullName)) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }
    $remaining = @(Get-ChildItem -LiteralPath $taskData -Force | Where-Object { $_.Name -notin @('installation.json', 'uninstalled') })
    if ($remaining.Count) { throw "Files appeared during uninstall. Close the approval panel and retry: $taskData" }
    Remove-Item -LiteralPath $taskStopMarker, $taskManifestPath -Force
    [IO.Directory]::Delete($taskData)
    $taskResult = 'Uninstalled Gravity Steward and deleted its local logs, settings, and backups.'
} else {
    $taskArchive = Join-Path $taskData ('uninstalled-plugin-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $taskArchive) { throw 'Uninstall archive already exists' }
    if (Test-Path -LiteralPath $taskPlugin) { Move-Item -LiteralPath $taskPlugin -Destination $taskArchive }
    if ($taskManifest.hadPreviousPlugin) {
        $taskPrevious = Join-Path $taskBackup 'previous-plugin'
        Assert-NoReparsePoint $taskPrevious
        if ((Test-Path -LiteralPath $taskPrevious) -and !(Test-Path -LiteralPath $taskPlugin)) {
            Move-Item -LiteralPath $taskPrevious -Destination $taskPlugin
        }
    }
    $taskResult = "Uninstalled. Preserved files in $taskData"
}
Write-Host $taskResult
Show-UninstallResult $taskResult $true
$global:LASTEXITCODE = 0
