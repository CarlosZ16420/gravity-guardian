[CmdletBinding()]
param([string]$PackageZip = '')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskFixture=Join-Path $taskRoot ('.local/p-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$taskPortableRoot=Join-Path $taskFixture '中文 空格'
$taskGemini=Join-Path $taskFixture 'gemini'
$taskLegacyData=Join-Path $taskFixture 'old-data'
$taskHostConfig=Join-Path $taskGemini 'config'
$taskRegistration=Join-Path $taskHostConfig 'plugins/gravity-guardian'
$taskAuth=Join-Path $taskFixture 'auth'
$taskSavedHome=$env:CODEX_HOME
$taskWindowsPowerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
New-Item -ItemType Directory -Path $taskHostConfig,$taskAuth -Force | Out-Null
'cli_auth_credentials_store = "file"' | Set-Utf8NoBom -LiteralPath (Join-Path $taskAuth 'config.toml')
$env:CODEX_HOME=$taskAuth
$taskOriginal=@{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO';globalPermissionGrants=@{allow=@('command(git status)');deny=@('write_file(private)')}};sidecars=@{other=@{enabled=$true}}}
Write-PortableJson (Join-Path $taskHostConfig 'config.json') $taskOriginal

try {
    if ($PackageZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $unpack=Join-Path $taskFixture 'zip'
        [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($PackageZip),$unpack)
        $release=@(Get-ChildItem -LiteralPath $unpack -Directory)[0].FullName
        Copy-PortableVerified $release $taskPortableRoot
    } else {
        $bundle=Join-Path $taskRoot 'artifacts/gravity-guardian'
        Copy-PortableVerified $bundle (Join-Path $taskPortableRoot 'app')
        Copy-Item -LiteralPath (Join-Path $bundle 'app/GravityGuardian.exe') -Destination (Join-Path $taskPortableRoot 'GravityGuardian.exe')
        $extraPanel=Join-Path $taskPortableRoot 'app/app'
        Assert-PortablePath $extraPanel
        Remove-Item -LiteralPath $extraPanel -Recurse -Force
        Write-PortableJson (Join-Path $taskPortableRoot 'portable.json') @{storageMode='portable';layoutVersion=1;distribution='standalone'}
        Copy-Item -LiteralPath (Join-Path $taskRoot 'docs/portable.md') -Destination (Join-Path $taskPortableRoot 'README.md')
    }
    $taskLayout=Get-PortableLayout $taskPortableRoot
    $install=Join-Path $taskLayout.app 'scripts/Install.ps1'
    & $taskWindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $install -GeminiRoot $taskGemini -AntigravityPath $env:ComSpec -PlanOnly | Out-Host
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $taskLayout.data) -or (Test-Path -LiteralPath (Split-Path $taskLayout.config))) { throw 'Portable plan wrote user files or failed' }
    $stats=& (Join-Path $taskLayout.app 'runtime/dotnet.exe') (Join-Path $taskLayout.app 'scripts/gravity-guardian.dll') stats | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $stats.today.totalRequests -ne 0) { throw 'Unconnected portable statistics failed' }
    Write-Host 'PASS local portable preview and offline statistics'

    # Use the installed workflow as migration input, with no real login or model invocation.
    & (Join-Path $PSScriptRoot 'Install.ps1') -GeminiRoot $taskGemini -DataDirectory $taskLegacyData -AntigravityPath $env:ComSpec -NoStart | Out-Null
    $sourceLog=Join-Path $taskLegacyData 'logs/2026-11-01.000.jsonl'
    New-Item -ItemType Directory -Path (Split-Path $sourceLog) -Force | Out-Null
    '{"at":"2026-11-01T00:00:00Z","event":"session_start","conversationId":"portable-migration"}' | Set-Utf8NoBom -LiteralPath $sourceLog
    $logHash=(Get-FileHash -LiteralPath $sourceLog).Hash
    $customPrice=Read-PortableJson (Join-Path $taskRegistration 'pricing.json')
    $customPrice.multiplier=1.25
    Write-PortableJson (Join-Path $taskRegistration 'pricing.json') $customPrice
    & $taskWindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $install -GeminiRoot $taskGemini -AntigravityPath $env:ComSpec | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Portable connection or migration failed' }
    if ((Get-FileHash -LiteralPath (Join-Path $taskLayout.data 'logs/2026-11-01.000.jsonl')).Hash -cne $logHash) { throw 'Migrated approval log changed' }
    if (Test-Path -LiteralPath (Join-Path $taskRegistration 'runtime')) { throw 'Portable registration copied program files' }
    if (Test-Path -LiteralPath (Join-Path $taskRegistration 'approval.json')) { throw 'Portable registration copied user settings' }
    $settings=Read-PortableJson $taskLayout.config
    if ($settings.schemaVersion -ne 2 -or $settings.ContainsKey('dataDirectory') -or $settings.ContainsKey('policyDirectory')) { throw 'Portable configuration stores internal paths' }
    if ((Read-PortableJson (Join-Path (Split-Path $taskLayout.config) 'pricing.json')).multiplier -ne 1.25) { throw 'Custom price was not migrated' }
    $status=Invoke-PortableCore $taskLayout 'status' | ConvertFrom-Json
    if ($status.storageMode -cne 'portable' -or $status.portableRoot -ine $taskPortableRoot) { throw 'Portable service identity mismatch' }
    & (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskRegistration
    Write-Host 'PASS local portable connection, legacy migration and shipped hooks'

    # Prove the system-only hook wrapper returns deny when the child cannot even start.
    Stop-PortableService $taskLayout
    $runtime=Join-Path $taskLayout.app 'runtime/dotnet.exe'
    $disabled=$runtime+'.disabled'
    Move-Item -LiteralPath $runtime -Destination $disabled
    try { & (Join-Path $PSScriptRoot 'Test-Hooks.ps1') -PluginDirectory $taskRegistration }
    finally { Move-Item -LiteralPath $disabled -Destination $runtime }
    Remove-Item -LiteralPath (Join-Path $taskLayout.data 'uninstalled') -Force
    Invoke-PortableCore $taskLayout 'ensure' | Out-Null
    Write-Host 'PASS missing runtime cannot turn into automatic approval'

    if ($PackageZip) {
        Stop-PortableService $taskLayout
        & (Join-Path $PSScriptRoot 'Apply-Update.ps1') -PackageZip $PackageZip -ExpectedSha256 (Get-FileHash -LiteralPath $PackageZip).Hash -PluginDirectory $taskLayout.app -DataDirectory $taskLayout.data -SkipProcessCheck | Out-Host
        if ((Get-FileHash -LiteralPath (Join-Path $taskLayout.data 'logs/2026-11-01.000.jsonl')).Hash -cne $logHash) { throw 'Portable update overwrote logs' }
        # A pending marker before the first directory move must preserve the intact old app.
        $backup=Join-Path $taskPortableRoot 'backups/update-abcdef12'
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Write-PortableJson (Join-Path $taskLayout.data 'update-transaction.json') @{portableRoot=$taskPortableRoot;backup='backups/update-abcdef12'}
        Restore-PortableUpdate $taskLayout
        if (!(Test-Path -LiteralPath (Join-Path $taskLayout.app 'scripts/gravity-guardian.dll'))) { throw 'Early update recovery removed the program' }
        Write-Host 'PASS portable update preserves settings/logs and early recovery is safe'
    }

    & $taskWindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $taskLayout.app 'scripts/Uninstall.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $taskRegistration)) { throw 'Portable disconnect failed' }
    $restored=Read-PortableJson (Join-Path $taskHostConfig 'config.json')
    if ($restored.userSettings.permissionPreset -cne 'AGENT_PERMISSION_PRESET_AUTO' -or !$restored.sidecars.other.enabled -or $restored.userSettings.globalPermissionGrants.allow -cnotcontains 'command(git status)') { throw 'Portable disconnect failed to restore user settings' }
    if (!(Test-Path -LiteralPath $taskLayout.config) -or !(Test-Path -LiteralPath $sourceLog)) { throw 'Disconnect removed settings or original logs' }
    Write-Host ('PASS portable disconnect preserves data; fixture: '+$taskFixture)
} finally {
    if ($taskLayout -and (Test-Path -LiteralPath $taskLayout.config)) {
        try { Stop-PortableService $taskLayout } catch {}
    }
    $env:CODEX_HOME=$taskSavedHome
}
