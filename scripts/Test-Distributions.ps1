[CmdletBinding()]
param([string]$OutputDirectory, [string]$PreviousPackage)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$root = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $root 'artifacts'
$manifest = Get-Content -LiteralPath (Join-Path $artifacts 'release-manifest.json') -Raw | ConvertFrom-JsonHashtable
$sandbox = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else {
    Join-Path $root ('.local/distribution-test/' + [Guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $sandbox) { throw 'Refusing to overwrite distribution test evidence' }
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$releases = @{}
$assetPaths = @{}
foreach ($type in @('standalone', 'lite')) {
    $asset = $manifest.distributions[$type]
    $zip = Join-Path $artifacts $asset.assetName
    if ((Get-FileHash -LiteralPath $zip).Hash -ine $asset.sha256 -or (Get-Item -LiteralPath $zip).Length -ne $asset.sizeBytes) {
        throw "Release manifest differs from $type ZIP"
    }
    $destination = Join-Path $sandbox $type
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $destination)
    $releases[$type] = Join-Path $destination ('gravity-steward-' + $manifest.version)
    $assetPaths[$type] = $zip
}
if ($manifest.assetName -cne $manifest.distributions.standalone.assetName -or $manifest.sha256 -cne $manifest.distributions.standalone.sha256) {
    throw 'Legacy manifest fields must point to Standalone'
}

function New-TestProfile([string]$Name) {
    $profile = Join-Path $sandbox $Name
    $gemini = Join-Path $profile 'Windows 测试 profile/.gemini'
    $config = Join-Path $gemini 'config'
    $data = Join-Path $profile 'data'
    New-Item -ItemType Directory -Path $config, $data -Force | Out-Null
    @{ userSettings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_DEFAULT'; enableTerminalSandbox = $true }; sidecars = @{} } |
        ConvertTo-Json -Depth 6 | Set-Utf8NoBom -LiteralPath (Join-Path $config 'config.json')
    return @{ gemini = $gemini; data = $data; plugin = (Join-Path $config 'plugins/codex-approval') }
}

function Test-Installed([hashtable]$Profile, [string]$Type) {
    if ((Get-ApprovalDistribution $Profile.plugin) -cne $Type) { throw "Expected installed $Type" }
    if ((Test-Path -LiteralPath (Join-Path $Profile.plugin 'runtime')) -ne ($Type -eq 'standalone')) {
        throw 'Installed runtime directory disagrees with distribution'
    }
    $dotnet = Resolve-ApprovalRuntime $Profile.plugin -Installed
    $sidecar = Get-Content -LiteralPath (Join-Path $Profile.plugin 'sidecars/reviewer/sidecar.json') -Raw | ConvertFrom-Json
    $install = Get-Content -LiteralPath (Join-Path $Profile.data 'installation.json') -Raw | ConvertFrom-Json
    if ($sidecar.command -ine $dotnet -or $install.dotnetPath -ine $dotnet -or $install.distribution -cne $Type) {
        throw 'Installed runtime selection is inconsistent'
    }
    $status = & $dotnet (Join-Path $Profile.plugin 'scripts/ag-approval.dll') status --config (Join-Path $Profile.plugin 'approval.json') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $status.status -ne 'running' -or $status.version -ne $manifest.version) {
        throw "Expected running $Type service $($manifest.version)"
    }
    & (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $Profile.plugin
}

function Invoke-TestInstall([hashtable]$Profile, [string]$Type) {
    & (Join-Path $releases[$Type] 'scripts/Install.ps1') -GeminiRoot $Profile.gemini -DataDirectory $Profile.data -AntigravityPath $env:ComSpec | Out-Null
}

function Invoke-TestUpdate(
    [hashtable]$Profile,
    [string]$Type,
    [string]$Script = (Join-Path $PSScriptRoot 'Apply-Update.ps1'),
    [switch]$WindowsPowerShell
) {
    if ($WindowsPowerShell) {
        $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $start = [Diagnostics.ProcessStartInfo]::new($powershell)
        foreach ($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Script,'-PackageZip',$assetPaths[$Type],
            '-ExpectedSha256',$manifest.distributions[$Type].sha256,'-PluginDirectory',$Profile.plugin,'-DataDirectory',$Profile.data,'-SkipProcessCheck')) {
            $start.ArgumentList.Add($arg)
        }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        # Match a desktop launch instead of inheriting the test runner's PowerShell 7 module paths.
        [void]$start.Environment.Remove('PSModulePath')
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(120000)) { $process.Kill($true); throw 'Windows PowerShell update timed out' }
            # The detached service can still hold inherited handles when the updater exits.
            if ($process.ExitCode -ne 0) {
                $details = if ($stderr.Wait(1000)) { $stderr.GetAwaiter().GetResult() }
                throw "Windows PowerShell update failed ($($process.ExitCode)): $details"
            }
        } finally { $process.Dispose() }
        return
    }
    $arguments = @{
        PackageZip = $assetPaths[$Type]; ExpectedSha256 = $manifest.distributions[$Type].sha256
        PluginDirectory = $Profile.plugin; DataDirectory = $Profile.data; SkipProcessCheck = $true
    }
    & $Script @arguments | Out-Null
}

