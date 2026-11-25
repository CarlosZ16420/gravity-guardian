[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory, [switch]$RunFixtures)

$ErrorActionPreference = 'Stop'
$taskOutput = [IO.Path]::GetFullPath($OutputDirectory)
$taskTripwire = Join-Path $taskOutput 'codex.exe'
$taskControlPath = Join-Path $taskOutput 'control-pid.txt'
if ($RunFixtures) {
    if ($env:AG_TEST_CLI_TRIPWIRE -ne $taskTripwire) { throw 'The process trace must start the fixtures' }
    $taskStartInfo = [Diagnostics.ProcessStartInfo]::new($taskTripwire, '/d /c exit 0')
    $taskStartInfo.UseShellExecute = $false
    $taskStartInfo.CreateNoWindow = $true
    $taskControl = [Diagnostics.Process]::Start($taskStartInfo)
    try {
        $taskControl.WaitForExit()
        [IO.File]::WriteAllText($taskControlPath, [string]$taskControl.Id)
    } finally { $taskControl.Dispose() }
    & (Join-Path $PSScriptRoot 'Test-Installation.ps1')
    & (Join-Path $PSScriptRoot 'Test-Update.ps1')
    exit 0
}

New-Item -ItemType Directory -Path $taskOutput | Out-Null
Copy-Item -LiteralPath $env:ComSpec -Destination $taskTripwire
$taskOldPath = $env:PATH
$taskOldTripwire = $env:AG_TEST_CLI_TRIPWIRE
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'Trace-ProcessTree.cs')
    $env:PATH = $taskOutput + [IO.Path]::PathSeparator + $taskOldPath
    $env:AG_TEST_CLI_TRIPWIRE = $taskTripwire
    $taskShell = (Get-Process -Id $PID).Path
    $taskCommand = '"{0}" -NoProfile -NonInteractive -File "{1}" -OutputDirectory "{2}" -RunFixtures' -f $taskShell, $PSCommandPath, $taskOutput
    $taskTrace = [ProcessTreeTrace]::Run($taskShell, $taskCommand, $PSScriptRoot)
    if ($taskTrace.ExitCode -ne 0) { throw ('Traced installation or update test failed with exit code ' + $taskTrace.ExitCode) }
    $taskControlId = [int][IO.File]::ReadAllText($taskControlPath)
    $taskSawControl = $false
    $taskObserved = @(foreach ($taskStart in $taskTrace.Starts) {
        if (!$taskSawControl -and $taskStart.ProcessId -eq $taskControlId -and $taskStart.Image -eq $taskTripwire) {
            $taskSawControl = $true
            continue
        }
        [IO.Path]::GetFileName($taskStart.Image)
    })
    if (!$taskSawControl) { throw ('The Windows process trace missed the positive control PID ' + $taskControlId) }
    $taskCli = @($taskObserved | Where-Object { $_ -eq 'codex.exe' })
    foreach ($taskExpected in @('ag-guardian-host.exe', 'GravityGuardian.exe', 'dotnet.exe')) {
        if ($taskExpected -notin $taskObserved) { throw ('The process trace missed the exercised executable ' + $taskExpected) }
    }
    @{
        positiveControl = $true
        tracedProcessStarts = $taskObserved.Count
        codexExeStarts = $taskCli.Count
        guardianStarts = @($taskObserved | Where-Object { $_ -eq 'ag-guardian-host.exe' }).Count
        panelStarts = @($taskObserved | Where-Object { $_ -eq 'GravityGuardian.exe' }).Count
        scenarios = @('install', 'diagnostics', 'panel discovery', 'native Hooks', 'repair', 'self-update', 'uninstall')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskOutput 'summary.json') -Encoding utf8
    if ($taskCli.Count) { throw 'The candidate launched codex.exe' }
    Write-Host 'PASS Windows process trace found zero codex.exe starts across the installed workflows'
} finally {
    $env:PATH = $taskOldPath
    $env:AG_TEST_CLI_TRIPWIRE = $taskOldTripwire
    Remove-Item -LiteralPath $taskTripwire -ErrorAction SilentlyContinue
}
