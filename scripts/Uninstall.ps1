[CmdletBinding()]
param([string]$DataDirectory = (Join-Path $env:USERPROFILE '.gemini/codex-approval-data'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskData = [IO.Path]::GetFullPath($DataDirectory)
$taskManifest = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskData 'installation.json') -Raw | ConvertFrom-JsonHashtable
$taskPlugin = [IO.Path]::GetFullPath($taskManifest.pluginDirectory)
$taskExpected = [IO.Path]::GetFullPath((Join-Path $taskManifest.configRoot 'plugins/codex-approval'))
if ($taskPlugin -ne $taskExpected) { throw 'Invalid installation manifest target' }
[IO.File]::WriteAllText((Join-Path $taskData 'uninstalled'), 'disabled')

# Stop tray panel if running from this plugin directory, and clean autostart entry pointing here.
Get-Process -Name 'CodexApprovalPanel' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($taskPlugin + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    try { $_.Kill(); $_.WaitForExit(5000) } catch {}
}

$taskRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $taskRunKey) {
    try {
        $taskRunVal = (Get-ItemProperty -LiteralPath $taskRunKey -Name 'AntigravityCodexApproval' -ErrorAction SilentlyContinue).'AntigravityCodexApproval'
        if ($taskRunVal -and $taskRunVal.IndexOf($taskPlugin, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Remove-ItemProperty -LiteralPath $taskRunKey -Name 'AntigravityCodexApproval' -ErrorAction SilentlyContinue
        }
    } catch {}
}

$taskRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
$taskAssembly = Join-Path $taskPlugin 'scripts/ag-approval.dll'
if (Test-Path -LiteralPath $taskRuntime) {
    $taskPrevError = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $taskRuntime $taskAssembly stop --config (Join-Path $taskPlugin 'approval.json') 2>$null | Out-Null } finally { $ErrorActionPreference = $taskPrevError }
}

$taskConfig = Join-Path $taskManifest.configRoot 'config.json'
$taskState = Get-Content -Encoding UTF8 -LiteralPath $taskConfig -Raw | ConvertFrom-JsonHashtable
if ($taskState.sidecars -and $taskState.sidecars.ContainsKey($taskManifest.sidecarId)) {
    if ($null -eq $taskManifest.oldSidecar) { $taskState.sidecars.Remove($taskManifest.sidecarId) } else { $taskState.sidecars[$taskManifest.sidecarId] = $taskManifest.oldSidecar }
    $taskTemp = $taskConfig + '.codex-approval.tmp'
    $taskState | ConvertTo-Json -Depth 100 | Set-Utf8NoBom -LiteralPath $taskTemp -Encoding utf8
    Move-Item -LiteralPath $taskTemp -Destination $taskConfig -Force
}
if ($taskManifest.reviewModeChanges) { Restore-CodexReviewMode -ConfigRoot $taskManifest.configRoot -Changes @($taskManifest.reviewModeChanges) }

Start-Sleep -Milliseconds 2200
$taskArchive = Join-Path $taskData ('uninstalled-plugin-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
if ((Test-Path -LiteralPath $taskArchive) -or ![IO.Path]::GetFullPath($taskArchive).StartsWith($taskData + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid uninstall archive target' }
if (Test-Path -LiteralPath $taskPlugin) { Move-Item -LiteralPath $taskPlugin -Destination $taskArchive }
if ($taskManifest.hadPreviousPlugin) {
    $taskPrevious = [IO.Path]::GetFullPath((Join-Path $taskManifest.backupDirectory 'previous-plugin'))
    if (!$taskPrevious.StartsWith($taskData + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $taskPlugin)) { throw 'Invalid previous plugin restoration path' }
    Move-Item -LiteralPath $taskPrevious -Destination $taskPlugin
}
Write-Host "Uninstalled. Preserved files: $taskArchive"