function Stop-TestInstall([hashtable]$Profile) {
    $config = Join-Path $Profile.plugin 'approval.json'
    if (!(Test-Path -LiteralPath $config)) { return }
    [IO.File]::WriteAllText((Join-Path $Profile.data 'uninstalled'), 'test cleanup')
    & (Resolve-ApprovalRuntime $Profile.plugin -Installed) (Join-Path $Profile.plugin 'scripts/ag-approval.dll') stop --config $config | Out-Null
}

function New-BrokenGuardianZip {
    $path = Join-Path $sandbox 'broken-guardian.zip'
    Copy-Item -LiteralPath $assetPaths.lite -Destination $path
    $prefix = "gravity-steward-$($manifest.version)/"
    $bundle = 'artifacts/codex-approval/native/'
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        function Read-ZipJson([string]$Name) {
            $reader = [IO.StreamReader]::new($zip.GetEntry($prefix + $Name).Open())
            try { $reader.ReadToEnd() | ConvertFrom-JsonHashtable } finally { $reader.Dispose() }
        }
        function Write-ZipText([string]$Name, [string]$Value) {
            $zip.GetEntry($prefix + $Name).Delete()
            $entry = $zip.CreateEntry($prefix + $Name)
            $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
            $stream = $entry.Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
        $package = Read-ZipJson 'package-manifest.json'
        $native = Read-ZipJson ($bundle + 'SOURCE.json')
        $native.binarySha256 = Write-ZipText ($bundle + 'ag-guardian-host.exe') 'not a Windows executable'
        $sourceHash = Write-ZipText ($bundle + 'SOURCE.json') ($native | ConvertTo-Json -Depth 12)
        foreach ($file in $package.files) {
            if ($file.path -ceq ($bundle + 'SOURCE.json')) { $file.sha256 = $sourceHash }
            if ($file.path -ceq ($bundle + 'ag-guardian-host.exe')) { $file.sha256 = $native.binarySha256 }
        }
        $null = Write-ZipText 'package-manifest.json' ($package | ConvertTo-Json -Depth 10)
    } finally { $zip.Dispose() }
    return $path
}

