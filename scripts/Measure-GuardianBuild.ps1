[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Baseline','Symbols','Thin','ThinSingleUnit','ThinSize')]
    [string]$Tuning,
    [ValidateRange(1,50)][int]$Repetitions = 10,
    [string]$OutputDirectory,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$trial = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else {
    Join-Path $root ('.local/guardian-benchmarks/' + $Tuning + '-' + [Guid]::NewGuid().ToString('N'))
}
$target = Join-Path $trial 'cargo-target'
New-Item -ItemType Directory -Path $trial | Out-Null

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = (Get-Process -Id $PID).Path
foreach ($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Build-Guardian.ps1'),'-ForceBuild','-ReleaseTuning',$Tuning)) {
    $start.ArgumentList.Add($arg)
}
if ($Offline) { $start.ArgumentList.Add('-Offline') }
$start.Environment['CARGO_TARGET_DIR'] = $target
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$watch = [Diagnostics.Stopwatch]::StartNew()
$build = [Diagnostics.Process]::Start($start)
$peak = 0L
try {
    $stdout = $build.StandardOutput.ReadToEndAsync()
    $stderr = $build.StandardError.ReadToEndAsync()
    while (!$build.WaitForExit(1000)) {
        # Run one Rust build at a time so the compiler process sample belongs to this trial.
        $workingSet = (Get-Process -Name cargo,rustc,link,lld-link,cl,lib,cmake,ninja -ErrorAction SilentlyContinue |
            Measure-Object WorkingSet64 -Sum).Sum
        $peak = [Math]::Max($peak, [long]$workingSet)
    }
    $watch.Stop()
    [IO.File]::WriteAllText((Join-Path $trial 'build.stdout.log'), $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $trial 'build.stderr.log'), $stderr.GetAwaiter().GetResult())
    if ($build.ExitCode -ne 0) { throw "Guardian build failed; see $trial" }
} finally {
    if (!$build.HasExited) { $build.Kill($true) }
    $build.Dispose()
}

$artifact = Join-Path $root ".local/guardian-profiles/$Tuning"
$binary = Join-Path $artifact 'ag-guardian-host.exe'
$manifestPath = Join-Path $artifact 'SOURCE.json'
$manifest = Get-Content -Encoding UTF8 -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$zip = Join-Path $trial 'guardian.zip'
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $zipName = Split-Path $binary -Leaf
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $binary, $zipName, [IO.Compression.CompressionLevel]::Optimal)
} finally { $archive.Dispose() }
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try { $compressed = $archive.GetEntry($zipName).CompressedLength } finally { $archive.Dispose() }

$authHome = Join-Path $trial 'codex-home'
New-Item -ItemType Directory -Path $authHome | Out-Null
Set-Content -LiteralPath (Join-Path $authHome 'config.toml') 'cli_auth_credentials_store = "file"'
$guardian = [Diagnostics.ProcessStartInfo]::new($binary)
$guardian.WorkingDirectory = $trial
$guardian.UseShellExecute = $false
$guardian.RedirectStandardOutput = $true
$guardian.RedirectStandardError = $true
$guardian.RedirectStandardInput = $true
$guardian.Environment['CODEX_HOME'] = $authHome
$guardian.Environment['AG_GUARDIAN_HOST'] = '1'
foreach ($variable in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_AUTH_TOKEN','CODEX_GUARDIAN_REPLAY','CODEX_GUARDIAN_REPLAY_ALLOW_INFERENCE')) {
    [void]$guardian.Environment.Remove($variable)
}
$startupWatch = [Diagnostics.Stopwatch]::StartNew()
$hostProcess = [Diagnostics.Process]::Start($guardian)
try {
    $readyLine = $hostProcess.StandardOutput.ReadLineAsync()
    if (!$readyLine.Wait(20000)) { throw 'Timed out waiting for the native ready frame' }
    $startupWatch.Stop()
    $ready = $readyLine.Result | ConvertFrom-Json
    if ($ready.type -cne 'ready' -or $ready.toolsEnabled -ne $false) { throw 'Invalid native ready frame' }
} finally {
    $hostProcess.StandardInput.Close()
    if (!$hostProcess.WaitForExit(5000)) { $hostProcess.Kill($true) }
    $hostProcess.Dispose()
}
$savedTarget = $env:CARGO_TARGET_DIR
try {
    $env:CARGO_TARGET_DIR = $target
    & node (Join-Path $PSScriptRoot 'Test-NativePrompt.mjs') (Join-Path $trial 'loopback') $manifestPath $Repetitions
    if ($LASTEXITCODE -ne 0) { throw 'Guardian loopback benchmark failed' }
} finally { $env:CARGO_TARGET_DIR = $savedTarget }
$review = Get-Content -LiteralPath (Join-Path $trial 'loopback/summary.json') -Raw | ConvertFrom-Json
@{
    tuning = $Tuning; releaseOptions = $manifest.releaseOptions; upstreamCommit = $manifest.upstreamCommit
    binarySha256 = $manifest.binarySha256; binaryBytes = (Get-Item -LiteralPath $binary).Length
    resolvedCargoLockSha256 = $manifest.resolvedCargoLockSha256
    zipEntryBytes = $compressed; coldBuildMs = $watch.ElapsedMilliseconds; peakSampledCompilerWorkingSetBytes = $peak
    startupReadyMs = $startupWatch.Elapsed.TotalMilliseconds
    loopbackReviewP50Ms = $review.reviewP50Ms; loopbackReviewP95Ms = $review.reviewP95Ms; reviewCount = $review.capturedModelRequests
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $trial 'measurements.json') -Encoding utf8
Write-Host "Measurements: $trial"
