[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Locked-DotnetRuntime.ps1')

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskRuntime = Get-LockedDotnetRuntime
$taskBundle = Join-Path $taskRoot 'artifacts/codex-approval'
$taskVersion = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskBundle 'plugin.json') -Raw | ConvertFrom-Json).version
$taskStage = Join-Path $taskRoot ('artifacts/releases/stage-' + [Guid]::NewGuid().ToString('N'))
$taskRelease = Join-Path $taskStage ('gravity-steward-' + $taskVersion)

New-Item -ItemType Directory -Path (Join-Path $taskRelease 'artifacts') -Force | Out-Null
Copy-Item -LiteralPath $taskBundle -Destination (Join-Path $taskRelease 'artifacts/codex-approval') -Recurse
Copy-Item -LiteralPath (Join-Path $taskBundle 'app/CodexApprovalPanel.exe') -Destination (Join-Path $taskRelease 'GravitySteward.exe') -Force

New-Item -ItemType Directory -Path (Join-Path $taskRelease 'scripts') -Force | Out-Null
foreach ($taskName in @('Install.ps1','Uninstall.ps1','Review-Mode.ps1','Doctor.ps1','Analyze-Logs.ps1','Compact-Logs.ps1','Apply-Update.ps1','Test-Hooks.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $taskName) -Destination (Join-Path $taskRelease 'scripts')
}

New-Item -ItemType Directory -Path (Join-Path $taskRelease 'docs') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskRoot "docs/release-$taskVersion.md") -Destination (Join-Path $taskRelease 'docs')

Copy-Item -LiteralPath (Join-Path $taskRoot 'LICENSE') -Destination (Join-Path $taskRelease 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'NOTICE') -Destination (Join-Path $taskRelease 'NOTICE') -Force
foreach ($taskReadme in @('README.md', 'README.en.md')) {
    Copy-Item -LiteralPath (Join-Path $taskRoot $taskReadme) -Destination $taskRelease
}
Copy-Item -LiteralPath (Join-Path $taskRoot 'schemas') -Destination $taskRelease -Recurse

$taskReleaseFiles = @(Get-ChildItem -LiteralPath $taskRelease -Recurse -File -Force | Sort-Object FullName)
$taskFiles = @($taskReleaseFiles | ForEach-Object {
    @{
        path = (Get-RelativePathCompat $taskRelease $_.FullName).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$taskPackageManifest = Join-Path $taskRelease 'package-manifest.json'
@{
    version = $taskVersion
    builtAt = [DateTime]::UtcNow.ToString('O')
    deploymentStatusSource = 'Use Doctor or CodexApprovalPanel status; package metadata is not live deployment state'
    files = $taskFiles
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskPackageManifest -Encoding utf8

$taskExpectedFiles = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($taskFile in $taskFiles) { $taskExpectedFiles.Add($taskFile.path, $taskFile.sha256) }
$taskExpectedFiles.Add('package-manifest.json', (Get-FileHash -LiteralPath $taskPackageManifest -Algorithm SHA256).Hash.ToLowerInvariant())

$taskZipName = "gravity-steward-$taskVersion-windows-x64.zip"
$taskZip = Join-Path $taskRoot ('artifacts/' + $taskZipName)
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
        $taskExpectedRuntime = Get-LockedDotnetRuntimeFiles -Archive $taskRuntimeArchive -Version $taskRuntime.version
        $taskRuntimePrefix = 'artifacts/codex-approval/runtime/'
        $taskNativeExe = 'artifacts/codex-approval/native/ag-guardian-host.exe'
        $taskNativeManifest = 'artifacts/codex-approval/native/SOURCE.json'
        $taskPanel = 'artifacts/codex-approval/app/CodexApprovalPanel.exe'
        $taskRequiredFiles = @(
            'GravitySteward.exe', $taskNativeExe, $taskNativeManifest, $taskPanel
            'artifacts/codex-approval/hooks.json'
            'artifacts/codex-approval/scripts/ag-approval.dll'
            'artifacts/codex-approval/scripts/ag-approval.deps.json'
            'artifacts/codex-approval/scripts/ag-approval.runtimeconfig.json'
        )
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
        if ($taskFileHashes['GravitySteward.exe'] -cne $taskFileHashes[$taskPanel]) { throw 'Panel entry points differ' }
    } finally {
        $taskRuntimeArchive.Dispose()
    }
} finally {
    $taskArchive.Dispose()
}

$taskZipHash = (Get-FileHash -LiteralPath $taskStagedZip -Algorithm SHA256).Hash.ToLowerInvariant()
$taskStagedChecksums = Join-Path $taskStage 'checksums.sha256'
Set-Utf8NoBom -LiteralPath $taskStagedChecksums -Content ("$taskZipHash *$taskZipName`n")

$taskRepo = 'CarlosZ16420/gravity-steward'
$taskUpdCfgPath = Join-Path $taskBundle 'update-config.json'
if (Test-Path -LiteralPath $taskUpdCfgPath -PathType Leaf) {
    $taskUpdCfg = Get-Content -Encoding UTF8 -LiteralPath $taskUpdCfgPath -Raw | ConvertFrom-Json
    if ($taskUpdCfg.repository) { $taskRepo = [string]$taskUpdCfg.repository }
}

$taskStagedManifest = Join-Path $taskStage 'release-manifest.json'
@{
    version = $taskVersion
    publishedAt = [DateTime]::UtcNow.ToString('O')
    assetName = $taskZipName
    downloadUrl = "https://github.com/$taskRepo/releases/download/v$taskVersion/$taskZipName"
    sha256 = $taskZipHash
    sizeBytes = $taskZipSize
    minAntigravityVersion = '2.32.0'
    releaseNotes = "Gravity Steward ${taskVersion}: Codex-powered tool approvals for Antigravity on Windows."
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskStagedManifest -Encoding utf8

$taskStagedBuildInfo = Join-Path $taskStage 'release-build-info.json'
@{
    rootDirectory = $taskPrefix.TrimEnd('/')
    assetName = $taskZipName
    zipSizeBytes = $taskZipSize
    zipSha256 = $taskZipHash
    unpackedSizeBytes = $taskUnpackedBytes
    fileCount = $taskTree.Count
    dotnetRuntimeVersion = $taskRuntime.version
    dotnetRuntimeArchiveSha256 = $taskRuntime.sha256
    guardianHostSha256 = $taskFileHashes[$taskNativeExe]
    files = $taskTree
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskStagedBuildInfo -Encoding utf8

$taskArtifacts = Join-Path $taskRoot 'artifacts'
$taskChecksumsPath = Join-Path $taskArtifacts 'checksums.sha256'
$taskManifestPath = Join-Path $taskArtifacts 'release-manifest.json'
$taskBuildInfoPath = Join-Path $taskArtifacts 'release-build-info.json'
$taskPublishLock = [IO.File]::Open((Join-Path $taskArtifacts '.package.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    [IO.File]::Move($taskStagedZip, $taskZip, $true)
    [IO.File]::Move($taskStagedChecksums, $taskChecksumsPath, $true)
    [IO.File]::Move($taskStagedBuildInfo, $taskBuildInfoPath, $true)
    [IO.File]::Move($taskStagedManifest, $taskManifestPath, $true)
} finally {
    $taskPublishLock.Dispose()
}

@{
    package = $taskZip
    manifest = $taskManifestPath
    checksums = $taskChecksumsPath
    buildInfo = $taskBuildInfoPath
    sha256 = $taskZipHash
    files = $taskFiles.Count
    bytes = $taskZipSize
} | ConvertTo-Json