$standalone = New-TestProfile 'standalone-fresh'
$lite = New-TestProfile 'lite-fresh'
$missing = New-TestProfile 'missing-dotnet'
$previousCodexHome = $env:CODEX_HOME
$env:CODEX_HOME = Join-Path $sandbox 'codex-home'
New-Item -ItemType Directory -Path $env:CODEX_HOME | Out-Null
Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml') 'cli_auth_credentials_store = "file"'
try {
    $environment = @{ Path = $env:Path; ProgramFiles = $env:ProgramFiles; ProgramW6432 = $env:ProgramW6432 }
    try {
        $absent = Join-Path $sandbox 'absent'
        $env:Path = $env:ProgramFiles = $env:ProgramW6432 = $absent
        Invoke-TestInstall $standalone 'standalone'
        $failure = $null
        try { Invoke-TestInstall $missing 'lite' } catch { $failure = $_.Exception.Message }
        if ($failure -notmatch 'Microsoft.DotNet.Runtime.10' -or (Test-Path -LiteralPath $missing.plugin)) {
            throw 'Lite failed to reject a missing system runtime before installation'
        }
    } finally {
        foreach ($key in $environment.Keys) { [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process') }
    }
    Test-Installed $standalone 'standalone'
    Write-Host 'PASS clean Standalone install and Lite no-runtime detection with system runtime discovery isolated'

    $dualFeed = Join-Path $sandbox 'dual-feed'
    New-Item -ItemType Directory -Path $dualFeed | Out-Null
    Copy-Item -LiteralPath $assetPaths.standalone, $assetPaths.lite -Destination $dualFeed
    $advertised = $manifest.Clone()
    $version = [version]$manifest.version
    $advertised.version = '{0}.{1}.{2}' -f $version.Major, $version.Minor, ($version.Build + 1)
    $advertised | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath (Join-Path $dualFeed 'release-manifest.json')
    $panelOutput = & (Join-Path $standalone.plugin 'app/CodexApprovalPanel.exe') --self-test --local-feed $dualFeed | ForEach-Object { $_ }
    $panelOutput | Write-Host
    if ($LASTEXITCODE -ne 0 -or !($panelOutput -match 'PASS local feed selected and verified separate Lite asset')) {
        throw 'Native panel did not verify both feed assets'
    }

    Invoke-TestInstall $lite 'lite'
    Test-Installed $lite 'lite'
    Invoke-TestUpdate $lite 'lite' -WindowsPowerShell
    Test-Installed $lite 'lite'
    Invoke-TestUpdate $standalone 'standalone'
    Test-Installed $standalone 'standalone'
    Write-Host 'PASS fresh Lite and both same-distribution updates'

    Invoke-TestUpdate $standalone 'lite'
    Test-Installed $standalone 'lite'
    Invoke-TestUpdate $standalone 'standalone'
    Test-Installed $standalone 'standalone'
    Invoke-TestInstall $lite 'standalone'
    Test-Installed $lite 'standalone'
    Invoke-TestInstall $lite 'lite'
    Test-Installed $lite 'lite'
    Invoke-TestInstall $lite 'lite'
    Test-Installed $lite 'lite'
    Write-Host 'PASS both distribution switches through updater and installer, plus Lite repair'

    $checks = @((Join-Path $standalone.plugin 'approval.json'), (Join-Path $standalone.data 'installation.json'),
        (Join-Path $standalone.plugin 'sidecars/reviewer/sidecar.json'))
    $guardData = Join-Path $standalone.data 'denial-guard'
    $logs = Join-Path $standalone.data 'logs'
    New-Item -ItemType Directory -Path $guardData, $logs -Force | Out-Null
    $dataFiles = @((Join-Path $guardData 'rollback-sentinel.json'), (Join-Path $logs 'rollback-sentinel.txt'))
    foreach ($file in $dataFiles) { Set-Utf8NoBom -LiteralPath $file -Content 'rollback fixture' }
    $checks += $dataFiles
    $hashes = @(Get-FileHash -LiteralPath $checks | ForEach-Object Hash)
    $brokenZip = New-BrokenGuardianZip
    $failure = $null
    try {
        & (Join-Path $PSScriptRoot 'Apply-Update.ps1') -PackageZip $brokenZip -ExpectedSha256 (Get-FileHash -LiteralPath $brokenZip).Hash -PluginDirectory $standalone.plugin -DataDirectory $standalone.data -SkipProcessCheck | Out-Null
    } catch { $failure = $_.Exception.Message }
    if ($failure -cne 'Updated Guardian executable could not start' -or (Test-Path -LiteralPath (Join-Path $standalone.data 'uninstalled'))) {
        throw 'Invalid Guardian executable did not fail preflight with the old installation untouched'
    }
    if (Compare-Object $hashes @(Get-FileHash -LiteralPath $checks | ForEach-Object Hash)) { throw 'Native preflight failure changed the existing configuration' }
    Test-Installed $standalone 'standalone'
    Write-Host 'PASS invalid Guardian startup was rejected before stopping the old service'

    $fault = Join-Path $sandbox 'test-health-failure.ps1'
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Apply-Update.ps1'))
    $hook = 'if ($taskStatusJson.status -ne ''running'')'
    if (!$source.Contains($hook)) { throw 'Could not locate update health gate for fault injection' }
    Set-Utf8NoBom -LiteralPath $fault -Content ($source.Replace($hook, 'if ($true)'))
    $failure = $null
    try { Invoke-TestUpdate $standalone 'lite' $fault } catch { $failure = $_.Exception.Message }
    if ($failure -cne 'Updated approval host is not running') { throw "Unexpected health-fault result: $failure" }
    if (Test-Path -LiteralPath (Join-Path $standalone.data 'uninstalled')) { throw 'Rollback left the stop marker behind' }
    if (Compare-Object $hashes @(Get-FileHash -LiteralPath $checks | ForEach-Object Hash)) { throw 'Rollback changed the previous installation metadata or configuration' }
    Test-Installed $standalone 'standalone'
    Write-Host 'PASS failed post-update health check restored prior config, service and hooks and preserved logs and guard state'

    if ($PreviousPackage) {
        $previous = New-TestProfile 'previous-version'
        $source = Join-Path $sandbox 'previous-package'
        [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($PreviousPackage), $source)
        $release = (Get-ChildItem -LiteralPath $source -Directory | Select-Object -First 1).FullName
        try {
            & (Join-Path $release 'scripts/Install.ps1') -GeminiRoot $previous.gemini -DataDirectory $previous.data -AntigravityPath $env:ComSpec | Out-Null
            $previousDotnet = Resolve-ApprovalRuntime $previous.plugin -Installed
            $previousStatus = & $previousDotnet (Join-Path $previous.plugin 'scripts/ag-approval.dll') status --config (Join-Path $previous.plugin 'approval.json') | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $previousStatus.status -cne 'running' -or [version]$previousStatus.version -ge [version]$manifest.version) {
                throw 'Expected an earlier running service for version upgrade'
            }
            Invoke-TestUpdate $previous 'standalone' (Join-Path $releases.standalone 'scripts/Apply-Update.ps1') -WindowsPowerShell
            Test-Installed $previous 'standalone'
            Write-Host "PASS new updater upgraded running $($previousStatus.version) to $($manifest.version)"
        } finally { Stop-TestInstall $previous }
    }
} finally {
    Stop-TestInstall $standalone
    Stop-TestInstall $lite
    $env:CODEX_HOME = $previousCodexHome
}
$global:LASTEXITCODE = 0
