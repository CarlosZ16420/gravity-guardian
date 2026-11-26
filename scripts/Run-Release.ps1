[CmdletBinding()]
param([string]$EvidenceDirectory='', [switch]$Resume, [switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$fingerprint=& (Join-Path $PSScriptRoot 'Get-ReleaseFingerprint.ps1')
$commit=(& git -c "safe.directory=$($taskRoot.Replace('\','/'))" -C $taskRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify release commit' }
$dirty=[bool](& git -c "safe.directory=$($taskRoot.Replace('\','/'))" -C $taskRoot status --porcelain)
$version=(Get-Content -LiteralPath (Join-Path $taskRoot 'plugin/plugin.json') -Raw | ConvertFrom-Json).version
if (!$EvidenceDirectory) { $EvidenceDirectory=Join-Path $taskRoot ('.local/release-checks/'+[Guid]::NewGuid().ToString('N')) }
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
$stateFile=Join-Path $evidence 'release-state.json'
function Save-State {
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($stateFile+'.tmp') -Encoding utf8
    [IO.File]::Move(($stateFile+'.tmp'),$stateFile,$true)
}
function Snapshot-Files([string[]]$Paths) {
    @(foreach ($path in $Paths) {
        $file=Get-Item -LiteralPath (Join-Path $taskRoot $path)
        @{path=$path;sizeBytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
    })
}
function Assert-Snapshot($Files) {
    foreach ($file in $Files) {
        $path=Join-Path $taskRoot $file.path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $file.sizeBytes -or
            (Get-FileHash -LiteralPath $path).Hash -ine $file.sha256) { throw "Previously checked artifact changed: $($file.path). Start a new run." }
    }
}
if ($Resume) {
    $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
    if ($state.fingerprint -cne $fingerprint -or $state.commit -cne $commit) { throw 'Release inputs changed. Start a new run instead of reusing old checks.' }
    Assert-Snapshot $state.bundleFiles
    Assert-Snapshot $state.assets
} else {
    if (Test-Path -LiteralPath $evidence) { throw 'Evidence directory already exists; use -Resume or a new directory' }
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    $state=@{version=$version;commit=$commit;sourceDirty=$dirty;fingerprint=$fingerprint;result='in_progress';steps=@();bundleFiles=@();assets=@()}
    Save-State
}
function Invoke-Check([string]$Name,[scriptblock]$Action) {
    if (@($state.steps | Where-Object { $_.name -ceq $Name -and $_.result -ceq 'success' }).Count) {
        Write-Host "REUSE checked stage: $Name"
        return
    }
    if ((& (Join-Path $PSScriptRoot 'Get-ReleaseFingerprint.ps1')) -cne $fingerprint) { throw 'Source changed during release validation' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $global:LASTEXITCODE=0
    Write-Host "START $Name"
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "Release stage failed: $Name ($LASTEXITCODE)" }
    if ($Name -ceq 'Build') {
        $bundle=Join-Path $taskRoot 'artifacts/gravity-guardian'
        $paths=Get-ChildItem -LiteralPath $bundle -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($taskRoot,$_.FullName) }
        $state.bundleFiles=Snapshot-Files $paths
    }
    if ($Name -ceq 'Package') {
        $state.assets=Snapshot-Files @("artifacts/gravity-guardian-$version-windows-x64.zip","artifacts/gravity-guardian-$version-lite-windows-x64.zip","artifacts/gravity-guardian-$version-portable-windows-x64.zip",'artifacts/checksums.sha256','artifacts/release-manifest.json','artifacts/release-build-info.json')
    }
    $state.steps+=@{name=$Name;result='success';seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)}
    Save-State
    Write-Host "PASS $Name"
}
Push-Location $taskRoot
try {
    Invoke-Check 'Preflight and service tests' { & (Join-Path $PSScriptRoot 'Check-ReleasePreflight.ps1') -RunServiceTests }
    if ($PreflightOnly) { Write-Host "PREFLIGHT VERIFIED: $evidence"; return }
    # Preflight already executed the service, schema, statistics and privacy tests.
    Invoke-Check 'Build' { & (Join-Path $PSScriptRoot 'Build.ps1') -SkipTests }
    Invoke-Check 'Native prompt' {
        & (Join-Path $PSScriptRoot 'Build-Guardian.ps1') -SyncWorkspaceOnly
        & node (Join-Path $PSScriptRoot 'Test-NativePrompt.mjs') (Join-Path $evidence ('prompt-'+[Guid]::NewGuid().ToString('N').Substring(0,8))) --release
    }
    Invoke-Check 'Installation' { & (Join-Path $PSScriptRoot 'Test-Installation.ps1') }
    Invoke-Check 'Package' { & (Join-Path $PSScriptRoot 'Package.ps1') }
    Invoke-Check 'Update and rollback' { & (Join-Path $PSScriptRoot 'Test-Update.ps1') }
    Invoke-Check 'Standalone and Lite' { & (Join-Path $PSScriptRoot 'Test-Distributions.ps1') }
    Invoke-Check 'Portable' { & (Join-Path $PSScriptRoot 'Test-Portable.ps1') -PackageZip "artifacts/gravity-guardian-$version-portable-windows-x64.zip" }
    Invoke-Check 'Zero CLI trace' { & (Join-Path $PSScriptRoot 'Test-NoCli.ps1') -OutputDirectory (Join-Path $evidence ('no-cli-'+[Guid]::NewGuid().ToString('N').Substring(0,8))) }
    Assert-Snapshot $state.assets
    if ((& (Join-Path $PSScriptRoot 'Get-ReleaseFingerprint.ps1')) -cne $fingerprint) { throw 'Release source changed before final acceptance' }
    $state.result='success'
    $state.completedAt=[DateTime]::UtcNow.ToString('O')
    Save-State
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskRoot 'artifacts/release-acceptance.json') -Encoding utf8
    $state.steps | Format-Table name,seconds,result
    Write-Host "RELEASE VERIFIED: $evidence"
} finally { Pop-Location }
