[CmdletBinding()]
param(
    [ValidateSet('Auto','Service','Panel','Policy','Plugin','Guardian','All')]
    [string[]]$Components = @('Auto'),
    [ValidateSet('Dev','Release')]
    [string]$GuardianProfile = 'Dev',
    [ValidateSet('Default','Baseline','Symbols','Thin','ThinSingleUnit','ThinSize')]
    [string]$GuardianTuning = 'Default',
    [switch]$ForceGuardian,
    [switch]$OfflineGuardian,
    [switch]$RunTests,
    [switch]$SkipPanelSelfTest,
    [switch]$BuildOnly,
    [switch]$NoStart,
    [switch]$SkipDoctor,
    [switch]$SkipGuardianAuthCheck,
    [switch]$UseVerifiedCopyCommit,
    [string]$GeminiRoot = '',
    [string]$DataDirectory = '',
    [string]$AntigravityPath = '',
    [string]$Proxy = '',
    [ValidateSet('Codex','Preserve')]
    [string]$ReviewMode = 'Codex',
    [ValidateSet('Conservative','ModelOnly')]
    [string]$ReviewRouting = 'Conservative',
    [switch]$EnableDetailedLogs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Locked-DotnetRuntime.ps1')

$taskTotalWatch = [Diagnostics.Stopwatch]::StartNew()
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskParentRoot = Split-Path $taskRoot -Parent
$taskLocal = Join-Path $taskRoot '.local'
$taskBuildTemp = Join-Path $taskLocal 'build-temp'
$taskNugetScratch = Join-Path $taskBuildTemp 'NuGetScratch'

$taskReleaseVersion = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'plugin/plugin.json') -Raw | ConvertFrom-Json).version
$taskCoreProject = [xml](Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'src/AgApproval/AgApproval.csproj') -Raw)
$taskPanelVersion = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'src/AgApproval.Panel/version.h') -Raw
$taskPanelManifest = [xml](Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'src/AgApproval.Panel/panel.manifest') -Raw)
$taskGuardianCargo = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'native/guardian-host/Cargo.toml') -Raw
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

$taskSavedEnv = [ordered]@{}
foreach ($taskEnvName in @(
    'TMP', 'TEMP', 'NUGET_SCRATCH',
    'DOTNET_CLI_HOME', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE',
    'DOTNET_GENERATE_ASPNET_CERTIFICATE', 'APPDATA'
)) {
    $taskSavedEnv[$taskEnvName] = [Environment]::GetEnvironmentVariable($taskEnvName, 'Process')
}

