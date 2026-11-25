[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskSandbox = Join-Path $taskRoot ('.local/update-test/' + [Guid]::NewGuid().ToString('N'))
$taskGemini = Join-Path $taskSandbox '.gemini'
$taskConfig = Join-Path $taskGemini 'config'
$taskData = Join-Path $taskSandbox 'data'
$taskFeed = Join-Path $taskSandbox 'feed'
$taskCodexHome = Join-Path $taskSandbox 'codex-home'
New-Item -ItemType Directory -Path $taskConfig, $taskData, $taskFeed, $taskCodexHome -Force | Out-Null
Set-Content -LiteralPath (Join-Path $taskCodexHome 'config.toml') 'cli_auth_credentials_store = "file"'

# Minimal native Antigravity config fixture
@{ userSettings = @{ permissionPreset = 'AGENT_PERMISSION_PRESET_DEFAULT'; enableTerminalSandbox = $true; autoExecutionPolicy = 'CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX' }; sidecars = @{} } |
    ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath (Join-Path $taskConfig 'config.json') -Encoding utf8

# 1. Install the current package into an isolated directory.
& (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec
$taskPlugin = Join-Path $taskConfig 'plugins/gravity-guardian'
$taskRuntime = Join-Path $taskPlugin 'runtime/dotnet.exe'
$taskAssembly = Join-Path $taskPlugin 'scripts/gravity-guardian.dll'
$taskApprovalPath = Join-Path $taskPlugin 'approval.json'
$taskBaseVersion = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw | ConvertFrom-Json).version
$taskBaseParts = [version]$taskBaseVersion
$taskNextVersion = '{0}.{1}.{2}' -f $taskBaseParts.Major, $taskBaseParts.Minor, ($taskBaseParts.Build + 1)

# Customize enableDetailedLogs=true, write a log file and denial-guard sentinel to verify preservation across upgrade
& $taskRuntime $taskAssembly set-logging --config $taskApprovalPath --enabled true | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable detailed logs before update test' }
$taskLegacyApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
$taskLegacyApproval.codexHome = $taskCodexHome
$taskLegacyApproval.reviewerBackend = 'Cli'
$taskLegacyApproval.codexPath = $(if ($env:AG_TEST_CLI_TRIPWIRE) { $env:AG_TEST_CLI_TRIPWIRE } else { Join-Path $taskSandbox 'missing-codex.exe' })
$taskLegacyApproval.enableReviewerSessions = $true
$taskLegacyApproval.enableNativeState = $false
$taskLegacyApproval | ConvertTo-Json -Depth 16 | Set-Utf8NoBom -LiteralPath $taskApprovalPath
$taskPaused = & $taskRuntime $taskAssembly takeover --config $taskApprovalPath --enabled false | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $taskPaused.takeoverEnabled -ne $false) { throw 'Could not pause approval takeover before update' }

$taskLogsDir = Join-Path $taskData 'logs'
New-Item -ItemType Directory -Path $taskLogsDir -Force | Out-Null
$taskSentinelLog = Join-Path $taskLogsDir '2026-11-21.000.jsonl'
[IO.File]::WriteAllText($taskSentinelLog, '{"at":"2026-11-21T02:00:00Z","event":"review_completed","requestId":"upd-sentinel","status":"approved"}' + "`n")
$taskGuardDir = Join-Path $taskData 'denial-guard'
New-Item -ItemType Directory -Path $taskGuardDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $taskGuardDir 'sentinel.json'), '{"keep":true}')

# 2. Use the verified build and simulate an advertised newer version in the local feed.
$taskBaseZip = Get-Item -LiteralPath (Join-Path $taskRoot "artifacts/gravity-guardian-$taskBaseVersion-windows-x64.zip")
if (!$taskBaseZip) { throw 'Packaged release zip not found' }
$taskNextName = "gravity-guardian-$taskNextVersion-windows-x64.zip"
$taskNextZip = Join-Path $taskFeed $taskNextName
Copy-Item -LiteralPath $taskBaseZip.FullName -Destination $taskNextZip

