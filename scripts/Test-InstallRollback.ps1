[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ge 6) {
    & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell installation rollback regression failed' }
    return
}
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('.local/install-rollback-'+[Guid]::NewGuid().ToString('N'))
$scripts=Join-Path $fixture 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
foreach ($name in @('Install.ps1','Review-Mode.ps1','Portable.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts }
$installer=Join-Path $scripts 'Install.ps1'
$source=[IO.File]::ReadAllText($installer)
$needle='if (!$NoStart) {'
if (($source.Split(@($needle),[StringSplitOptions]::None)).Count -ne 2) { throw 'Installation failure injection point changed' }
[IO.File]::WriteAllText($installer,$source.Replace($needle,"if (!`$NoStart) { throw 'injected before ensure' }`r`n"+$needle),[Text.UTF8Encoding]::new($true))
$bundle=Join-Path $fixture 'bundle'
$gemini=Join-Path $fixture 'gemini'
$data=Join-Path $fixture 'custom-data'
$plugin=Join-Path $gemini 'config/plugins/gravity-guardian'
foreach ($relative in @('runtime','scripts','native')) { New-Item -ItemType Directory -Path (Join-Path $bundle $relative) -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/where.exe') -Destination (Join-Path $bundle 'runtime/dotnet.exe')
[IO.File]::WriteAllText((Join-Path $bundle 'scripts/gravity-guardian.dll'),'inert assembly')
[IO.File]::WriteAllText((Join-Path $bundle 'native/ag-guardian-host.exe'),'inert native host')
foreach ($name in @('plugin.json','hooks.json','pricing.json')) { Copy-Item -LiteralPath (Join-Path $root ('plugin/'+$name)) -Destination $bundle }
$config=Join-Path $gemini 'config/config.json'
Write-PortableJson $config @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW';enableTerminalSandbox=$false};sidecars=@{other=@{enabled=$true}}}
# Preserve isolates native stderr recovery from the separate Windows PowerShell
# JSON-array compatibility problem in review-mode rollback journals.
$options=@{BundlePath=$bundle;GeminiRoot=$gemini;DataDirectory=$data;AntigravityPath=$env:ComSpec;ReviewMode='Preserve'}
foreach ($upgrade in @($false,$true)) {
    if ($upgrade) { & $installer @options -NoStart | Out-Null }
    $beforeConfig=[IO.File]::ReadAllText($config)
    $manifest=Join-Path $data 'installation.json'
    $preferences=Join-Path $data 'panel-settings.json'
    $beforeManifest=if ($upgrade) { [IO.File]::ReadAllText($manifest) } else { $null }
    $beforePreferences=if ($upgrade) { [IO.File]::ReadAllText($preferences) } else { $null }
    $beforeApproval=if ($upgrade) { [IO.File]::ReadAllText((Join-Path $plugin 'approval.json')) } else { $null }
    $failed=$false
    try { & $installer @options | Out-Null } catch {
        if ($_.Exception.Message -notlike '*injected before ensure*' -or $_.Exception.Message -like '*recovery is incomplete*') { throw }
        $failed=$true
    }
    if (!$failed -or (Read-PortableJson $config).userSettings.permissionPreset -ne (ConvertFrom-JsonHashtable $beforeConfig).userSettings.permissionPreset) { throw 'Rollback lost the current permission mode' }
    $restored=Read-PortableJson $config
    if (!$restored.sidecars.other.enabled -or $restored.sidecars.ContainsKey('gravity-guardian/reviewer') -ne $upgrade) { throw 'Rollback lost sidecar state' }
    if (Test-Path -LiteralPath (Join-Path $gemini 'config/gravity-guardian-install-incomplete.json')) { throw 'Recovered install retained incomplete marker' }
    if ($upgrade) {
        if ([IO.File]::ReadAllText($manifest) -cne $beforeManifest -or [IO.File]::ReadAllText($preferences) -cne $beforePreferences -or [IO.File]::ReadAllText((Join-Path $plugin 'approval.json')) -cne $beforeApproval) { throw 'Upgrade did not restore prior plugin, manifest and preferences' }
    } elseif ((Test-Path -LiteralPath $plugin) -or (Test-Path -LiteralPath $manifest) -or (Test-Path -LiteralPath $preferences)) { throw 'Failed fresh installation retained committed state' }
}
Write-Host 'PASS R01 Windows PowerShell 5.1 NoStart=false / ReviewMode=Preserve rollback restores fresh and upgrade state despite native stderr'
$global:LASTEXITCODE=0
