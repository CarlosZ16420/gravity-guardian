[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:USERPROFILE '.gemini/gravity-guardian-data'),
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$taskPortable=Get-PortableLayout
if ($taskPortable -and !$PSBoundParameters.ContainsKey('DataDirectory')) { $DataDirectory=$taskPortable.data }

$taskLogs = [IO.Path]::GetFullPath((Join-Path $DataDirectory 'logs'))
if (!(Test-Path -LiteralPath $taskLogs -PathType Container)) {
    Write-Host "No logs directory found at $taskLogs"
    return
}

$taskFiles = @(Get-ChildItem -LiteralPath $taskLogs -Filter '*.jsonl' -File | Sort-Object Name)
$taskBytesBefore = ($taskFiles | Measure-Object -Property Length -Sum).Sum
if ($PlanOnly) {
    @{
        logDirectory = $taskLogs
        segmentFiles = $taskFiles.Count
        sizeMB = [Math]::Round(($taskBytesBefore / 1MB), 2)
        action = 'Strip redundant review_context, guardian_input, review_transport, and raw hook payloads while retaining all compact audit/usage events'
    } | ConvertTo-Json -Depth 5
    return
}

# Share the core lock, active-file protection and atomic replacement implementation.
$taskBundle = if ($taskPortable) { $taskPortable.app } else { Split-Path $PSScriptRoot -Parent }
if (!(Test-Path -LiteralPath (Join-Path $taskBundle 'scripts/gravity-guardian.dll') -PathType Leaf)) {
    $taskBundle = Join-Path $taskBundle 'artifacts/gravity-guardian'
}
$taskAssembly = Join-Path $taskBundle 'scripts/gravity-guardian.dll'
if (!(Test-Path -LiteralPath $taskAssembly -PathType Leaf)) { throw 'Build or install Gravity Guardian before compacting logs' }
$taskRuntime = Resolve-ApprovalRuntime $taskBundle -Installed
& $taskRuntime $taskAssembly compact-logs --data-dir ([IO.Path]::GetFullPath($DataDirectory))
if ($LASTEXITCODE -ne 0) { throw 'Log compaction failed; inspect the core command error above' }
