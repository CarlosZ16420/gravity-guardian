[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:USERPROFILE '.gemini/gravity-guardian-data'),
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

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

$taskTempDir = Join-Path $taskLogs ('compact-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTempDir -Force | Out-Null

$taskWriters = @{}
$taskKeptLines = 0
$taskDroppedVerboseLines = 0

try {
    foreach ($taskFile in $taskFiles) {
        $taskPrefix = $taskFile.Name.Split('.')[0]
        if ($taskPrefix -notmatch '^\d{4}-\d{2}-\d{2}$') { $taskPrefix = [DateTime]::UtcNow.ToString('yyyy-MM-dd') }
        if (!$taskWriters.ContainsKey($taskPrefix)) {
            $taskOutPath = Join-Path $taskTempDir ($taskPrefix + '.000.jsonl')
            $taskWriters[$taskPrefix] = [IO.StreamWriter]::new($taskOutPath, $true, [Text.UTF8Encoding]::new($false))
        }
        $taskWriter = $taskWriters[$taskPrefix]
        $taskStream = [IO.FileStream]::new($taskFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $taskReader = [IO.StreamReader]::new($taskStream, [Text.Encoding]::UTF8)
        try {
            while ($null -ne ($taskLine = $taskReader.ReadLine())) {
                if (!$taskLine.Trim()) { continue }
                if ($taskLine.Contains('"event":"review_context"') -or $taskLine.Contains('"event":"guardian_input"') -or $taskLine.Contains('"event":"review_transport"')) {
                    $taskDroppedVerboseLines++
                    continue
                }
                if ($taskLine.Length -gt 8192 -and ($taskLine.Contains('"event":"tool_completed"') -or $taskLine.Contains('"event":"review_received"'))) {
                    try {
                        $taskObj = $taskLine | ConvertFrom-JsonHashtable
                        if ($taskObj.ContainsKey('payload')) { [void]$taskObj.Remove('payload') }
                        $taskWriter.WriteLine(($taskObj | ConvertTo-Json -Depth 10 -Compress))
                        $taskKeptLines++
                    } catch {
                        $taskDroppedVerboseLines++
                    }
                    continue
                }
                $taskWriter.WriteLine($taskLine)
                $taskKeptLines++
            }
        } finally {
            $taskReader.Dispose()
            $taskStream.Dispose()
        }
    }
} finally {
    foreach ($taskW in $taskWriters.Values) { $taskW.Flush(); $taskW.Dispose() }
}

foreach ($taskOld in $taskFiles) {
    try { Remove-Item -LiteralPath $taskOld.FullName -Force } catch {}
}
foreach ($taskNew in (Get-ChildItem -LiteralPath $taskTempDir -Filter '*.jsonl' -File)) {
    $taskDest = Join-Path $taskLogs $taskNew.Name
    if (Test-Path -LiteralPath $taskDest) {
        $taskAlt = Join-Path $taskLogs ($taskNew.BaseName + '.compacted.jsonl')
        Move-Item -LiteralPath $taskNew.FullName -Destination $taskAlt -Force
    } else {
        Move-Item -LiteralPath $taskNew.FullName -Destination $taskDest -Force
    }
}
Remove-Item -LiteralPath $taskTempDir -Recurse -Force

$taskBytesAfter = (Get-ChildItem -LiteralPath $taskLogs -Filter '*.jsonl' -File | Measure-Object -Property Length -Sum).Sum
@{
    logDirectory = $taskLogs
    keptEvents = $taskKeptLines
    droppedVerboseDumps = $taskDroppedVerboseLines
    beforeMB = [Math]::Round(($taskBytesBefore / 1MB), 2)
    afterMB = [Math]::Round(($taskBytesAfter / 1MB), 2)
    savedMB = [Math]::Round((($taskBytesBefore - $taskBytesAfter) / 1MB), 2)
} | ConvertTo-Json -Depth 5
