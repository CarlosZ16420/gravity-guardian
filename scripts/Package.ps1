[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Locked-DotnetRuntime.ps1')

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskBuildTemp = Join-Path $taskRoot '.local/build-temp'
New-Item -ItemType Directory -Path $taskBuildTemp -Force | Out-Null
$taskOriginalTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
$taskOriginalTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
$env:TMP = $taskBuildTemp
$env:TEMP = $taskBuildTemp
try {
$taskRuntime = Get-LockedDotnetRuntime
$taskBundle = Join-Path $taskRoot 'artifacts/gravity-guardian'
$taskGuardianManifestPath = Join-Path $taskBundle 'native/SOURCE.json'
if (!(Test-Path -LiteralPath $taskGuardianManifestPath -PathType Leaf)) {
    throw "Missing Guardian manifest in $taskBundle. Run .\scripts\Build.ps1 first."
}
$taskBundleGuardian = Get-Content -Encoding UTF8 -LiteralPath $taskGuardianManifestPath -Raw | ConvertFrom-Json
if ($taskBundleGuardian.profile -cne 'Release') {
    throw "Refusing to package a non-Release Guardian build ($($taskBundleGuardian.profile)). Run .\scripts\Build.ps1 first."
}
$taskVersion = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskBundle 'plugin.json') -Raw | ConvertFrom-Json).version
$taskStage = Join-Path $taskRoot ('artifacts/releases/stage-' + [Guid]::NewGuid().ToString('N'))

