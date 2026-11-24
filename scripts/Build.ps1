[CmdletBinding()]
param([switch]$SkipTests,[switch]$SkipPanelSelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Locked-DotnetRuntime.ps1')
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskParentRoot = Split-Path $taskRoot -Parent

$taskToolsDir = if (Test-Path -LiteralPath (Join-Path $taskRoot '.tools/dotnet/dotnet.exe')) {
    Join-Path $taskRoot '.tools'
} elseif (Test-Path -LiteralPath (Join-Path $taskParentRoot '.tools/dotnet/dotnet.exe')) {
    Join-Path $taskParentRoot '.tools'
} else {
    Join-Path $taskRoot '.tools'
}

$env:DOTNET_CLI_HOME = Join-Path $taskToolsDir 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$taskOriginalAppData = $env:APPDATA
$env:APPDATA = Join-Path $taskToolsDir 'build-profile'

$taskDotnet = Join-Path $taskToolsDir 'dotnet/dotnet.exe'
if (!(Test-Path -LiteralPath $taskDotnet)) { $taskDotnet = (Get-Command dotnet).Source }

Push-Location $taskRoot
try {
    & (Join-Path $PSScriptRoot 'Check-PublicHygiene.ps1')
    $taskRuntime = Get-LockedDotnetRuntime
    & node (Join-Path $PSScriptRoot 'Prepare-Policy.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Policy preparation failed' }
    & (Join-Path $PSScriptRoot 'Build-Guardian.ps1')
    & $taskDotnet restore 'tests/AgApproval.Tests/AgApproval.Tests.csproj' --configfile (Join-Path $taskRoot 'NuGet.Config') --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Offline dependency restore failed' }
    & $taskDotnet build 'src/AgApproval/AgApproval.csproj' -c Release --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }

    if (!$SkipTests) {
        & $taskDotnet run --project 'tests/AgApproval.Tests/AgApproval.Tests.csproj' -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { throw 'Verification failed' }
        $taskContract = Join-Path $taskRoot '.local/contract/input.json'
        $taskSchema = Join-Path $taskRoot 'schemas/review-input.schema.json'
        $taskSessionContract = Join-Path $taskRoot '.local/contract/session.json'
        $taskSessionSchema = Join-Path $taskRoot 'schemas/review-session.schema.json'
        $taskValidator = Join-Path $PSScriptRoot 'Validate-Schema.mjs'
        & node $taskValidator $taskContract $taskSchema
        if ($LASTEXITCODE -ne 0) { throw 'Review input contract validation failed' }
        & node $taskValidator $taskContract $taskSchema '--forged-role-check'
        if ($LASTEXITCODE -ne 0) { throw 'Schema accepted forged trusted message role' }
        Write-Host 'PASS published JSON schema validates actual input and rejects forged role'
        & node $taskValidator $taskSessionContract $taskSessionSchema
        if ($LASTEXITCODE -ne 0) { throw 'Reviewer session wire schema validates failed' }
        Write-Host 'PASS reviewer session wire schema validates the captured delta transport'
        & (Join-Path $PSScriptRoot 'Test-LogStatistics.ps1')
    }

    & (Join-Path $PSScriptRoot 'Build-Panel.ps1') -SkipSelfTest:$SkipPanelSelfTest

    $taskBundle = Join-Path $taskRoot ('.local/build-bundle/' + [Guid]::NewGuid().ToString('N') + '/codex-approval')
    New-Item -ItemType Directory -Path $taskBundle -Force | Out-Null
    Copy-Item -Path (Join-Path $taskRoot 'plugin/*') -Destination $taskBundle -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $taskRoot '.local/guardian-host-build') -Destination (Join-Path $taskBundle 'native') -Recurse

    $taskApp = Join-Path $taskBundle 'app'
    New-Item -ItemType Directory -Path $taskApp -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $taskRoot '.local/panel-build/CodexApprovalPanel.exe') -Destination (Join-Path $taskApp 'CodexApprovalPanel.exe') -Force

    $taskPrograms = Join-Path $taskBundle 'scripts'
    New-Item -ItemType Directory -Path $taskPrograms -Force | Out-Null
    & $taskDotnet publish 'src/AgApproval/AgApproval.csproj' -c Release --no-restore --self-contained false -p:DebugType=None -p:DebugSymbols=false -o $taskPrograms --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
    foreach ($taskScript in @('Apply-Update.ps1', 'Install.ps1', 'Uninstall.ps1', 'Review-Mode.ps1')) {
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

    $taskPublishedBundle = [IO.Path]::GetFullPath((Join-Path $taskRoot 'artifacts/codex-approval'))
    $taskOldBundle = [IO.Path]::GetFullPath((Join-Path $taskRoot ('.local/build-backups/' + [Guid]::NewGuid().ToString('N') + '/codex-approval')))
    $taskWorkspacePrefix = [IO.Path]::GetFullPath($taskRoot).TrimEnd('\') + '\'
    foreach ($taskMovePath in @($taskBundle, $taskPublishedBundle, $taskOldBundle)) {
        if (![IO.Path]::GetFullPath($taskMovePath).StartsWith($taskWorkspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build target escaped workspace' }
    }
    New-Item -ItemType Directory -Path (Split-Path $taskPublishedBundle) -Force | Out-Null
    if (Test-Path -LiteralPath $taskPublishedBundle) { New-Item -ItemType Directory -Path (Split-Path $taskOldBundle) -Force | Out-Null; Move-Item -LiteralPath $taskPublishedBundle -Destination $taskOldBundle }
    Move-Item -LiteralPath $taskBundle -Destination $taskPublishedBundle
    Write-Host "Ready: $taskPublishedBundle"
} finally {
    $env:APPDATA = $taskOriginalAppData
    Pop-Location
}