$taskUtf8NoBom = [Text.UTF8Encoding]::new($false)
function Restore-LocalBuildEnvironment {
    foreach ($entry in $taskSavedEnv.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -LiteralPath ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
    }
}
function Get-FileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-TextSha256([string]$Value) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($taskUtf8NoBom.GetBytes($Value))).ToLowerInvariant()
}
function Get-InputsSha256([string]$BaseRoot, [string[]]$RelativePaths, [string[]]$ExcludedDirNames = @()) {
    $basePrefix = [IO.Path]::GetFullPath($BaseRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($rel in $RelativePaths) {
        $fullTarget = Join-Path $BaseRoot $rel
        if (!(Test-Path -LiteralPath $fullTarget)) { continue }
        $item = Get-Item -LiteralPath $fullTarget -Force
        if ($item -is [IO.FileInfo]) {
            $relNorm = $item.FullName.Substring($basePrefix.Length).Replace('\', '/')
            $entries.Add($relNorm + ':' + (Get-FileSha256 $item.FullName))
            continue
        }
        foreach ($file in (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force)) {
            $relNorm = $file.FullName.Substring($basePrefix.Length).Replace('\', '/')
            $parts = $relNorm -split '/'
            $excluded = $false
            foreach ($part in $parts) {
                if ($ExcludedDirNames -contains $part) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            $entries.Add($relNorm + ':' + (Get-FileSha256 $file.FullName))
        }
    }
    $entries.Sort([StringComparer]::Ordinal)
    Get-TextSha256 ($entries -join "`n")
}
function Copy-DirectoryContent([string]$SourceDir, [string]$TargetDir) {
    if (Test-Path -LiteralPath $TargetDir) {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $TargetDir -Recurse -Force
}
function Sync-FileIfChanged([string]$SourcePath, [string]$DestinationPath) {
    $destDir = Split-Path $DestinationPath -Parent
    if (!(Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if ((Test-Path -LiteralPath $DestinationPath -PathType Leaf) -and
        ((Get-FileSha256 $SourcePath) -ceq (Get-FileSha256 $DestinationPath))) {
        return $false
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return $true
}
function Test-NeedsDotnetRestore([string]$ProjectPath, [string[]]$Inputs = @()) {
    $assetsPath = Join-Path (Join-Path (Split-Path $ProjectPath -Parent) 'obj') 'project.assets.json'
    if (!(Test-Path -LiteralPath $assetsPath -PathType Leaf)) { return $true }
    $assetsTime = (Get-Item -LiteralPath $assetsPath).LastWriteTimeUtc
    foreach ($inputPath in (@($ProjectPath) + $Inputs)) {
        if ((Test-Path -LiteralPath $inputPath -PathType Leaf) -and ((Get-Item -LiteralPath $inputPath).LastWriteTimeUtc -gt $assetsTime)) {
            return $true
        }
    }
    return $false
}

$taskStageRoot = Join-Path $taskLocal ('build-bundle/local-' + [Guid]::NewGuid().ToString('N'))

Push-Location $taskRoot
try {
    New-Item -ItemType Directory -Path $taskLocal, $taskBuildTemp, $taskNugetScratch -Force | Out-Null
    $env:TMP = $taskBuildTemp
    $env:TEMP = $taskBuildTemp
    $env:NUGET_SCRATCH = $taskNugetScratch
    $env:DOTNET_CLI_HOME = Join-Path $taskToolsDir 'dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $env:APPDATA = Join-Path $taskToolsDir 'build-profile'

    $taskDotnet = Join-Path $taskToolsDir 'dotnet/dotnet.exe'
    if (!(Test-Path -LiteralPath $taskDotnet -PathType Leaf)) {
        $taskDotnet = (Get-Command dotnet).Source
    }

    $taskOrigin = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'native/SOURCE.json') -Raw | ConvertFrom-Json
    $taskPolicySource = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskRoot 'policy/upstream-codex/SOURCE.json') -Raw | ConvertFrom-Json

    $taskShippedScripts = @(
        'scripts/Apply-Update.ps1', 'scripts/Install.ps1', 'scripts/Uninstall.ps1',
        'scripts/Review-Mode.ps1', 'scripts/Resolve-Runtime.ps1'
    )
    $taskHashes = [ordered]@{
        service = Get-InputsSha256 $taskRoot @('src/AgApproval') @('bin', 'obj')
        panel   = Get-InputsSha256 $taskRoot @('src/AgApproval.Panel', 'scripts/Build-Panel.ps1')
        policy  = Get-InputsSha256 $taskRoot @('policy/upstream-codex', 'scripts/Prepare-Policy.mjs')
        plugin  = Get-InputsSha256 $taskRoot (@('plugin') + $taskShippedScripts)
    }
    $taskGuardianProdHashes = [ordered]@{}
    foreach ($file in @(
        'native/SOURCE.json', 'native/patches/guardian-entry.patch',
        'native/guardian-host/Cargo.toml', 'native/guardian-host/src/main.rs',
        'native/guardian-host/src/bootstrap.rs', 'policy/upstream-codex/SOURCE.json'
    )) {
        $taskGuardianProdHashes[$file] = Get-FileSha256 (Join-Path $taskRoot $file)
    }

    function Test-VerifiedGuardianDir([string]$Dir, [bool]$RequireSourceMatch) {
        $exePath = Join-Path $Dir 'ag-guardian-host.exe'
        $manifestPath = Join-Path $Dir 'SOURCE.json'
        foreach ($req in @($exePath, $manifestPath, (Join-Path $Dir 'UPSTREAM-LICENSE'), (Join-Path $Dir 'UPSTREAM-NOTICE'))) {
            if (!(Test-Path -LiteralPath $req -PathType Leaf)) { return $null }
        }
        try {
            $saved = Get-Content -Encoding UTF8 -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $actualSha = Get-FileSha256 $exePath
            if ($saved.binarySha256 -cne $actualSha) { return $null }
            $idRaw = & $exePath --version 2>$null
            if ($LASTEXITCODE -ne 0 -or !$idRaw) { return $null }
            $id = ($idRaw -join "`n") | ConvertFrom-Json
            if ($id.protocol -cne $taskOrigin.protocol -or $id.upstreamCommit -cne $taskOrigin.commit -or $id.version -cne $saved.version) {
                return $null
            }
            if ($RequireSourceMatch) {
                if ($saved.hostCommit -cne $taskOrigin.commit -or $saved.policySourceCommit -cne $taskPolicySource.commit) { return $null }
                foreach ($key in $taskGuardianProdHashes.Keys) {
                    if ($saved.sourceSha256.$key -cne $taskGuardianProdHashes[$key]) { return $null }
                }
            }
            return [pscustomobject]@{
                directory = $Dir
                profile   = [string]$saved.profile
                sha256    = $actualSha
                version   = [string]$saved.version
            }
        } catch {
            return $null
        }
    }

    $taskStatePath = Join-Path $taskLocal 'local-build-state.json'
    $taskPrevState = if (Test-Path -LiteralPath $taskStatePath -PathType Leaf) {
        try { Get-Content -Encoding UTF8 -LiteralPath $taskStatePath -Raw | ConvertFrom-Json } catch { $null }
    } else { $null }

    $taskBundle = Join-Path $taskRoot 'artifacts/gravity-guardian'
    $taskPanelCacheExe = Join-Path $taskLocal 'panel-build/GravityGuardian.exe'
    $taskBundlePluginJson = Join-Path $taskBundle 'plugin.json'
    $taskBundleHooksJson = Join-Path $taskBundle 'hooks.json'
    $taskBundleServiceDll = Join-Path $taskBundle 'scripts/gravity-guardian.dll'
    $taskBundlePanelExe = Join-Path $taskBundle 'app/GravityGuardian.exe'
    $taskBundlePolicySource = Join-Path $taskBundle 'policy/effective-codex/SOURCE.json'
    $taskRepoPolicySource = Join-Path $taskRoot 'policy/effective-codex/SOURCE.json'

    $taskPanelCacheValid = (Test-Path -LiteralPath $taskPanelCacheExe -PathType Leaf) -and
        ((Get-Item -LiteralPath $taskPanelCacheExe).VersionInfo.ProductVersion -ceq "$taskReleaseVersion.0")
    $taskBundlePanelValid = (Test-Path -LiteralPath $taskBundlePanelExe -PathType Leaf) -and
        ((Get-Item -LiteralPath $taskBundlePanelExe).VersionInfo.ProductVersion -ceq "$taskReleaseVersion.0")
    $taskBundleVersionMatches = (Test-Path -LiteralPath $taskBundlePluginJson -PathType Leaf) -and
        (((Get-Content -Encoding UTF8 -LiteralPath $taskBundlePluginJson -Raw | ConvertFrom-Json).version) -ceq $taskReleaseVersion)

    $taskGuardianCandidates = if ($PSBoundParameters.ContainsKey('GuardianProfile') -and $GuardianProfile -eq 'Dev') {
        @(
            (Join-Path $taskLocal 'guardian-host-dev'),
            (Join-Path $taskLocal 'guardian-host-build'),
            (Join-Path $taskBundle 'native')
        )
    } else {
        @(
            (Join-Path $taskLocal 'guardian-host-build'),
            (Join-Path $taskLocal 'guardian-host-dev'),
            (Join-Path $taskBundle 'native')
        )
    }

    $taskSelected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Components -contains 'All') {
        foreach ($c in @('Policy', 'Plugin', 'Service', 'Panel', 'Guardian')) { [void]$taskSelected.Add($c) }
    } elseif ($Components -contains 'Auto') {
        if (!$taskBundleVersionMatches -or !(Test-Path -LiteralPath $taskBundleHooksJson -PathType Leaf) -or
            !$taskPrevState -or $taskPrevState.hashes.plugin -cne $taskHashes.plugin) {
            [void]$taskSelected.Add('Plugin')
        }
        if (!(Test-Path -LiteralPath $taskRepoPolicySource -PathType Leaf) -or
            !(Test-Path -LiteralPath $taskBundlePolicySource -PathType Leaf) -or
            !$taskPrevState -or $taskPrevState.hashes.policy -cne $taskHashes.policy) {
            [void]$taskSelected.Add('Policy')
        }
        if (!$taskBundleVersionMatches -or !(Test-Path -LiteralPath $taskBundleServiceDll -PathType Leaf) -or
            !$taskPrevState -or $taskPrevState.hashes.service -cne $taskHashes.service) {
            [void]$taskSelected.Add('Service')
        }
        $taskPanelStale = !$taskPrevState -or $taskPrevState.hashes.panel -cne $taskHashes.panel
        if ($taskPanelStale -or (!$taskBundlePanelValid -and !$taskPanelCacheValid)) {
            [void]$taskSelected.Add('Panel')
        }
        $taskMatchedGuardian = $null
        foreach ($cand in $taskGuardianCandidates) {
            $taskMatchedGuardian = Test-VerifiedGuardianDir $cand $true
            if ($taskMatchedGuardian) { break }
        }
        if (!$taskMatchedGuardian) {
            [void]$taskSelected.Add('Guardian')
        }
    } else {
        foreach ($c in $Components) {
            if ($c -notin @('Auto', 'All')) { [void]$taskSelected.Add($c) }
        }
        if (!$taskBundleVersionMatches -or !(Test-Path -LiteralPath $taskBundleHooksJson -PathType Leaf)) {
            [void]$taskSelected.Add('Plugin')
        }
        if (!(Test-Path -LiteralPath $taskRepoPolicySource -PathType Leaf) -and !(Test-Path -LiteralPath $taskBundlePolicySource -PathType Leaf)) {
            [void]$taskSelected.Add('Policy')
        }
        if (!(Test-Path -LiteralPath $taskBundleServiceDll -PathType Leaf)) {
            [void]$taskSelected.Add('Service')
        }
        if (!$taskBundlePanelValid -and !$taskPanelCacheValid) {
            [void]$taskSelected.Add('Panel')
        }
    }
    if ($ForceGuardian) { [void]$taskSelected.Add('Guardian') }

    $taskResolvedGuardian = $null
    $taskReusedGuardianWarning = $false
    if (!$taskSelected.Contains('Guardian')) {
        foreach ($cand in $taskGuardianCandidates) {
            $taskResolvedGuardian = Test-VerifiedGuardianDir $cand $true
            if ($taskResolvedGuardian) { break }
        }
        if (!$taskResolvedGuardian) {
            foreach ($cand in @((Join-Path $taskBundle 'native'), (Join-Path $taskLocal 'guardian-host-build'), (Join-Path $taskLocal 'guardian-host-dev'))) {
                $taskResolvedGuardian = Test-VerifiedGuardianDir $cand $false
                if ($taskResolvedGuardian) { $taskReusedGuardianWarning = $true; break }
            }
        }
        if (!$taskResolvedGuardian) {
            throw 'No verified Native Guardian binary is available to reuse. Run .\scripts\Update-Local.ps1 -Components Guardian (or .\scripts\Build-Guardian.ps1 -Profile Dev).'
        }
        if ($taskReusedGuardianWarning) {
            Write-Warning "Reusing existing Guardian ($($taskResolvedGuardian.profile), SHA-256 $($taskResolvedGuardian.sha256)) without rebuilding modified Rust/policy inputs."
        }
    }

    $taskTimings = [ordered]@{}
    $taskBuiltList = [Collections.Generic.List[string]]::new()
    $taskReusedList = [Collections.Generic.List[string]]::new()

    if ($taskSelected.Contains('Policy')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & node (Join-Path $PSScriptRoot 'Prepare-Policy.mjs') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Policy preparation failed' }
        $sw.Stop()
        $taskTimings['policySeconds'] = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $taskBuiltList.Add('Policy')
    } else {
        $taskReusedList.Add('Policy')
    }

    if ($taskSelected.Contains('Guardian')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $mappedProfile = if ($GuardianProfile -eq 'Dev') { 'Debug' } else { 'Release' }
        & (Join-Path $PSScriptRoot 'Build-Guardian.ps1') -Profile $mappedProfile -ReleaseTuning $GuardianTuning -Offline:$OfflineGuardian -ForceBuild:$ForceGuardian | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Native Guardian build failed' }
        $sw.Stop()
        $taskTimings['guardianSeconds'] = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $guardianOutDir = if ($mappedProfile -eq 'Debug') {
            Join-Path $taskLocal 'guardian-host-dev'
        } elseif ($GuardianTuning -eq 'Default') {
            Join-Path $taskLocal 'guardian-host-build'
        } else {
            Join-Path $taskLocal "guardian-profiles/$GuardianTuning"
        }
        $taskResolvedGuardian = Test-VerifiedGuardianDir $guardianOutDir $false
        if (!$taskResolvedGuardian) { throw "Built Guardian verification failed in $guardianOutDir" }
        $taskBuiltList.Add("Guardian($GuardianProfile)")
    } else {
        $taskReusedList.Add("Guardian($($taskResolvedGuardian.profile))")
    }

    $taskStageScripts = $null
    if ($taskSelected.Contains('Service')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $serviceProj = Join-Path $taskRoot 'src/AgApproval/AgApproval.csproj'
        $testsProj = Join-Path $taskRoot 'tests/AgApproval.Tests/AgApproval.Tests.csproj'
        if ($RunTests) {
            if (Test-NeedsDotnetRestore $testsProj @($serviceProj)) {
                & $taskDotnet restore 'tests/AgApproval.Tests/AgApproval.Tests.csproj' --configfile (Join-Path $taskRoot 'NuGet.Config') --nologo | Out-Host
                if ($LASTEXITCODE -ne 0) { throw 'Offline test dependency restore failed' }
            }
        } elseif (Test-NeedsDotnetRestore $serviceProj) {
            & $taskDotnet restore 'src/AgApproval/AgApproval.csproj' --configfile (Join-Path $taskRoot 'NuGet.Config') --nologo | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Offline service dependency restore failed' }
        }
        $taskStageScripts = Join-Path $taskStageRoot 'scripts'
        New-Item -ItemType Directory -Path $taskStageScripts -Force | Out-Null
        & $taskDotnet publish 'src/AgApproval/AgApproval.csproj' -c Release --no-restore --self-contained false -p:UseAppHost=false -p:DebugType=None -p:DebugSymbols=false -o $taskStageScripts --nologo | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'C# service publish failed' }
        if ($RunTests) {
            & $taskDotnet run --project 'tests/AgApproval.Tests/AgApproval.Tests.csproj' -c Release --no-restore | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'C# verification failed' }
            $taskContract = Join-Path $taskLocal 'contract/input.json'
            $taskSchema = Join-Path $taskRoot 'schemas/review-input.schema.json'
            $taskValidator = Join-Path $PSScriptRoot 'Validate-Schema.mjs'
            & node $taskValidator $taskContract $taskSchema | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Review input contract validation failed' }
            & node $taskValidator $taskContract $taskSchema '--forged-role-check' | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Schema accepted forged trusted message role' }
            & (Join-Path $PSScriptRoot 'Test-LogStatistics.ps1') | Out-Host
        }
        $sw.Stop()
        $taskTimings['serviceSeconds'] = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $taskBuiltList.Add('Service')
    } else {
        $taskReusedList.Add('Service')
    }

    if ($taskSelected.Contains('Panel')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & (Join-Path $PSScriptRoot 'Build-Panel.ps1') -SkipSelfTest:$SkipPanelSelfTest | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Panel build failed' }
        if ((Get-Item -LiteralPath $taskPanelCacheExe).VersionInfo.ProductVersion -cne "$taskReleaseVersion.0") {
            throw 'Built panel product version differs from the release version'
        }
        $sw.Stop()
        $taskTimings['panelSeconds'] = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $taskBuiltList.Add('Panel')
    } else {
        $taskReusedList.Add('Panel')
    }

    # Incrementally sync artifacts/gravity-guardian without generating release ZIPs.
    $swSync = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType Directory -Path $taskBundle -Force | Out-Null

    $taskRuntime = Get-LockedDotnetRuntime
    $taskBundleRuntime = Join-Path $taskBundle 'runtime'
    $taskRuntimeMarkerFiles = @(
        (Join-Path $taskBundleRuntime 'dotnet.exe'),
        (Join-Path $taskBundleRuntime "host/fxr/$($taskRuntime.version)/hostfxr.dll"),
        (Join-Path $taskBundleRuntime "shared/Microsoft.NETCore.App/$($taskRuntime.version)/coreclr.dll")
    )
    $taskRuntimeReady = $true
    foreach ($rf in $taskRuntimeMarkerFiles) {
        if (!(Test-Path -LiteralPath $rf -PathType Leaf)) { $taskRuntimeReady = $false; break }
    }
    if (!$taskRuntimeReady) {
        $taskRuntimeStage = Join-Path $taskStageRoot 'runtime'
        New-Item -ItemType Directory -Path $taskRuntimeStage -Force | Out-Null
        $taskRuntimeArchive = [IO.Compression.ZipFile]::OpenRead($taskRuntime.archivePath)
        try {
            $taskRuntimeFiles = Get-LockedDotnetRuntimeFiles -Archive $taskRuntimeArchive -Version $taskRuntime.version
            foreach ($taskRuntimeFile in $taskRuntimeFiles.Values) {
                $taskTarget = Join-Path $taskRuntimeStage $taskRuntimeFile.FullName
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($taskTarget)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($taskRuntimeFile, $taskTarget)
            }
        } finally {
            $taskRuntimeArchive.Dispose()
        }
        if (Test-Path -LiteralPath $taskBundleRuntime) { Remove-Item -LiteralPath $taskBundleRuntime -Recurse -Force }
        Move-Item -LiteralPath $taskRuntimeStage -Destination $taskBundleRuntime
    }

    if ($taskSelected.Contains('Plugin')) {
        Copy-Item -Path (Join-Path $taskRoot 'plugin/*') -Destination $taskBundle -Recurse -Force
        $distMarker = Join-Path $taskBundle 'distribution.json'
        if (Test-Path -LiteralPath $distMarker -PathType Leaf) { Remove-Item -LiteralPath $distMarker -Force }
        $taskBuiltList.Add('Plugin')
    } else {
        $taskReusedList.Add('Plugin')
    }

    if ($taskSelected.Contains('Policy') -or !(Test-Path -LiteralPath $taskBundlePolicySource -PathType Leaf) -or
        !$taskPrevState -or $taskPrevState.hashes.policy -cne $taskHashes.policy) {
        Copy-DirectoryContent (Join-Path $taskRoot 'policy/effective-codex') (Join-Path $taskBundle 'policy/effective-codex')
    }

    $taskBundleScripts = Join-Path $taskBundle 'scripts'
    if ($taskStageScripts) {
        foreach ($taskScript in @('Apply-Update.ps1', 'Install.ps1', 'Uninstall.ps1', 'Review-Mode.ps1', 'Resolve-Runtime.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $taskScript) -Destination (Join-Path $taskStageScripts $taskScript) -Force
        }
        Copy-DirectoryContent $taskStageScripts $taskBundleScripts
    } else {
        New-Item -ItemType Directory -Path $taskBundleScripts -Force | Out-Null
        foreach ($taskScript in @('Apply-Update.ps1', 'Install.ps1', 'Uninstall.ps1', 'Review-Mode.ps1', 'Resolve-Runtime.ps1')) {
            [void](Sync-FileIfChanged (Join-Path $PSScriptRoot $taskScript) (Join-Path $taskBundleScripts $taskScript))
        }
    }

    if (Test-Path -LiteralPath $taskPanelCacheExe -PathType Leaf) {
        [void](Sync-FileIfChanged $taskPanelCacheExe $taskBundlePanelExe)
    }

    $taskBundleNative = Join-Path $taskBundle 'native'
    New-Item -ItemType Directory -Path $taskBundleNative -Force | Out-Null
    $taskGuardianSourceDir = [IO.Path]::GetFullPath($taskResolvedGuardian.directory)
    if ($taskGuardianSourceDir -ne [IO.Path]::GetFullPath($taskBundleNative)) {
        $exeChanged = Sync-FileIfChanged (Join-Path $taskGuardianSourceDir 'ag-guardian-host.exe') (Join-Path $taskBundleNative 'ag-guardian-host.exe')
        $manifestChanged = Sync-FileIfChanged (Join-Path $taskGuardianSourceDir 'SOURCE.json') (Join-Path $taskBundleNative 'SOURCE.json')
        if ($exeChanged -or $manifestChanged -or
            !(Test-Path -LiteralPath (Join-Path $taskBundleNative 'UPSTREAM-LICENSE') -PathType Leaf) -or
            !(Test-Path -LiteralPath (Join-Path $taskBundleNative 'UPSTREAM-NOTICE') -PathType Leaf)) {
            [void](Sync-FileIfChanged (Join-Path $taskGuardianSourceDir 'UPSTREAM-LICENSE') (Join-Path $taskBundleNative 'UPSTREAM-LICENSE'))
            [void](Sync-FileIfChanged (Join-Path $taskGuardianSourceDir 'UPSTREAM-NOTICE') (Join-Path $taskBundleNative 'UPSTREAM-NOTICE'))
        }
    }
    $swSync.Stop()
    $taskTimings['bundleSyncSeconds'] = [Math]::Round($swSync.Elapsed.TotalSeconds, 2)

    $taskStateRecord = [ordered]@{
        version = $taskReleaseVersion
        updatedAt = [DateTime]::UtcNow.ToString('O')
        hashes = $taskHashes
        guardian = [ordered]@{
            profile = $taskResolvedGuardian.profile
            sha256 = $taskResolvedGuardian.sha256
            sourceDirectory = $taskResolvedGuardian.directory
        }
        lastRun = [ordered]@{
            built = @($taskBuiltList)
            reused = @($taskReusedList)
            zipCount = 0
        }
    }
    $taskStateRecord | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskStatePath -Encoding utf8

    # Live installation and service startup must use the user's environment,
    # especially APPDATA, rather than the isolated build profile.
    Restore-LocalBuildEnvironment
    $taskDoctorPassed = $false
    if (!$BuildOnly) {
        $swInstall = [Diagnostics.Stopwatch]::StartNew()
        $installParams = @{}
        foreach ($passParam in @('GeminiRoot', 'DataDirectory', 'AntigravityPath', 'Proxy', 'ReviewMode', 'ReviewRouting', 'EnableDetailedLogs', 'NoStart', 'UseVerifiedCopyCommit')) {
            if ($PSBoundParameters.ContainsKey($passParam)) {
                $installParams[$passParam] = $PSBoundParameters[$passParam]
            }
        }
        & (Join-Path $PSScriptRoot 'Install.ps1') @installParams | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Local install failed' }
        $swInstall.Stop()
        $taskTimings['installSeconds'] = [Math]::Round($swInstall.Elapsed.TotalSeconds, 2)

        if (!$NoStart -and !$SkipDoctor) {
            $swDoc = [Diagnostics.Stopwatch]::StartNew()
            $effectiveGeminiRoot = if ($PSBoundParameters.ContainsKey('GeminiRoot') -and ![string]::IsNullOrWhiteSpace($GeminiRoot)) {
                $GeminiRoot
            } else {
                Join-Path $env:USERPROFILE '.gemini'
            }
            $effectiveDataDir = if ($PSBoundParameters.ContainsKey('DataDirectory') -and ![string]::IsNullOrWhiteSpace($DataDirectory)) {
                $DataDirectory
            } else {
                $installedApprovalPath = Join-Path $effectiveGeminiRoot 'config/plugins/gravity-guardian/approval.json'
                if (Test-Path -LiteralPath $installedApprovalPath -PathType Leaf) {
                    $installedApproval = Get-Content -Encoding UTF8 -LiteralPath $installedApprovalPath -Raw | ConvertFrom-Json
                    if ($installedApproval.dataDirectory) { [string]$installedApproval.dataDirectory } else { Join-Path $effectiveGeminiRoot 'gravity-guardian-data' }
                } else {
                    Join-Path $effectiveGeminiRoot 'gravity-guardian-data'
                }
            }
            & (Join-Path $PSScriptRoot 'Doctor.ps1') -DataDirectory $effectiveDataDir -SkipGuardianAuthCheck:$SkipGuardianAuthCheck | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Doctor check failed after local update' }
            $swDoc.Stop()
            $taskTimings['doctorSeconds'] = [Math]::Round($swDoc.Elapsed.TotalSeconds, 2)
            $taskDoctorPassed = $true
        }
    }

    $taskTotalWatch.Stop()
    [ordered]@{
        ok = $true
        version = $taskReleaseVersion
        bundleDirectory = $taskBundle
        built = @($taskBuiltList)
        reused = @($taskReusedList)
        guardianProfile = $taskResolvedGuardian.profile
        guardianSha256 = $taskResolvedGuardian.sha256
        installed = (-not [bool]$BuildOnly)
        doctorChecked = $taskDoctorPassed
        zipCount = 0
        timings = $taskTimings
        totalSeconds = [Math]::Round($taskTotalWatch.Elapsed.TotalSeconds, 2)
    } | ConvertTo-Json -Depth 6
} finally {
    if (Test-Path -LiteralPath $taskStageRoot) {
        Remove-Item -LiteralPath $taskStageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-LocalBuildEnvironment
    Pop-Location
}