$taskNextSha = (Get-FileHash -LiteralPath $taskNextZip -Algorithm SHA256).Hash.ToLowerInvariant()
@{
    version = $taskNextVersion
    publishedAt = [DateTime]::UtcNow.ToString('O')
    assetName = $taskNextName
    downloadUrl = ''
    sha256 = $taskNextSha
    sizeBytes = (Get-Item -LiteralPath $taskNextZip).Length
} | ConvertTo-Json -Depth 6 | Set-Utf8NoBom -LiteralPath (Join-Path $taskFeed 'release-manifest.json') -Encoding utf8

try {
    # Test A: Panel self-test against local feed (verifies SemVer detection + BCrypt SHA-256)
    $taskPanelExe = Join-Path $taskPlugin 'app/GravityGuardian.exe'
    $taskPanelOut = & $taskPanelExe --self-test --local-feed $taskFeed | ForEach-Object { $_ }
    $taskPanelOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or !($taskPanelOut -join "`n").Contains('PASS local update feed check')) {
        throw 'Panel local update feed self-test failed'
    }

    # Test B: Reject corrupt SHA-256 without changing the installed version.
    $taskRejected = $false
    try {
        & (Join-Path $PSScriptRoot 'Apply-Update.ps1') -PackageZip $taskNextZip -ExpectedSha256 ('0' * 64) -PluginDirectory $taskPlugin -DataDirectory $taskData -SkipProcessCheck | Out-Null
    } catch {
        $taskRejected = $true
    }
    if (!$taskRejected) { throw 'Apply-Update accepted a mismatched SHA-256 hash' }
    if ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw | ConvertFrom-Json).version -ne $taskBaseVersion) {
        throw "Corrupt update modified existing $taskBaseVersion installation"
    }
    Write-Host 'PASS update transaction rejected mismatched SHA-256 without modifying installed plugin'

    # Test C: A valid update preserves config, logs, and denial protection.
    $taskApplyRes = & (Join-Path $PSScriptRoot 'Apply-Update.ps1') -PackageZip $taskNextZip -ExpectedSha256 $taskNextSha -PluginDirectory $taskPlugin -DataDirectory $taskData -SkipProcessCheck
    $taskApplyRes | ForEach-Object { Write-Host $_ }

    $taskNewVer = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'plugin.json') -Raw | ConvertFrom-Json).version
    if ($taskNewVer -ne $taskBaseVersion) { throw "Expected the packaged plugin version $taskBaseVersion, got $taskNewVer" }

    $taskPostApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
    if (!$taskPostApproval.enableDetailedLogs) { throw 'Upgrade lost enableDetailedLogs=true user preference' }
    if ($taskPostApproval.reviewerBackend -ne 'NativeGuardian' -or !$taskPostApproval.enableNativeState -or
        $taskPostApproval.ContainsKey('codexPath') -or $taskPostApproval.ContainsKey('enableReviewerSessions')) { throw 'Self-update did not migrate old reviewer settings' }
    if (!(Test-Path -LiteralPath $taskSentinelLog) -or ![IO.File]::ReadAllText((Join-Path $taskGuardDir 'sentinel.json')).Contains('keep')) {
        throw 'Upgrade lost user logs or denial-guard state'
    }

    $taskStatusRaw = & $taskRuntime $taskAssembly status --config $taskApprovalPath
    if ($LASTEXITCODE -ne 0) { throw 'Upgraded host status command failed' }
    $taskStatus = ($taskStatusRaw -join [Environment]::NewLine) | ConvertFrom-Json
    if ($taskStatus.status -ne 'running' -or !$taskStatus.detailedLogs) {
        throw 'Upgraded host not running with preserved detailedLogs setting'
    }
    $taskAfterUpdate = & $taskRuntime $taskAssembly takeover --config $taskApprovalPath | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $taskAfterUpdate.takeoverEnabled -ne $false) { throw 'Update resumed paused approval takeover' }
    Write-Host "PASS package replacement preserved paused takeover, user config, logs, and running host"
} finally {
    # Cleanly stop isolated test host
    try {
        [IO.File]::WriteAllText((Join-Path $taskData 'uninstalled'), 'test cleanup')
        & $taskRuntime $taskAssembly stop --config $taskApprovalPath 2>$null | Out-Null
    } catch {}
}
$global:LASTEXITCODE = 0
