[CmdletBinding()]
param([switch]$RunServiceTests)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'Check-PublicHygiene.ps1')
$taskPlugin=Get-Content -LiteralPath (Join-Path $taskRoot 'plugin/plugin.json') -Raw | ConvertFrom-Json
$taskVersion=[string]$taskPlugin.version
$taskProject=[xml](Get-Content -LiteralPath (Join-Path $taskRoot 'src/AgApproval/AgApproval.csproj') -Raw)
$taskManifest=[xml](Get-Content -LiteralPath (Join-Path $taskRoot 'src/AgApproval.Panel/panel.manifest') -Raw)
$taskPanel=[IO.File]::ReadAllText((Join-Path $taskRoot 'src/AgApproval.Panel/version.h'))
$taskCargo=[IO.File]::ReadAllText((Join-Path $taskRoot 'native/guardian-host/Cargo.toml'))
if ($taskVersion -notmatch '^\d+\.\d+\.\d+$' -or
    $taskProject.SelectSingleNode('/Project/PropertyGroup/Version').InnerText -cne $taskVersion -or
    $taskManifest.assembly.assemblyIdentity.version -cne "$taskVersion.0" -or
    $taskPanel -notmatch ('(?m)^#define PANEL_VERSION_WIDE L"'+[regex]::Escape($taskVersion)+'"\s*$') -or
    $taskCargo -notmatch ('(?m)^version\s*=\s*"'+[regex]::Escape($taskVersion)+'"\s*$')) { throw 'The five release versions disagree' }
$taskNotes=Join-Path $taskRoot "docs/release-$taskVersion.md"
if (!(Test-Path -LiteralPath $taskNotes) -or ![IO.File]::ReadAllText($taskNotes).StartsWith("# Gravity Guardian v$taskVersion")) { throw 'Matching release notes are missing' }
foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax error in $($script.Name): $($errors[0].Message)" }
}
foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.mjs) {
    & node --check $script.FullName
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax error: $($script.Name)" }
}
foreach ($file in @('plugin/plugin.json','plugin/hooks.json','plugin/update-config.json','native/SOURCE.json','schemas/review-input.schema.json')) {
    [void]([IO.File]::ReadAllText((Join-Path $taskRoot $file)) | ConvertFrom-Json)
}
& (Join-Path $PSScriptRoot 'Test-ReleasePrivacy.ps1')
& (Join-Path $PSScriptRoot 'Test-ReleaseWorkflow.ps1')
& (Join-Path $PSScriptRoot 'Test-PortableServiceStop.ps1')
Write-Host 'PASS preflight versions, release notes, source privacy, PowerShell/JavaScript syntax and JSON'
if ($RunServiceTests) {
    $taskParent=Split-Path $taskRoot -Parent
    $taskDotnet=@((Join-Path $taskRoot '.tools/dotnet/dotnet.exe'),(Join-Path $taskParent '.tools/dotnet/dotnet.exe')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (!$taskDotnet) { $taskDotnet=(Get-Command dotnet).Source }
    $saved=@{}
    $environment=@{DOTNET_CLI_HOME=(Join-Path $taskRoot '.tools/dotnet-home');DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='false'}
    foreach ($entry in $environment.GetEnumerator()) { $saved[$entry.Key]=[Environment]::GetEnvironmentVariable($entry.Key,'Process'); [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process') }
    Push-Location $taskRoot
    try {
        & node (Join-Path $PSScriptRoot 'Prepare-Policy.mjs')
        if ($LASTEXITCODE -ne 0) { throw 'Policy preparation failed' }
        & $taskDotnet restore tests/AgApproval.Tests/AgApproval.Tests.csproj --configfile NuGet.Config --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Service test restore failed' }
        & $taskDotnet run --project tests/AgApproval.Tests/AgApproval.Tests.csproj -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { throw 'Service regression failed' }
        foreach ($extra in @('', '--forged-role-check')) {
            $arguments=@((Join-Path $PSScriptRoot 'Validate-Schema.mjs'),'.local/contract/input.json','schemas/review-input.schema.json')
            if ($extra) { $arguments += $extra }
            & node @arguments
            if ($LASTEXITCODE -ne 0) { throw 'Review input schema check failed' }
        }
        & (Join-Path $PSScriptRoot 'Test-LogStatistics.ps1')
    } finally {
        Pop-Location
        foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process') }
    }
}
$global:LASTEXITCODE=0
