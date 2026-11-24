[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

$taskRoot = Split-Path $PSScriptRoot -Parent
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

$taskFiles = @(Get-ChildItem -LiteralPath $taskRelease -Recurse -File | ForEach-Object {
    @{ path = (Get-RelativePathCompat $taskRelease $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
@{
    version = $taskVersion
    builtAt = [DateTime]::UtcNow.ToString('O')
    deploymentStatusSource = 'Use Doctor or CodexApprovalPanel status; package metadata is not live deployment state'
    files = $taskFiles
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath (Join-Path $taskRelease 'package-manifest.json') -Encoding utf8

$taskZipName = "gravity-steward-$taskVersion-windows-x64.zip"
$taskZip = Join-Path $taskRoot ('artifacts/' + $taskZipName)
if (Test-Path -LiteralPath $taskZip) { Remove-Item -LiteralPath $taskZip -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$taskZipStream = [IO.File]::Open($taskZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $taskArchive = [IO.Compression.ZipArchive]::new($taskZipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $taskPrefix = Split-Path $taskRelease -Leaf
        foreach ($taskItem in Get-ChildItem -LiteralPath $taskRelease -Recurse -File) {
            $taskEntryName = ($taskPrefix + '/' + (Get-RelativePathCompat $taskRelease $taskItem.FullName)).Replace('\', '/')
            $taskEntry = $taskArchive.CreateEntry($taskEntryName, [IO.Compression.CompressionLevel]::Optimal)
            $taskEntry.LastWriteTime = [DateTimeOffset]$taskItem.LastWriteTime
            $taskIn = [IO.File]::Open($taskItem.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            try { $taskOut = $taskEntry.Open(); try { $taskIn.CopyTo($taskOut) } finally { $taskOut.Dispose() } } finally { $taskIn.Dispose() }
        }
    } finally { $taskArchive.Dispose() }
} finally { $taskZipStream.Dispose() }

$taskZipHash = (Get-FileHash -LiteralPath $taskZip -Algorithm SHA256).Hash.ToLowerInvariant()
$taskZipSize = (Get-Item -LiteralPath $taskZip).Length

$taskChecksumsPath = Join-Path $taskRoot 'artifacts/checksums.sha256'
Set-Utf8NoBom -LiteralPath $taskChecksumsPath -Content ("$taskZipHash *$taskZipName`n")

$taskRepo = 'CarlosZ16420/gravity-steward'
$taskUpdCfgPath = Join-Path $taskBundle 'update-config.json'
if (Test-Path -LiteralPath $taskUpdCfgPath -PathType Leaf) {
    $taskUpdCfg = Get-Content -Encoding UTF8 -LiteralPath $taskUpdCfgPath -Raw | ConvertFrom-Json
    if ($taskUpdCfg.repository) { $taskRepo = [string]$taskUpdCfg.repository }
}

$taskManifestPath = Join-Path $taskRoot 'artifacts/release-manifest.json'
@{
    version = $taskVersion
    publishedAt = [DateTime]::UtcNow.ToString('O')
    assetName = $taskZipName
    downloadUrl = "https://github.com/$taskRepo/releases/download/v$taskVersion/$taskZipName"
    sha256 = $taskZipHash
    sizeBytes = $taskZipSize
    minAntigravityVersion = '2.32.0'
    releaseNotes = "Gravity Steward ${taskVersion}: Codex-powered tool approvals for Antigravity on Windows."
} | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskManifestPath -Encoding utf8

@{
    package = $taskZip
    manifest = $taskManifestPath
    checksums = $taskChecksumsPath
    sha256 = $taskZipHash
    files = $taskFiles.Count
    bytes = $taskZipSize
} | ConvertTo-Json
