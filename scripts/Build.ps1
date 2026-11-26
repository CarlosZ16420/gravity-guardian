[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipPanelSelfTest,
    [ValidateSet('Default','Baseline','Symbols','Thin','ThinSingleUnit','ThinSize')]
    [string]$GuardianTuning = 'Default'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Locked-DotnetRuntime.ps1')
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskParentRoot = Split-Path $taskRoot -Parent
$taskReleaseVersion = (Get-Content -LiteralPath (Join-Path $taskRoot 'plugin/plugin.json') -Raw | ConvertFrom-Json).version
$taskCoreProject = [xml](Get-Content -LiteralPath (Join-Path $taskRoot 'src/AgApproval/AgApproval.csproj') -Raw)
$taskPanelVersion = Get-Content -LiteralPath (Join-Path $taskRoot 'src/AgApproval.Panel/version.h') -Raw
$taskPanelManifest = [xml](Get-Content -LiteralPath (Join-Path $taskRoot 'src/AgApproval.Panel/panel.manifest') -Raw)
$taskGuardianCargo = Get-Content -LiteralPath (Join-Path $taskRoot 'native/guardian-host/Cargo.toml') -Raw
if ($taskReleaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
    $taskCoreProject.Project.PropertyGroup.Version -cne $taskReleaseVersion -or
    $taskPanelVersion -notmatch ('(?m)^#define PANEL_VERSION_WIDE L"' + [regex]::Escape($taskReleaseVersion) + '"\s*$') -or
    $taskPanelManifest.assembly.assemblyIdentity.version -cne "$taskReleaseVersion.0" -or
    $taskGuardianCargo -notmatch ('(?m)^version\s*=\s*"' + [regex]::Escape($taskReleaseVersion) + '"\s*$')) {
    throw 'Release versions disagree between plugin.json, AgApproval.csproj, panel version.h/manifest, and native guardian-host Cargo.toml'
}

$taskToolsDir = if (Test-Path -LiteralPath (Join-Path $taskRoot '.tools/dotnet/dotnet.exe')) {
    Join-Path $taskRoot '.tools'
} elseif (Test-Path -LiteralPath (Join-Path $taskParentRoot '.tools/dotnet/dotnet.exe')) {
    Join-Path $taskParentRoot '.tools'
} else {
    Join-Path $taskRoot '.tools'
}

$taskBuildTemp = Join-Path $taskRoot '.local/build-temp'
$taskNugetScratch = Join-Path $taskBuildTemp 'NuGetScratch'
New-Item -ItemType Directory -Path $taskBuildTemp, $taskNugetScratch -Force | Out-Null

$taskOriginalTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
$taskOriginalTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
$taskOriginalNugetScratch = [Environment]::GetEnvironmentVariable('NUGET_SCRATCH', 'Process')
$taskOriginalAppData = [Environment]::GetEnvironmentVariable('APPDATA', 'Process')
$env:TMP = $taskBuildTemp
$env:TEMP = $taskBuildTemp
$env:NUGET_SCRATCH = $taskNugetScratch
$env:DOTNET_CLI_HOME = Join-Path $taskToolsDir 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:APPDATA = Join-Path $taskToolsDir 'build-profile'

$taskDotnet = Join-Path $taskToolsDir 'dotnet/dotnet.exe'
if (!(Test-Path -LiteralPath $taskDotnet)) { $taskDotnet = (Get-Command dotnet).Source }

Push-Location $taskRoot
try {
    & (Join-Path $PSScriptRoot 'Check-PublicHygiene.ps1')
    if (!$SkipTests) { & (Join-Path $PSScriptRoot 'Test-ReleasePrivacy.ps1') }
    $taskRuntime = Get-LockedDotnetRuntime
    & node (Join-Path $PSScriptRoot 'Prepare-Policy.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Policy preparation failed' }
    & $taskDotnet restore 'tests/AgApproval.Tests/AgApproval.Tests.csproj' --configfile (Join-Path $taskRoot 'NuGet.Config') --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Offline dependency restore failed' }
    & $taskDotnet build 'src/AgApproval/AgApproval.csproj' -c Release --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }

    if (!$SkipTests) {
        & $taskDotnet run --project 'tests/AgApproval.Tests/AgApproval.Tests.csproj' -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { throw 'Verification failed' }
        $taskContract = Join-Path $taskRoot '.local/contract/input.json'
        $taskSchema = Join-Path $taskRoot 'schemas/review-input.schema.json'
        $taskValidator = Join-Path $PSScriptRoot 'Validate-Schema.mjs'
        & node $taskValidator $taskContract $taskSchema
        if ($LASTEXITCODE -ne 0) { throw 'Review input contract validation failed' }
        & node $taskValidator $taskContract $taskSchema '--forged-role-check'
        if ($LASTEXITCODE -ne 0) { throw 'Schema accepted forged trusted message role' }
        Write-Host 'PASS published JSON schema validates actual input and rejects forged role'
        & (Join-Path $PSScriptRoot 'Test-LogStatistics.ps1')
    }

    & (Join-Path $PSScriptRoot 'Build-Panel.ps1') -SkipSelfTest:$SkipPanelSelfTest
    $taskPanelBinary = Join-Path $taskRoot '.local/panel-build/GravityGuardian.exe'
    if ((Get-Item -LiteralPath $taskPanelBinary).VersionInfo.ProductVersion -cne "$taskReleaseVersion.0") {
        throw 'Built panel product version differs from the release version'
    }

    # Fail the inexpensive service/panel checks before starting heavy Rust work.
    & (Join-Path $PSScriptRoot 'Build-Guardian.ps1') -Profile Release -ReleaseTuning $GuardianTuning

    $taskBundle = Join-Path $taskRoot ('.local/build-bundle/' + [Guid]::NewGuid().ToString('N') + '/gravity-guardian')
    New-Item -ItemType Directory -Path $taskBundle -Force | Out-Null
    Copy-Item -Path (Join-Path $taskRoot 'plugin/*') -Destination $taskBundle -Recurse -Force
    $taskNative = Join-Path $taskBundle 'native'
    $taskNativeBuild = if ($GuardianTuning -eq 'Default') {
        Join-Path $taskRoot '.local/guardian-host-build'
    } else { Join-Path $taskRoot ".local/guardian-profiles/$GuardianTuning" }
    New-Item -ItemType Directory -Path $taskNative -Force | Out-Null
    foreach ($taskNativeFile in @('ag-guardian-host.exe', 'SOURCE.json', 'UPSTREAM-LICENSE', 'UPSTREAM-NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $taskNativeBuild $taskNativeFile) -Destination $taskNative
    }

    $taskApp = Join-Path $taskBundle 'app'
    New-Item -ItemType Directory -Path $taskApp -Force | Out-Null
    Copy-Item -LiteralPath $taskPanelBinary -Destination (Join-Path $taskApp 'GravityGuardian.exe') -Force

    $taskPrograms = Join-Path $taskBundle 'scripts'
    New-Item -ItemType Directory -Path $taskPrograms -Force | Out-Null
    & $taskDotnet publish 'src/AgApproval/AgApproval.csproj' -c Release --no-restore --self-contained false -p:UseAppHost=false -p:DebugType=None -p:DebugSymbols=false -o $taskPrograms --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
    foreach ($taskScript in @('Apply-Update.ps1', 'Install.ps1', 'Uninstall.ps1', 'Review-Mode.ps1', 'Resolve-Runtime.ps1', 'Portable.ps1', 'Doctor.ps1', 'Analyze-Logs.ps1', 'Compact-Logs.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $taskScript) -Destination (Join-Path $taskPrograms $taskScript) -Force
    }

    $taskPolicy = Join-Path $taskBundle 'policy/effective-codex'
    New-Item -ItemType Directory -Path $taskPolicy -Force | Out-Null
    Copy-Item -Path (Join-Path $taskRoot 'policy/effective-codex/*') -Destination $taskPolicy -Recurse -Force

    # The build SDK is independent of the runtime shipped with the framework-dependent app.
    $taskRuntimeArchive = [IO.Compression.ZipFile]::OpenRead($taskRuntime.archivePath)
    try {
        $taskRuntimeFiles = Get-LockedDotnetRuntimeFiles -Archive $taskRuntimeArchive -Version $taskRuntime.version
        foreach ($taskRuntimeFile in $taskRuntimeFiles.Values) {
            $taskTarget = Join-Path $taskBundle ('runtime/' + $taskRuntimeFile.FullName)
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($taskTarget)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($taskRuntimeFile, $taskTarget)
        }
    } finally {
        $taskRuntimeArchive.Dispose()
    }

    $taskPublishedBundle = [IO.Path]::GetFullPath((Join-Path $taskRoot 'artifacts/gravity-guardian'))
    $taskOldBundle = [IO.Path]::GetFullPath((Join-Path $taskRoot ('.local/build-backups/' + [Guid]::NewGuid().ToString('N') + '/gravity-guardian')))
    $taskWorkspacePrefix = [IO.Path]::GetFullPath($taskRoot).TrimEnd('\') + '\'
    foreach ($taskMovePath in @($taskBundle, $taskPublishedBundle, $taskOldBundle)) {
        if (![IO.Path]::GetFullPath($taskMovePath).StartsWith($taskWorkspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build target escaped workspace' }
    }
    New-Item -ItemType Directory -Path (Split-Path $taskPublishedBundle) -Force | Out-Null
    if (Test-Path -LiteralPath $taskPublishedBundle) { New-Item -ItemType Directory -Path (Split-Path $taskOldBundle) -Force | Out-Null; Move-Item -LiteralPath $taskPublishedBundle -Destination $taskOldBundle }
    Move-Item -LiteralPath $taskBundle -Destination $taskPublishedBundle
    $taskBundleStageRoot = Split-Path $taskBundle -Parent
    if ((Test-Path -LiteralPath $taskBundleStageRoot) -and @(Get-ChildItem -LiteralPath $taskBundleStageRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $taskBundleStageRoot -Force
    }
    Write-Host "Ready: $taskPublishedBundle"
} finally {
    foreach ($restorePair in @(
        @{ k='TMP'; v=$taskOriginalTmp },
        @{ k='TEMP'; v=$taskOriginalTemp },
        @{ k='NUGET_SCRATCH'; v=$taskOriginalNugetScratch },
        @{ k='APPDATA'; v=$taskOriginalAppData }
    )) {
        if ($null -eq $restorePair.v) { Remove-Item -LiteralPath ("Env:" + $restorePair.k) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($restorePair.k, [string]$restorePair.v, 'Process') }
    }
    Pop-Location
}
