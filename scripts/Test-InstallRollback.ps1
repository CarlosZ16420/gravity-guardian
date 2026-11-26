[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ge 6) {
    & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell installation rollback regression failed' }
}
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('.local/install-rollback-'+[Guid]::NewGuid().ToString('N'))
$scripts=Join-Path $fixture 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
foreach ($name in @('Install.ps1','Uninstall.ps1','Review-Mode.ps1','Portable.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts }
$installer=Join-Path $scripts 'Install.ps1'
$source=[IO.File]::ReadAllText($installer)
$needle='if (!$NoStart) {'
if (($source.Split(@($needle),[StringSplitOptions]::None)).Count -ne 2) { throw 'Installation failure injection point changed' }
[IO.File]::WriteAllText($installer,$source.Replace($needle,"if (!`$NoStart) { throw 'injected before ensure' }`r`n"+$needle),[Text.UTF8Encoding]::new($true))
$bundle=Join-Path $fixture 'bundle'
foreach ($relative in @('runtime','scripts','native')) { New-Item -ItemType Directory -Path (Join-Path $bundle $relative) -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/where.exe') -Destination (Join-Path $bundle 'runtime/dotnet.exe')
[IO.File]::WriteAllText((Join-Path $bundle 'scripts/gravity-guardian.dll'),'inert assembly')
[IO.File]::WriteAllText((Join-Path $bundle 'native/ag-guardian-host.exe'),'inert native host')
foreach ($name in @('plugin.json','hooks.json','pricing.json')) { Copy-Item -LiteralPath (Join-Path $root ('plugin/'+$name)) -Destination $bundle }
function Check-Rollback([bool]$Value,[string]$Message) { if (!$Value) { throw $Message } }
foreach ($mode in @('Preserve','Codex')) {
    $gemini=Join-Path $fixture "$mode/gemini"
    $data=Join-Path $fixture "$mode/custom-data"
    $plugin=Join-Path $gemini 'config/plugins/gravity-guardian'
    $config=Join-Path $gemini 'config/config.json'
    Write-PortableJson $config @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW';enableTerminalSandbox=$false;globalPermissionGrants=@{allow=@('command(git status)');ask=@();deny=@('command(blocked)')}};sidecars=@{other=@{enabled=$true}}}
    foreach ($project in @('retained','deleted')) {
        Write-PortableJson (Join-Path $gemini "config/projects/$project.json") @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO';enableTerminalSandbox=$false}}
    }
    $options=@{BundlePath=$bundle;GeminiRoot=$gemini;DataDirectory=$data;AntigravityPath=$env:ComSpec}
    # Omit ReviewMode for Codex: test the actual default, not an explicit override.
    if ($mode -eq 'Preserve') { $options.ReviewMode='Preserve' }
    foreach ($upgrade in @($false,$true)) {
        if ($upgrade) {
            & $installer @options -NoStart | Out-Null
            if ($mode -eq 'Codex') {
                $changed=Read-PortableJson $config
                $changed.userSettings.permissionPreset='AGENT_PERMISSION_PRESET_AUTO'
                $changed.userSettings.enableTerminalSandbox=$false
                Write-PortableJson $config $changed
                Write-PortableJson (Join-Path $gemini 'config/projects/retained.json') @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO';enableTerminalSandbox=$false}}
            }
            Remove-Item -LiteralPath (Join-Path $gemini 'config/projects/deleted.json')
        }
        $beforeConfig=Read-PortableJson $config
        $projectPath=Join-Path $gemini 'config/projects/retained.json'
        $beforeProject=Read-PortableJson $projectPath
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
        $restored=Read-PortableJson $config
        Check-Rollback ($failed -and $restored.userSettings.permissionPreset -ceq $beforeConfig.userSettings.permissionPreset -and $restored.userSettings.enableTerminalSandbox -eq $beforeConfig.userSettings.enableTerminalSandbox) 'Rollback lost the current permission mode'
        foreach ($key in @('permissionPreset','enableTerminalSandbox','autoExecutionPolicy')) {
            Check-Rollback ($restored.userSettings.ContainsKey($key) -eq $beforeConfig.userSettings.ContainsKey($key) -and $restored.userSettings[$key] -ceq $beforeConfig.userSettings[$key]) "Rollback lost permission field $key"
        }
        $restoredProject=Read-PortableJson $projectPath
        Check-Rollback ($restoredProject.settings.permissionPreset -ceq $beforeProject.settings.permissionPreset -and $restoredProject.settings.enableTerminalSandbox -eq $beforeProject.settings.enableTerminalSandbox) 'Rollback lost project permission settings'
        Check-Rollback ($restored.userSettings.globalPermissionGrants.allow -is [array] -and $restored.userSettings.globalPermissionGrants.allow.Count -eq 1 -and $restored.userSettings.globalPermissionGrants.ask -is [array] -and $restored.userSettings.globalPermissionGrants.ask.Count -eq 0) 'Rollback changed permission-grant arrays'
        Check-Rollback ($restored.sidecars.other.enabled -and $restored.sidecars.ContainsKey('gravity-guardian/reviewer') -eq $upgrade) 'Rollback lost sidecar state'
        Check-Rollback (!(Test-Path -LiteralPath (Join-Path $gemini 'config/gravity-guardian-install-incomplete.json'))) 'Recovered install retained incomplete marker'
        if ($upgrade) {
            Check-Rollback ([IO.File]::ReadAllText($manifest) -ceq $beforeManifest -and [IO.File]::ReadAllText($preferences) -ceq $beforePreferences -and [IO.File]::ReadAllText((Join-Path $plugin 'approval.json')) -ceq $beforeApproval) 'Upgrade did not restore prior plugin, manifest and preferences'
            Check-Rollback (!(Test-Path -LiteralPath (Join-Path $gemini 'config/projects/deleted.json'))) 'Rollback recreated a deleted project'
        } else {
            Check-Rollback (!(Test-Path -LiteralPath $plugin) -and !(Test-Path -LiteralPath $manifest) -and !(Test-Path -LiteralPath $preferences)) 'Failed fresh installation retained committed state'
        }
    }
    & $installer @options -NoStart | Out-Null
    & (Join-Path $scripts 'Uninstall.ps1') -DataDirectory $data | Out-Null
    $uninstalled=Read-PortableJson $config
    Check-Rollback ($uninstalled.userSettings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW' -and !$uninstalled.userSettings.enableTerminalSandbox -and !$uninstalled.sidecars.ContainsKey('gravity-guardian/reviewer') -and $uninstalled.sidecars.other.enabled -and !(Test-Path -LiteralPath $plugin)) 'Uninstall lost original permissions or retained registration'
    Check-Rollback ((Read-PortableJson (Join-Path $gemini 'config/projects/retained.json')).settings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_AUTO') 'Uninstall did not restore project permission mode'
    Write-Host "PASS D03 NoStart=false / $mode fresh and upgrade rollback, deleted projects and uninstall (PowerShell $($PSVersionTable.PSVersion))"
}

# A damaged journal must leave explicit recovery evidence rather than claim success.
foreach ($invalid in @('root','record')) {
    $gemini=Join-Path $fixture "invalid-$invalid/gemini"
    $data=Join-Path $fixture "invalid-$invalid/data"
    $config=Join-Path $gemini 'config/config.json'
    Write-PortableJson $config @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW'};sidecars=@{}}
    $faulted=Join-Path $scripts "Install-invalid-$invalid.ps1"
    $corruption=if ($invalid -eq 'root') { "'false'" } else { "(ConvertTo-Json -InputObject @(@{path=`$taskAppConfig}) -Compress)" }
    $injection="if (!`$NoStart) { [IO.File]::WriteAllText((Join-Path `$taskBackup 'review-mode/rollback.json'),$corruption); throw 'injected invalid journal' }`r`n"
    [IO.File]::WriteAllText($faulted,$source.Replace($needle,$injection+$needle),[Text.UTF8Encoding]::new($true))
    $failed=$false
    try { & $faulted -BundlePath $bundle -GeminiRoot $gemini -DataDirectory $data -AntigravityPath $env:ComSpec | Out-Null }
    catch { $failed=$_.Exception.Message -like '*recovery is incomplete*Invalid review-mode*Original error: injected invalid journal*' }
    $marker=Join-Path $gemini 'config/gravity-guardian-install-incomplete.json'
    Check-Rollback ($failed -and (Test-Path -LiteralPath $marker)) 'Invalid journal did not preserve incomplete recovery marker'
    $recovery=Read-PortableJson $marker
    Check-Rollback (Test-Path -LiteralPath (Join-Path $recovery.backupDirectory 'review-mode/rollback.json')) 'Invalid journal lost its backup evidence'
}
Write-Host "PASS D03 malformed journal preserves backup and incomplete marker (PowerShell $($PSVersionTable.PSVersion))"
$global:LASTEXITCODE=0