function New-ReleaseArchive([ValidateSet('standalone','lite','portable')][string]$Distribution) {
$taskPortable = $Distribution -eq 'portable'
$taskRelease = Join-Path (Join-Path $taskStage $Distribution) ('gravity-guardian-' + $taskVersion)
$taskBundleRelative = if ($taskPortable) { 'app' } else { 'artifacts/gravity-guardian' }
$taskPackageBundle = Join-Path $taskRelease $taskBundleRelative

New-Item -ItemType Directory -Path $taskPackageBundle -Force | Out-Null
foreach ($item in (Get-ChildItem -LiteralPath $taskBundle -Force)) {
    if ($Distribution -eq 'lite' -and $item.Name -eq 'runtime') { continue }
    if ($taskPortable -and $item.Name -eq 'app') { continue }
    Copy-Item -LiteralPath $item.FullName -Destination $taskPackageBundle -Recurse
}
@{ type = $(if ($taskPortable) { 'standalone' } else { $Distribution }) } | ConvertTo-Json -Compress |
    Set-Utf8NoBom -LiteralPath (Join-Path $taskPackageBundle 'distribution.json')
Copy-Item -LiteralPath (Join-Path $taskBundle 'app/GravityGuardian.exe') -Destination (Join-Path $taskRelease 'GravityGuardian.exe') -Force

if (!$taskPortable) {
New-Item -ItemType Directory -Path (Join-Path $taskRelease 'scripts') -Force | Out-Null
foreach ($taskName in @('Install.ps1','Uninstall.ps1','Review-Mode.ps1','Resolve-Runtime.ps1','Doctor.ps1','Analyze-Logs.ps1','Compact-Logs.ps1','Apply-Update.ps1','Test-Hooks.ps1','Portable.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $taskName) -Destination (Join-Path $taskRelease 'scripts')
}
}

$taskDocs = if ($taskPortable) { Join-Path $taskPackageBundle 'docs' } else { Join-Path $taskRelease 'docs' }
New-Item -ItemType Directory -Path $taskDocs -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskRoot "docs/release-$taskVersion.md") -Destination $taskDocs
foreach ($taskNote in @('guardian-0.172.0-validation.md', 'release-native-guardian.md')) {
    Copy-Item -LiteralPath (Join-Path $taskRoot "docs/$taskNote") -Destination $taskDocs
}

$taskLegal = if ($taskPortable) { $taskDocs } else { $taskRelease }
Copy-Item -LiteralPath (Join-Path $taskRoot 'LICENSE') -Destination (Join-Path $taskLegal 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'NOTICE') -Destination (Join-Path $taskLegal 'NOTICE') -Force
if ($taskPortable) {
    Copy-Item -LiteralPath (Join-Path $taskRoot 'docs/portable.md') -Destination (Join-Path $taskRelease 'README.md')
    @{storageMode='portable';layoutVersion=1;distribution='standalone'} | ConvertTo-Json -Compress | Set-Utf8NoBom -LiteralPath (Join-Path $taskRelease 'portable.json')
} else {
foreach ($taskReadme in @('README.md', 'README.en.md')) {
    Copy-Item -LiteralPath (Join-Path $taskRoot $taskReadme) -Destination $taskRelease
}
Copy-Item -LiteralPath (Join-Path $taskRoot 'schemas') -Destination $taskRelease -Recurse
}

$taskReleaseFiles = @(Get-ChildItem -LiteralPath $taskRelease -Recurse -File -Force | Sort-Object FullName)
$taskFiles = @($taskReleaseFiles | ForEach-Object {
    @{
        path = (Get-RelativePathCompat $taskRelease $_.FullName).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$taskManifestRelative = if ($taskPortable) { 'app/package-manifest.json' } else { 'package-manifest.json' }
$taskPackageManifest = Join-Path $taskRelease $taskManifestRelative
@{
    version = $taskVersion
    distribution = $Distribution
    storageMode = $(if ($taskPortable) { 'portable' } else { 'installed' })
    layoutVersion = $(if ($taskPortable) { 1 } else { 0 })
    builtAt = [DateTime]::UtcNow.ToString('O')
    deploymentStatusSource = 'Use Doctor or GravityGuardian status; package metadata is not live deployment state'
    files = $taskFiles
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskPackageManifest -Encoding utf8

$taskExpectedFiles = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($taskFile in $taskFiles) { $taskExpectedFiles.Add($taskFile.path, $taskFile.sha256) }
$taskExpectedFiles.Add($taskManifestRelative, (Get-FileHash -LiteralPath $taskPackageManifest -Algorithm SHA256).Hash.ToLowerInvariant())

$taskSuffix = if ($Distribution -eq 'standalone') { '' } else { '-'+$Distribution }
$taskZipName = "gravity-guardian-$taskVersion$taskSuffix-windows-x64.zip"
$taskStagedZip = Join-Path $taskStage $taskZipName
$taskPrefix = (Split-Path $taskRelease -Leaf) + '/'

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$taskZipStream = [IO.File]::Open($taskStagedZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $taskArchive = [IO.Compression.ZipArchive]::new($taskZipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($taskItem in $taskReleaseFiles + @(Get-Item -LiteralPath $taskPackageManifest)) {
            $taskEntryName = $taskPrefix + (Get-RelativePathCompat $taskRelease $taskItem.FullName).Replace('\', '/')
            $taskEntry = $taskArchive.CreateEntry($taskEntryName, [IO.Compression.CompressionLevel]::Optimal)
            $taskEntry.LastWriteTime = [DateTimeOffset]$taskItem.LastWriteTime
            $taskIn = [IO.File]::Open($taskItem.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            try { $taskOut = $taskEntry.Open(); try { $taskIn.CopyTo($taskOut) } finally { $taskOut.Dispose() } } finally { $taskIn.Dispose() }
        }
    } finally { $taskArchive.Dispose() }
} finally { $taskZipStream.Dispose() }

$taskZipSize = (Get-Item -LiteralPath $taskStagedZip).Length
if ($taskZipSize -gt 120MB) { throw "Release ZIP exceeds 120 MiB: $taskZipSize bytes" }

$taskArchive = [IO.Compression.ZipFile]::OpenRead($taskStagedZip)
try {
    $taskRuntimeArchive = [IO.Compression.ZipFile]::OpenRead($taskRuntime.archivePath)
    try {
        $taskExpectedRuntime = if ($Distribution -ne 'lite') {
            Get-LockedDotnetRuntimeFiles -Archive $taskRuntimeArchive -Version $taskRuntime.version
        } else { @{} }
        $taskRuntimePrefix = $taskBundleRelative+'/runtime/'
        $taskNativeExe = $taskBundleRelative+'/native/ag-guardian-host.exe'
        $taskNativeManifest = $taskBundleRelative+'/native/SOURCE.json'
        $taskPanel = 'artifacts/gravity-guardian/app/GravityGuardian.exe'
        $taskRequiredFiles = @(
            'GravityGuardian.exe', $taskNativeExe, $taskNativeManifest
            ($taskBundleRelative+'/hooks.json')
            ($taskBundleRelative+'/scripts/gravity-guardian.dll')
            ($taskBundleRelative+'/scripts/gravity-guardian.deps.json')
            ($taskBundleRelative+'/scripts/gravity-guardian.runtimeconfig.json')
        )
        if (!$taskPortable) { $taskRequiredFiles += $taskPanel }
        else { $taskRequiredFiles += 'portable.json' }
        foreach ($taskRequired in $taskRequiredFiles) {
            if (!$taskExpectedFiles.ContainsKey($taskRequired)) { throw "Missing required release file: $taskRequired" }
        }
        $taskUnpackedBytes = [long]0
        $taskRuntimeFileCount = 0
        $taskTree = @(foreach ($taskEntry in $taskArchive.Entries) {
            if (!$taskEntry.FullName.StartsWith($taskPrefix, [StringComparison]::Ordinal)) {
                throw "Unexpected ZIP entry: $($taskEntry.FullName)"
            }
            $taskPath = $taskEntry.FullName.Substring($taskPrefix.Length)
            if ($taskPath -match '\.pdb$') { throw "Debug symbols found in release ZIP: $taskPath" }
            $taskExpectedHash = $null
            if (!$taskExpectedFiles.Remove($taskPath, [ref]$taskExpectedHash)) {
                throw "Unexpected or duplicate ZIP entry: $taskPath"
            }
            $taskUnpackedBytes += $taskEntry.Length
            if ($taskUnpackedBytes -gt 310MB) { throw "Unpacked release exceeds 310 MiB: $taskUnpackedBytes bytes" }
            $taskStream = $taskEntry.Open()
            try {
                $taskHash = (Get-FileHash -InputStream $taskStream -Algorithm SHA256).Hash.ToLowerInvariant()
            } finally {
                $taskStream.Dispose()
            }
            if ($taskHash -cne $taskExpectedHash) { throw "ZIP entry SHA-256 mismatch: $taskPath" }
            if ($taskPath.StartsWith($taskRuntimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $taskRuntimePath = $taskPath.Substring($taskRuntimePrefix.Length)
                if (!$taskExpectedRuntime.ContainsKey($taskRuntimePath)) {
                    throw "Unexpected file in bundled .NET runtime: $taskRuntimePath"
                }
                $taskRuntimeStream = $taskExpectedRuntime[$taskRuntimePath].Open()
                try {
                    $taskRuntimeHash = (Get-FileHash -InputStream $taskRuntimeStream -Algorithm SHA256).Hash.ToLowerInvariant()
                } finally {
                    $taskRuntimeStream.Dispose()
                }
                if ($taskHash -cne $taskRuntimeHash) { throw "Bundled .NET runtime SHA-256 mismatch: $taskRuntimePath" }
                $taskRuntimeFileCount++
            }
            @{ path = $taskPath; sizeBytes = $taskEntry.Length; sha256 = $taskHash }
        })
        if ($taskExpectedFiles.Count -ne 0) { throw "Release ZIP is missing $($taskExpectedFiles.Count) expected files" }
        if ($taskRuntimeFileCount -ne $taskExpectedRuntime.Count) {
            throw "Bundled .NET runtime file count mismatch: expected $($taskExpectedRuntime.Count), found $taskRuntimeFileCount"
        }

        $taskFileHashes = @{}
        foreach ($taskFile in $taskTree) { $taskFileHashes[$taskFile.path] = $taskFile.sha256 }
        $taskReader = [IO.StreamReader]::new($taskArchive.GetEntry($taskPrefix + $taskNativeManifest).Open())
        try {
            $taskGuardian = $taskReader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $taskReader.Dispose()
        }
        if ($taskFileHashes[$taskNativeExe] -ne $taskGuardian.binarySha256) { throw 'Guardian SHA-256 differs from native/SOURCE.json' }
        if (!$taskPortable -and $taskFileHashes['GravityGuardian.exe'] -cne $taskFileHashes[$taskPanel]) { throw 'Panel entry points differ' }
    } finally {
        $taskRuntimeArchive.Dispose()
    }
} finally {
    $taskArchive.Dispose()
}

$taskZipHash = (Get-FileHash -LiteralPath $taskStagedZip -Algorithm SHA256).Hash.ToLowerInvariant()
@{
    distribution = $Distribution
    rootDirectory = $taskPrefix.TrimEnd('/')
    assetName = $taskZipName
    zipSizeBytes = $taskZipSize
    zipSha256 = $taskZipHash
    unpackedSizeBytes = $taskUnpackedBytes
    fileCount = $taskTree.Count
    dotnetRuntimeVersion = $(if ($Distribution -ne 'lite') { $taskRuntime.version })
    dotnetRuntimeArchiveSha256 = $(if ($Distribution -ne 'lite') { $taskRuntime.sha256 })
    guardianHostSha256 = $taskFileHashes[$taskNativeExe]
    files = $taskTree
}
}

$taskStandalone = New-ReleaseArchive 'standalone'
$taskLite = New-ReleaseArchive 'lite'
$taskPortableBuild = New-ReleaseArchive 'portable'
$taskBuilds = [ordered]@{ standalone = $taskStandalone; lite = $taskLite; portable = $taskPortableBuild }
if ($taskPortableBuild.guardianHostSha256 -cne $taskStandalone.guardianHostSha256) { throw 'Portable Guardian differs from Standalone' }
if ($taskPortableBuild.zipSizeBytes -gt $taskStandalone.zipSizeBytes -or $taskPortableBuild.unpackedSizeBytes -gt $taskStandalone.unpackedSizeBytes) { throw 'Portable package must not exceed the matching Standalone package size' }
$taskSharedFiles = @{}
foreach ($file in $taskStandalone.files) { $taskSharedFiles[$file.path] = $file.sha256 }
foreach ($file in $taskLite.files) {
    if ($file.path -in @('package-manifest.json','artifacts/gravity-guardian/distribution.json')) { continue }
    if ($taskSharedFiles[$file.path] -cne $file.sha256) { throw "Distributions disagree on common file: $($file.path)" }
}
$taskStagedChecksums = Join-Path $taskStage 'checksums.sha256'
$taskChecksumLines = foreach ($build in $taskBuilds.Values) { "$($build.zipSha256) *$($build.assetName)" }
Set-Utf8NoBom -LiteralPath $taskStagedChecksums -Content (($taskChecksumLines -join [char]10) + [char]10)

$taskRepo = 'CarlosZ16420/gravity-guardian'
$taskUpdCfgPath = Join-Path $taskBundle 'update-config.json'
if (Test-Path -LiteralPath $taskUpdCfgPath -PathType Leaf) {
    $taskUpdCfg = Get-Content -Encoding UTF8 -LiteralPath $taskUpdCfgPath -Raw | ConvertFrom-Json
    if ($taskUpdCfg.repository) { $taskRepo = [string]$taskUpdCfg.repository }
}

$taskStagedManifest = Join-Path $taskStage 'release-manifest.json'
$taskAssets = [ordered]@{}
foreach ($build in $taskBuilds.Values) {
    $taskAssets[$build.distribution] = @{
        assetName = $build.assetName; sizeBytes = $build.zipSizeBytes; sha256 = $build.zipSha256
        downloadUrl = "https://github.com/$taskRepo/releases/download/v$taskVersion/$($build.assetName)"
    }
}
@{
    version = $taskVersion
    publishedAt = [DateTime]::UtcNow.ToString('O')
    assetName = $taskAssets.standalone.assetName
    downloadUrl = $taskAssets.standalone.downloadUrl
    sha256 = $taskAssets.standalone.sha256
    sizeBytes = $taskAssets.standalone.sizeBytes
    distributions = $taskAssets
    minAntigravityVersion = '2.32.0'
    releaseNotes = "Gravity Guardian ${taskVersion}: Codex-powered tool approvals for Antigravity on Windows."
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskStagedManifest -Encoding utf8

$taskStagedBuildInfo = Join-Path $taskStage 'release-build-info.json'
$taskBuildInfo = $taskStandalone.Clone()
$taskBuildInfo.distributions = $taskBuilds
$taskBuildInfo | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskStagedBuildInfo -Encoding utf8

$taskArtifacts = Join-Path $taskRoot 'artifacts'
$taskChecksumsPath = Join-Path $taskArtifacts 'checksums.sha256'
$taskManifestPath = Join-Path $taskArtifacts 'release-manifest.json'
$taskBuildInfoPath = Join-Path $taskArtifacts 'release-build-info.json'
$taskPublishLock = [IO.File]::Open((Join-Path $taskArtifacts '.package.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    foreach ($build in $taskBuilds.Values) {
        [IO.File]::Move((Join-Path $taskStage $build.assetName), (Join-Path $taskArtifacts $build.assetName), $true)
    }
    [IO.File]::Move($taskStagedChecksums, $taskChecksumsPath, $true)
    [IO.File]::Move($taskStagedBuildInfo, $taskBuildInfoPath, $true)
    [IO.File]::Move($taskStagedManifest, $taskManifestPath, $true)
} finally {
    $taskPublishLock.Dispose()
}

@{
    package = Join-Path $taskArtifacts $taskStandalone.assetName
    litePackage = Join-Path $taskArtifacts $taskLite.assetName
    portablePackage = Join-Path $taskArtifacts $taskPortableBuild.assetName
    manifest = $taskManifestPath
    checksums = $taskChecksumsPath
    buildInfo = $taskBuildInfoPath
    sha256 = $taskStandalone.zipSha256
    files = $taskStandalone.fileCount
    bytes = $taskStandalone.zipSizeBytes
} | ConvertTo-Json
} finally {
    if ($taskStage -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($taskStage)) -eq (Join-Path $taskRoot 'artifacts/releases') -and
        (Split-Path $taskStage -Leaf) -match '^stage-[a-f0-9]{32}$' -and
        (Test-Path -LiteralPath $taskStage)) {
        Remove-Item -LiteralPath $taskStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $taskOriginalTmp) { Remove-Item -LiteralPath 'Env:TMP' -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('TMP', [string]$taskOriginalTmp, 'Process') }
    if ($null -eq $taskOriginalTemp) { Remove-Item -LiteralPath 'Env:TEMP' -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('TEMP', [string]$taskOriginalTemp, 'Process') }
}
