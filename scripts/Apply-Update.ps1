[CmdletBinding()]
param(
    [int]$WaitPid = 0,
    [Parameter(Mandatory)][string]$PackageZip,
    [Parameter(Mandatory)][string]$ExpectedSha256,
    [Parameter(Mandatory)][string]$PluginDirectory,
    [Parameter(Mandatory)][string]$DataDirectory,
    [switch]$RelaunchPanel,
    [switch]$SkipProcessCheck
)
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-HashtableCompat($InputObject) {
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $t = @{}
        foreach ($k in $InputObject.Keys) { $t[$k] = ConvertTo-HashtableCompat $InputObject[$k] }
        return $t
    }
    if ($InputObject -is [PSCustomObject]) {
        $t = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $t[$p.Name] = ConvertTo-HashtableCompat $p.Value }
        return $t
    }
    if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($el in $InputObject) { $list.Add((ConvertTo-HashtableCompat $el)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function Get-RelPath([string]$BaseDir, [string]$TargetPath) {
    $prefix = [IO.Path]::GetFullPath($BaseDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($TargetPath)
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Path escaped base directory: ' + $TargetPath)
    }
    return $full.Substring($prefix.Length)
}

$taskPlugin = [IO.Path]::GetFullPath($PluginDirectory)
$taskData = [IO.Path]::GetFullPath($DataDirectory)
$taskZip = [IO.Path]::GetFullPath($PackageZip)
$taskUpdatesDir = Join-Path $taskData 'updates'
New-Item -ItemType Directory -Path $taskUpdatesDir -Force | Out-Null
$taskErrorLog = Join-Path $taskUpdatesDir 'last-update-error.log'

# 1. Wait for caller panel process to exit so executables are unlocked.
if ($WaitPid -gt 0) {
    $taskWaitProc = $null
    try { $taskWaitProc = [Diagnostics.Process]::GetProcessById($WaitPid) } catch [ArgumentException] {}
    if ($taskWaitProc) {
        try {
            if (!$taskWaitProc.WaitForExit(15000)) {
                throw 'Timed out waiting for CodexApprovalPanel to exit before updating.'
            }
        } finally { $taskWaitProc.Dispose() }
    }
}

# 2. Verify package ZIP exists and matches expected SHA-256.
if (!(Test-Path -LiteralPath $taskZip -PathType Leaf)) { throw ('Update package not found: ' + $taskZip) }
$taskActualZipHash = (Get-FileHash -LiteralPath $taskZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($taskActualZipHash -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
    throw ('Update package SHA-256 mismatch. Expected ' + $ExpectedSha256 + ', got ' + $taskActualZipHash)
}

# 3. Never interrupt a running Antigravity session.
if (!$SkipProcessCheck) {
    $taskAgProcs = @(Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue)
    if ($taskAgProcs.Count -gt 0) {
        throw 'Antigravity is currently running; update deferred until Antigravity exits.'
    }
}

# 4. Extract ZIP and verify all files against package-manifest.json.
$taskExtractDir = Join-Path $taskUpdatesDir ('extract-' + [Guid]::NewGuid().ToString('N'))
$taskStageDir = Join-Path $taskUpdatesDir ('stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskExtractDir -Force | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($taskZip, $taskExtractDir)

    $taskManifestItem = Get-ChildItem -LiteralPath $taskExtractDir -Filter 'package-manifest.json' -Recurse -File | Select-Object -First 1
    if (!$taskManifestItem) { throw 'package-manifest.json missing in update archive' }
    $taskReleaseRoot = $taskManifestItem.Directory.FullName
    $taskManifest = Get-Content -Encoding UTF8 -LiteralPath $taskManifestItem.FullName -Raw | ConvertFrom-Json
    foreach ($entry in $taskManifest.files) {
        $entryFull = [IO.Path]::GetFullPath((Join-Path $taskReleaseRoot $entry.path))
        $null = Get-RelPath $taskReleaseRoot $entryFull
        if (!(Test-Path -LiteralPath $entryFull -PathType Leaf)) {
            throw ('Missing file in extracted update archive: ' + $entry.path)
        }
        $actual = (Get-FileHash -LiteralPath $entryFull -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$entry.sha256).ToLowerInvariant()) {
            throw ('Extracted file SHA-256 mismatch: ' + $entry.path)
        }
    }

    $taskNewBundle = Join-Path $taskReleaseRoot 'artifacts/codex-approval'
    foreach ($req in @('plugin.json', 'scripts/ag-approval.dll', 'runtime/dotnet.exe', 'app/CodexApprovalPanel.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $taskNewBundle $req) -PathType Leaf)) {
            throw ('Incomplete update bundle, missing: ' + $req)
        }
    }

    if (!(Test-Path -LiteralPath $taskPlugin -PathType Container)) {
        throw ('Existing plugin installation not found at: ' + $taskPlugin)
    }

    # Read existing state to preserve user configuration and detect customized pricing.
    $taskOldApprovalPath = Join-Path $taskPlugin 'approval.json'
    if (!(Test-Path -LiteralPath $taskOldApprovalPath -PathType Leaf)) {
        throw ('Existing approval.json not found at: ' + $taskOldApprovalPath)
    }
    $taskOldApproval = ConvertTo-HashtableCompat (Get-Content -Encoding UTF8 -LiteralPath $taskOldApprovalPath -Raw | ConvertFrom-Json)

    $taskOldSidecarPath = Join-Path $taskPlugin 'sidecars/reviewer/sidecar.json'
    $taskOldSidecarText = if (Test-Path -LiteralPath $taskOldSidecarPath -PathType Leaf) {
        [IO.File]::ReadAllText($taskOldSidecarPath, [Text.Encoding]::UTF8)
    } else {
        @{ command = (Join-Path $taskPlugin 'runtime/dotnet.exe'); args = @((Join-Path $taskPlugin 'scripts/ag-approval.dll'), 'supervise', '--config', (Join-Path $taskPlugin 'approval.json')); restart_policy = 'on-failure'; display_name = 'Codex Approval'; description = 'Native codex-auto-review permission reviewer' } | ConvertTo-Json -Depth 8
    }

    $taskInstPath = Join-Path $taskData 'installation.json'
    $taskInst = if (Test-Path -LiteralPath $taskInstPath -PathType Leaf) {
        ConvertTo-HashtableCompat (Get-Content -Encoding UTF8 -LiteralPath $taskInstPath -Raw | ConvertFrom-Json)
    } else { $null }

    $taskPreservePricing = $false
    $taskOldPricingPath = Join-Path $taskPlugin 'pricing.json'
    $taskOldPricingText = ''
    if (Test-Path -LiteralPath $taskOldPricingPath -PathType Leaf) {
        $taskOldPricingText = [IO.File]::ReadAllText($taskOldPricingPath, [Text.Encoding]::UTF8)
        $taskOldPricingHash = (Get-FileHash -LiteralPath $taskOldPricingPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($taskInst -and $taskInst.ContainsKey('defaultPricingSha256') -and $taskInst.defaultPricingSha256) {
            if ($taskOldPricingHash -ne ([string]$taskInst.defaultPricingSha256).ToLowerInvariant()) {
                $taskPreservePricing = $true
            }
        } else {
            try {
                $pObj = $taskOldPricingText | ConvertFrom-Json
                if ($pObj.profileName -ne 'gpt-6-luna-low-2x-estimate' -or [decimal]$pObj.multiplier -ne 2.0 -or
                    [decimal]$pObj.inputPerMillionUsd -ne 0.10 -or [decimal]$pObj.cachedInputPerMillionUsd -ne 0.01 -or [decimal]$pObj.outputPerMillionUsd -ne 0.50) {
                    $taskPreservePricing = $true
                }
            } catch {}
        }
    }

    # Prepare clean staging directory with preserved config.
    Copy-Item -LiteralPath $taskNewBundle -Destination $taskStageDir -Recurse
    $taskNewPricingPath = Join-Path $taskStageDir 'pricing.json'
    $taskNewDefaultPricingSha = if (Test-Path -LiteralPath $taskNewPricingPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $taskNewPricingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { '' }
    if ($taskPreservePricing -and $taskOldPricingText) {
        Write-Utf8NoBom $taskNewPricingPath $taskOldPricingText
    }

    # Ensure approval.json retains user settings and points to installed plugin paths.
    $taskOldApproval['policyDirectory'] = Join-Path $taskPlugin 'policy/effective-codex'
    $taskOldApproval['guardianPath'] = Join-Path $taskPlugin 'native/ag-guardian-host.exe'
    Write-Utf8NoBom (Join-Path $taskStageDir 'approval.json') ($taskOldApproval | ConvertTo-Json -Depth 16)

    $taskStageSidecarDir = Join-Path $taskStageDir 'sidecars/reviewer'
    New-Item -ItemType Directory -Path $taskStageSidecarDir -Force | Out-Null
    Write-Utf8NoBom (Join-Path $taskStageSidecarDir 'sidecar.json') $taskOldSidecarText

    # Stop old host & sidecar cleanly.
    $taskOldRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
    $taskOldAssembly = Join-Path $taskPlugin 'scripts/ag-approval.dll'
    $taskStopMarker = Join-Path $taskData 'uninstalled'
    Write-Utf8NoBom $taskStopMarker 'upgrade in progress'
    Start-Sleep -Milliseconds 2200

    $taskOldHostId = $null
    $taskPrevErr = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $taskOldStatus = & $taskOldRuntime $taskOldAssembly status --config $taskOldApprovalPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $taskOldStatus) {
            $taskOldHostId = (($taskOldStatus -join [Environment]::NewLine) | ConvertFrom-Json).pid
        }
        & $taskOldRuntime $taskOldAssembly stop --config $taskOldApprovalPath 2>$null | Out-Null
    } catch {} finally { $ErrorActionPreference = $taskPrevErr }

    if ($taskOldHostId) {
        $taskOldProc = $null
        try { $taskOldProc = [Diagnostics.Process]::GetProcessById([int]$taskOldHostId) } catch [ArgumentException] {}
        if ($taskOldProc) {
            try {
                if (!$taskOldProc.WaitForExit(10000)) { throw 'Old approval host did not exit in time' }
            } finally { $taskOldProc.Dispose() }
        }
    }

    Get-Process -Name 'CodexApprovalPanel' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($taskPlugin + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        try { $_.Kill(); $_.WaitForExit(5000) } catch {}
    }

    # Backup old plugin before replacing.
    $taskBackupRoot = Join-Path $taskData ('backups/upgrade-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $taskBackupRoot -Force | Out-Null
    $taskBackupPlugin = Join-Path $taskBackupRoot 'replaced-plugin'
    Move-Item -LiteralPath $taskPlugin -Destination $taskBackupPlugin

    try {
        Copy-Item -LiteralPath $taskStageDir -Destination $taskPlugin -Recurse
        $taskStageFiles = @(Get-ChildItem -LiteralPath $taskStageDir -Recurse -File -Force)
        foreach ($f in $taskStageFiles) {
            $rel = Get-RelPath $taskStageDir $f.FullName
            $dst = [IO.Path]::GetFullPath((Join-Path $taskPlugin $rel))
            if (!(Test-Path -LiteralPath $dst -PathType Leaf) -or
                (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) {
                throw ('Updated file verification failed: ' + $rel)
            }
        }
        if (@(Get-ChildItem -LiteralPath $taskPlugin -Recurse -File -Force).Count -ne $taskStageFiles.Count) {
            throw 'Updated plugin directory contains unexpected files'
        }

        if (Test-Path -LiteralPath $taskStopMarker) { Remove-Item -LiteralPath $taskStopMarker -Force }

        # Start new host and verify status.
        $taskNewRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
        $taskNewAssembly = Join-Path $taskPlugin 'scripts/ag-approval.dll'
        $taskNewConfig = Join-Path $taskPlugin 'approval.json'
        $taskServiceLogs = Join-Path $taskData 'service'
        New-Item -ItemType Directory -Path $taskServiceLogs -Force | Out-Null
        $taskStartupId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
        $taskStartupArgs = @(('"' + $taskNewAssembly + '"'), 'ensure', '--config', ('"' + $taskNewConfig + '"'))
        $taskStartup = Start-Process -FilePath $taskNewRuntime -ArgumentList $taskStartupArgs -WorkingDirectory $taskPlugin -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskServiceLogs ($taskStartupId + '.stdout.log')) -RedirectStandardError (Join-Path $taskServiceLogs ($taskStartupId + '.stderr.log')) -PassThru
        try {
            if (!$taskStartup.WaitForExit(20000)) { throw 'Updated approval host startup timed out' }
            if ($null -ne $taskStartup.ExitCode -and $taskStartup.ExitCode -ne 0) { throw 'Updated approval host could not start' }
        } finally { $taskStartup.Dispose() }

        $taskPrevErr = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $taskStatusRaw = & $taskNewRuntime $taskNewAssembly status --config $taskNewConfig 2>$null
        } finally { $ErrorActionPreference = $taskPrevErr }
        if ($LASTEXITCODE -ne 0 -or !$taskStatusRaw) { throw 'Updated approval host failed health check' }
        $taskStatusJson = ($taskStatusRaw -join [Environment]::NewLine) | ConvertFrom-Json
        if ($taskStatusJson.status -ne 'running') { throw 'Updated approval host is not running' }

        if ($taskInst) {
            $taskInst['latestUpgradeBackup'] = $taskBackupRoot
            $taskInst['updatedAt'] = [DateTime]::UtcNow.ToString('O')
            $taskInst['version'] = [string]$taskManifest.version
            if ($taskNewDefaultPricingSha) { $taskInst['defaultPricingSha256'] = $taskNewDefaultPricingSha }
            Write-Utf8NoBom $taskInstPath ($taskInst | ConvertTo-Json -Depth 20)
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-Utf8NoBom $taskErrorLog ("[" + [DateTime]::UtcNow.ToString('O') + "] Update failed, rolling back: " + $errMsg)
        try {
            if (Test-Path -LiteralPath $taskPlugin) {
                $failedDir = Join-Path $taskBackupRoot 'failed-new-plugin'
                Move-Item -LiteralPath $taskPlugin -Destination $failedDir -Force
            }
            if (Test-Path -LiteralPath $taskBackupPlugin) {
                Move-Item -LiteralPath $taskBackupPlugin -Destination $taskPlugin -Force
            }
            if (Test-Path -LiteralPath $taskStopMarker) { Remove-Item -LiteralPath $taskStopMarker -Force }
            $taskServiceLogs = Join-Path $taskData 'service'
            New-Item -ItemType Directory -Path $taskServiceLogs -Force | Out-Null
            $rbArgs = @(('"' + $taskOldAssembly + '"'), 'ensure', '--config', ('"' + $taskOldApprovalPath + '"'))
            $rbProc = Start-Process -FilePath $taskOldRuntime -ArgumentList $rbArgs -WorkingDirectory $taskPlugin -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskServiceLogs 'rollback.stdout.log') -RedirectStandardError (Join-Path $taskServiceLogs 'rollback.stderr.log') -PassThru
            try { [void]$rbProc.WaitForExit(15000) } finally { $rbProc.Dispose() }
        } catch {}
        throw
    }

    if (Test-Path -LiteralPath $taskErrorLog) { Remove-Item -LiteralPath $taskErrorLog -Force -ErrorAction SilentlyContinue }

    if ($RelaunchPanel) {
        $panelExe = Join-Path $taskPlugin 'app/CodexApprovalPanel.exe'
        if (Test-Path -LiteralPath $panelExe -PathType Leaf) {
            Start-Process -FilePath $panelExe -WorkingDirectory (Split-Path $panelExe -Parent) | Out-Null
        }
    }

    @{ ok = $true; version = [string]$taskManifest.version; pluginDirectory = $taskPlugin } | ConvertTo-Json -Compress
} finally {
    Remove-Item -LiteralPath $taskExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $taskStageDir -Recurse -Force -ErrorAction SilentlyContinue
}
