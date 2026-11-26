[CmdletBinding()]
param([switch]$NoRebuild, [switch]$StateOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskLocal = Join-Path $taskRoot '.local'
$taskBuildGuardian = Join-Path $PSScriptRoot 'Build-Guardian.ps1'
$taskUpdateLocal = Join-Path $PSScriptRoot 'Update-Local.ps1'

# Exercise the production state merge and Auto's actual staleness expression
# without building binaries: Service B must not hide an outstanding Panel B.
$stateTokens=$null; $stateErrors=$null
$stateAst=[Management.Automation.Language.Parser]::ParseFile($taskUpdateLocal,[ref]$stateTokens,[ref]$stateErrors)
$stateFunction=$stateAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CompletedBuildHashes'},$false)
if (!$stateFunction) { throw 'Build state merge function not found' }
. ([scriptblock]::Create($stateFunction.Extent.Text))
& {
    $taskHashes=[ordered]@{service='service-B';panel='panel-B';plugin='plugin-B';policy='policy-B'}
    $old=[pscustomobject]@{service='service-A';panel='panel-A';plugin='plugin-A';policy='policy-A'}
    $saved=Get-CompletedBuildHashes $taskHashes $old @('Service')
    if ($saved.service -cne 'service-B' -or $saved.panel -cne 'panel-A' -or $saved.plugin -cne 'plugin-A' -or $saved.policy -cne 'policy-A') { throw 'Selective build marked unbuilt inputs complete' }
    $taskPrevState=[pscustomobject]@{hashes=$saved}
    $autoExpression=$stateAst.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$taskPanelStale'},$true)
    if (!$autoExpression) { throw 'Auto Panel staleness expression not found' }
    . ([scriptblock]::Create($autoExpression.Extent.Text))
    if (!$taskPanelStale) { throw 'Auto skipped Panel B after Service-only build' }
    $saved=Get-CompletedBuildHashes $taskHashes $saved @('Panel','Plugin','Policy')
    $taskPrevState=[pscustomobject]@{hashes=$saved}
    . ([scriptblock]::Create($autoExpression.Extent.Text))
    if ($taskPanelStale -or $saved.service -cne 'service-B') { throw 'Completed build did not settle Auto state' }
    $empty=Get-CompletedBuildHashes $taskHashes $null @('Service')
    if ($empty.panel) { throw 'Fresh selective build invented an unbuilt Panel hash' }
}
Write-Host 'PASS R09 selective Service build retains pending Panel changes; Auto detects them and completed Panel build settles state'
if ($StateOnly) { $global:LASTEXITCODE=0; return }

function Get-GuardianCacheInfo([string]$ProfileName) {
    $raw = & $taskBuildGuardian -Profile $ProfileName -PrintCacheKey
    if ($LASTEXITCODE -ne 0) { throw "Build-Guardian.ps1 -Profile $ProfileName -PrintCacheKey failed" }
    ($raw -join "`n") | ConvertFrom-Json
}

# Check A: Build-Guardian.ps1 cache key normalization, Dev/Release separation, and env isolation.
$taskSavedEnv = @{}
foreach ($name in @('TMP','TEMP','CARGO_TARGET_DIR','CARGO_INCREMENTAL','CARGO_PROFILE_DEV_OPT_LEVEL','CARGO_PROFILE_RELEASE_LTO')) {
    $taskSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $env:TMP = 'C:\Windows\Temp'
    $env:TEMP = 'C:\Windows\Temp'
    $env:CARGO_TARGET_DIR = $null
    $env:CARGO_INCREMENTAL = $null
    $env:CARGO_PROFILE_DEV_OPT_LEVEL = $null
    $env:CARGO_PROFILE_RELEASE_LTO = $null

    $relUnset = Get-GuardianCacheInfo 'Release'
    if ($env:TMP -cne 'C:\Windows\Temp' -or $env:TEMP -cne 'C:\Windows\Temp' -or
        $null -ne $env:CARGO_TARGET_DIR -or $null -ne $env:CARGO_INCREMENTAL) {
        throw 'Build-Guardian.ps1 leaked environment variable changes into the caller process'
    }

    $env:CARGO_TARGET_DIR = Join-Path $taskLocal 'native-release-target'
    $relDefault = Get-GuardianCacheInfo 'Release'

    $env:CARGO_TARGET_DIR = ((Join-Path $taskLocal 'native-release-target') + '/').ToLowerInvariant()
    $relTrailing = Get-GuardianCacheInfo 'Release'

    $env:CARGO_TARGET_DIR = Join-Path $taskLocal 'alternate-target'
    $relAlternate = Get-GuardianCacheInfo 'Release'

    $env:CARGO_TARGET_DIR = $null
    $env:CARGO_PROFILE_DEV_OPT_LEVEL = '3'
    $relWithDevEnv = Get-GuardianCacheInfo 'Release'
    $env:CARGO_PROFILE_DEV_OPT_LEVEL = $null

    foreach ($variant in @($relDefault, $relTrailing, $relAlternate, $relWithDevEnv)) {
        if ($variant.buildKey -cne $relUnset.buildKey) {
            throw 'Release buildKey changed due to CARGO_TARGET_DIR path differences or cross-profile DEV settings'
        }
    }
    if ($relUnset.sourceSha256.PSObject.Properties.Name -contains 'native/guardian-host/src/offline_prompt_tests.rs') {
        throw 'Test-only source offline_prompt_tests.rs leaked into production Guardian buildKey'
    }
    if ($relUnset.testSourceSha256.PSObject.Properties.Name -notcontains 'native/guardian-host/src/offline_prompt_tests.rs') {
        throw 'offline_prompt_tests.rs missing from testSourceSha256'
    }
    if ((Split-Path $relUnset.outputDirectory -Leaf) -cne 'guardian-host-build' -or
        (Split-Path $relUnset.cargoTargetDir -Leaf) -cne 'native-release-target') {
        throw 'Release Guardian output or cargoTargetDir location is unexpected'
    }

    $devInfo = Get-GuardianCacheInfo 'Dev'
    $debugInfo = Get-GuardianCacheInfo 'Debug'
    if ($devInfo.buildKey -cne $debugInfo.buildKey -or $devInfo.profile -cne 'Debug') {
        throw 'Dev alias and Debug profile produced different cache keys'
    }
    if ($devInfo.buildKey -ceq $relUnset.buildKey) {
        throw 'Dev and Release Guardian profiles produced identical cache keys'
    }
    if ((Split-Path $devInfo.outputDirectory -Leaf) -cne 'guardian-host-dev' -or
        (Split-Path $devInfo.cargoTargetDir -Leaf) -cne 'native-build-target') {
        throw 'Dev Guardian output or cargoTargetDir location is not isolated from Release'
    }
    if ($devInfo.cargoIncremental -cne '1' -or
        $devInfo.options.OPT_LEVEL -cne '0' -or
        $devInfo.options.LTO -cne 'off' -or
        $devInfo.options.CODEGEN_UNITS -cne '256' -or
        $devInfo.options.DEBUG -cne '0') {
        throw 'Dev Guardian compiler options do not match fast local iteration profile'
    }

    $env:CARGO_PROFILE_RELEASE_LTO = 'fat'
    $devWithRelEnv = Get-GuardianCacheInfo 'Dev'
    $env:CARGO_PROFILE_RELEASE_LTO = $null
    if ($devWithRelEnv.buildKey -cne $devInfo.buildKey) {
        throw 'CARGO_PROFILE_RELEASE_* polluted Dev Guardian buildKey'
    }
    Write-Host 'PASS Guardian cache key normalization, test-source isolation, and Dev/Release separation'
} finally {
    foreach ($entry in $taskSavedEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}

# Check B: Unified Update-Local.ps1 selective builds, Guardian reuse, isolated install, and zero ZIPs.
$taskSandbox = Join-Path $taskLocal ('local-build-test/' + [Guid]::NewGuid().ToString('N'))
$taskGemini = Join-Path $taskSandbox '.gemini'
$taskConfig = Join-Path $taskGemini 'config'
$taskData = Join-Path $taskSandbox 'data'
New-Item -ItemType Directory -Path $taskConfig, $taskData -Force | Out-Null
@{
    userSettings = @{
        permissionPreset = 'AGENT_PERMISSION_PRESET_DEFAULT'
        enableTerminalSandbox = $true
        autoExecutionPolicy = 'CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX'
    }
    sidecars = @{}
} | ConvertTo-Json -Depth 10 | Set-Utf8NoBom -LiteralPath (Join-Path $taskConfig 'config.json') -Encoding utf8

$taskPlugin = Join-Path $taskConfig 'plugins/gravity-guardian'
$taskArtifacts = Join-Path $taskRoot 'artifacts'
$taskExistingZips = @{}
if (Test-Path -LiteralPath $taskArtifacts) {
    foreach ($z in (Get-ChildItem -LiteralPath $taskArtifacts -Filter '*.zip' -File)) {
        $taskExistingZips[$z.FullName] = $z.LastWriteTimeUtc.ToString('O')
    }
}

try {
    if ($NoRebuild) {
        # Verify incremental Auto local install without rebuilding any application binaries.
        $resAuto1Raw = & $taskUpdateLocal -Components Auto -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec -SkipGuardianAuthCheck
        $resAuto1 = ($resAuto1Raw -join "`n") | ConvertFrom-Json
        if (!$resAuto1.ok -or $resAuto1.built.Count -ne 0 -or $resAuto1.zipCount -ne 0 -or !$resAuto1.installed -or !$resAuto1.doctorChecked) {
            throw ("NoRebuild Auto update expected 0 builds and clean install, got built=" + ($resAuto1.built -join ','))
        }
        & (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin

        $taskApprovalPath = Join-Path $taskPlugin 'approval.json'
        $taskCustomApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
        $taskCustomApproval.enableDetailedLogs = $true
        $taskCustomApproval | ConvertTo-Json -Depth 16 | Set-Utf8NoBom -LiteralPath $taskApprovalPath -Encoding utf8

        $resAuto2Raw = & $taskUpdateLocal -Components Auto -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec -SkipGuardianAuthCheck
        $resAuto2 = ($resAuto2Raw -join "`n") | ConvertFrom-Json
        if (!$resAuto2.ok -or $resAuto2.built.Count -ne 0) {
            throw ("Second NoRebuild Auto update rebuilt components unexpectedly: " + ($resAuto2.built -join ', '))
        }
        $taskPostApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
        if (!$taskPostApproval.enableDetailedLogs) {
            throw 'NoRebuild Auto local update did not preserve enableDetailedLogs preference'
        }
    } else {
        # 1. C# service-only update
        $resServiceRaw = & $taskUpdateLocal -Components Service -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec -SkipGuardianAuthCheck
        $resService = ($resServiceRaw -join "`n") | ConvertFrom-Json
        if (!$resService.ok -or $resService.zipCount -ne 0 -or !$resService.installed -or !$resService.doctorChecked) {
            throw 'Service-only local update did not complete install and doctor verification'
        }
        if ($resService.built -notcontains 'Service' -or ($resService.built | Where-Object { $_ -like 'Guardian*' })) {
            throw 'Service-only update rebuilt Guardian or skipped Service'
        }
        & (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskPlugin

        $taskApprovalPath = Join-Path $taskPlugin 'approval.json'
        $taskCustomApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
        $taskCustomApproval.enableDetailedLogs = $true
        $taskCustomApproval | ConvertTo-Json -Depth 16 | Set-Utf8NoBom -LiteralPath $taskApprovalPath -Encoding utf8

        # 2. Panel-only update (must preserve user preferences and reuse Service & Guardian)
        $resPanelRaw = & $taskUpdateLocal -Components Panel -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec -SkipGuardianAuthCheck
        $resPanel = ($resPanelRaw -join "`n") | ConvertFrom-Json
        if (!$resPanel.ok -or $resPanel.built -notcontains 'Panel' -or ($resPanel.reused -notcontains 'Service') -or ($resPanel.built | Where-Object { $_ -like 'Guardian*' })) {
            throw 'Panel-only update did not isolate Panel build and reuse Service & Guardian'
        }
        $taskPostPanelApproval = Get-Content -Encoding UTF8 -LiteralPath $taskApprovalPath -Raw | ConvertFrom-JsonHashtable
        if (!$taskPostPanelApproval.enableDetailedLogs) {
            throw 'Panel-only local update did not preserve enableDetailedLogs preference'
        }

        # 3. Auto with no changes (0 rebuilds)
        $resAutoRaw = & $taskUpdateLocal -Components Auto -GeminiRoot $taskGemini -DataDirectory $taskData -AntigravityPath $env:ComSpec -SkipGuardianAuthCheck
        $resAuto = ($resAutoRaw -join "`n") | ConvertFrom-Json
        if (!$resAuto.ok -or $resAuto.built.Count -ne 0) {
            throw ("Auto update rebuilt components unexpectedly: " + ($resAuto.built -join ', '))
        }
    }

    # Verify zero release ZIPs created or touched
    $taskAfterZips = @{}
    if (Test-Path -LiteralPath $taskArtifacts) {
        foreach ($z in (Get-ChildItem -LiteralPath $taskArtifacts -Filter '*.zip' -File)) {
            $taskAfterZips[$z.FullName] = $z.LastWriteTimeUtc.ToString('O')
        }
    }
    if ($taskAfterZips.Count -ne $taskExistingZips.Count) {
        throw 'Local update created unexpected ZIP package(s)'
    }
    foreach ($k in $taskAfterZips.Keys) {
        if ($taskExistingZips[$k] -cne $taskAfterZips[$k]) {
            throw "Local update modified ZIP package: $k"
        }
    }
    Write-Host 'PASS Update-Local.ps1 selective C#/Panel/Auto updates, Guardian reuse, isolated install, and zero ZIPs'
} finally {
    try {
        if (Test-Path -LiteralPath $taskPlugin) {
            $rt = Resolve-ApprovalRuntime $taskPlugin -Installed
            [IO.File]::WriteAllText((Join-Path $taskData 'uninstalled'), 'test cleanup')
            & $rt (Join-Path $taskPlugin 'scripts/gravity-guardian.dll') stop --config (Join-Path $taskPlugin 'approval.json') 2>$null | Out-Null
        }
    } catch {}
    if (Test-Path -LiteralPath $taskSandbox) {
        Remove-Item -LiteralPath $taskSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}
