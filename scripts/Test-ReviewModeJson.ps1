[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell JSON compatibility regression failed' }
}
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
$fixture=Join-Path (Split-Path $PSScriptRoot -Parent) ('.local/review-mode-json-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
function Check-Json([bool]$Value,[string]$Message) { if (!$Value) { throw $Message } }
function Assert-JsonValue($Actual,$Expected,[string]$Label) {
    if ($null -eq $Expected) { Check-Json ($null -eq $Actual) "$Label lost null"; return }
    if ($Expected -is [Collections.IDictionary]) {
        Check-Json ($Actual -is [Collections.IDictionary] -and $Actual.Count -eq $Expected.Count) "$Label changed object shape"
        foreach ($key in $Expected.Keys) {
            Check-Json ($Actual.Contains($key)) "$Label lost key $key"
            Assert-JsonValue $Actual[$key] $Expected[$key] "$Label.$key"
        }
        return
    }
    if ($Expected -is [array]) {
        Check-Json ($Actual -is [array] -and $Actual.Count -eq $Expected.Count) "$Label changed array shape"
        for ($index=0; $index -lt $Expected.Count; $index++) { Assert-JsonValue $Actual[$index] $Expected[$index] "$Label[$index]" }
        return
    }
    if ($Expected -is [bool]) { Check-Json ($Actual -is [bool]) "$Label changed boolean type" }
    if ($Expected -is [string]) { Check-Json ($Actual -is [string]) "$Label changed string type" }
    Check-Json ($Actual -ceq $Expected) "$Label changed scalar value"
}
$nested=[object[]]::new(3)
$nested[0]=@(1,2); $nested[1]=@(); $nested[2]=@($null)
$cases=@(
    @{json='[]';expected=@()},
    @{json='[1]';expected=@(1)},
    @{json='[1,2]';expected=@(1,2)},
    @{json='[null]';expected=@($null)},
    @{json='[{"path":"a"}]';expected=@(@{path='a'})},
    @{json='[{"path":"a"},{"path":"b"}]';expected=@(@{path='a'},@{path='b'})},
    @{json='[[1,2],[],[null]]';expected=$nested},
    @{json='{"empty":[],"one":[false],"nested":[[1,2],[],[null]],"object":{}}';expected=@{empty=@();one=@($false);nested=$nested;object=@{}}},
    @{json='{}';expected=@{}},
    @{json='null';expected=$null},
    @{json='false';expected=$false},
    @{json='true';expected=$true},
    @{json='0';expected=0},
    @{json='""';expected=''},
    @{json='"sample \"quoted\" text"';expected='sample "quoted" text'}
)
$path=Join-Path $fixture 'value.json'
foreach ($case in $cases) {
    $parsed=$case.json | ConvertFrom-JsonHashtable
    Assert-JsonValue $parsed $case.expected ('parser '+$case.json)
    Check-Json (@($case.json | ConvertFrom-JsonHashtable).Count -eq 1) 'Parser enumerated its root value'
    [IO.File]::WriteAllText($path,$case.json,[Text.UTF8Encoding]::new($false))
    $read=Read-PortableJson $path
    Assert-JsonValue $read $case.expected ('reader '+$case.json)
    Check-Json (@(Read-PortableJson $path).Count -eq 1) 'File reader enumerated its root value'
}
Check-Json ($null -eq (Read-PortableJson (Join-Path $fixture 'missing.json'))) 'Missing file behavior changed'
$direct=ConvertTo-HashtableDeep $nested
Assert-JsonValue $direct $nested 'recursive collection conversion'
foreach ($invalid in @('{bad','1,2','[1],"value":[2]')) {
    $rejected=$false
    try { $null=$invalid | ConvertFrom-JsonHashtable } catch { $rejected=$true }
    Check-Json $rejected 'Invalid JSON became valid through the compatibility wrapper'
}
Write-Host "PASS D03 JSON arrays, nested objects, null and scalars retain their shape through parser and file reader (PowerShell $($PSVersionTable.PSVersion))"

# Real permission journals: no binary, service, registry, login or model is needed.
foreach ($projectCount in @(0,1,2)) {
    $configRoot=Join-Path $fixture ("mode-$projectCount/config")
    $globalPath=Join-Path $configRoot 'config.json'
    Write-PortableJson $globalPath @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW';enableTerminalSandbox=$false};unrelated=@{list=@('keep')}}
    for ($index=0;$index -lt $projectCount;$index++) {
        Write-PortableJson (Join-Path $configRoot "projects/p$index.json") @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO';enableTerminalSandbox=$false}}
    }
    $backup=Join-Path $fixture "mode-$projectCount/backup"
    $changes=@(Set-CodexReviewMode -ConfigRoot $configRoot -BackupDirectory $backup)
    $journalPath=Join-Path $backup 'review-mode/rollback.json'
    $journal=Read-PortableJson $journalPath
    Check-Json ($journal -is [array] -and $journal.Count -eq (1+$projectCount)) 'Migration journal lost record array'
    foreach ($entry in $journal) {
        Assert-CodexReviewModeChange $configRoot $entry
        foreach ($pseudo in @('Length','Rank','SyncRoot','IsFixedSize')) { Check-Json (!$entry.ContainsKey($pseudo)) 'Journal contains array metadata instead of record fields' }
    }
    # Restoring one record and multiple records must share the same code path.
    Restore-CodexReviewMode -ConfigRoot $configRoot -Changes $journal
    $restored=Read-PortableJson $globalPath
    Check-Json ($restored.userSettings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW' -and !$restored.userSettings.enableTerminalSandbox) 'Journal restore lost global permission settings'
    Assert-JsonValue $restored.unrelated @{list=@('keep')} 'unrelated setting'
    $retry=@(Set-CodexReviewMode -ConfigRoot $configRoot -BackupDirectory (Join-Path $backup 'retry'))
    if ($projectCount -gt 0) { Remove-Item -LiteralPath (Join-Path $configRoot 'projects/p0.json') }
    $repaired=@(Set-CodexReviewMode -ConfigRoot $configRoot -BackupDirectory (Join-Path $backup 'repair') -PreviousChanges $retry)
    Check-Json ($repaired.Count -eq [Math]::Max(1,$projectCount)) 'Repair retained a deleted project or lost a live record'
    Restore-CodexReviewMode -ConfigRoot $configRoot -Changes $repaired
    if ($projectCount -gt 0) { Check-Json (!(Test-Path -LiteralPath (Join-Path $configRoot 'projects/p0.json'))) 'Repair or restore recreated a deleted project' }
}

# Reject an incomplete or malformed journal before applying even its first valid record.
$configRoot=Join-Path $fixture 'invalid/config'
$globalPath=Join-Path $configRoot 'config.json'
Write-PortableJson $globalPath @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW'}}
$valid=@(Set-CodexReviewMode -ConfigRoot $configRoot -BackupDirectory (Join-Path $fixture 'invalid/backup'))[0]
$before=[IO.File]::ReadAllText($globalPath)
$badRecords=@($null,42,@{path=$globalPath},@{path=$globalPath;section='settings';original=$valid.original;installed=$valid.installed},
    @{path=$globalPath;section='userSettings';original=@{};installed=$valid.installed},
    @{path=$globalPath;section='userSettings';original=@{permissionPreset=@{present='false';value='AUTO'}};installed=$valid.installed})
foreach ($bad in $badRecords) {
    $rejected=$false
    try { Restore-CodexReviewMode -ConfigRoot $configRoot -Changes @($valid,$bad) } catch { $rejected=$_.Exception.Message -like 'Invalid review-mode change record*' }
    Check-Json $rejected 'Malformed permission record was not rejected'
    Check-Json ([IO.File]::ReadAllText($globalPath) -ceq $before) 'Malformed later record allowed a partial restore'
}
Write-Host "PASS D03 single/multi-record permission journals, deleted projects and invalid-record rejection (PowerShell $($PSVersionTable.PSVersion))"

# Exercise only Portable's permission-journal path. Service and registry calls
# are inert; connection/update stop-failure behavior belongs to deferred D01.
& {
    $portableRoot=Join-Path $fixture 'portable'
    $gemini=Join-Path $fixture 'portable-gemini'
    $configRoot=Join-Path $gemini 'config'
    $globalPath=Join-Path $configRoot 'config.json'
    $projectPath=Join-Path $configRoot 'projects/project.json'
    Write-PortableJson $globalPath @{userSettings=@{permissionPreset='AGENT_PERMISSION_PRESET_REQUEST_REVIEW';enableTerminalSandbox=$false};sidecars=@{other=@{enabled=$true}};list=@('unchanged')}
    Write-PortableJson $projectPath @{settings=@{permissionPreset='AGENT_PERMISSION_PRESET_AUTO';enableTerminalSandbox=$false}}
    $layout=@{root=$portableRoot;app=(Join-Path $portableRoot 'app');data=(Join-Path $portableRoot 'data');config=(Join-Path $portableRoot 'config/approval.json');manifest=(Join-Path $portableRoot 'data/installation.json')}
    foreach ($relative in @('runtime/dotnet.exe','scripts/gravity-guardian.dll','native/ag-guardian-host.exe','hooks.json')) {
        $file=Join-Path $layout.app $relative
        New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($file,'inert portable fixture')
    }
    Write-PortableJson (Join-Path $layout.app 'plugin.json') @{name='gravity-guardian'}
    Write-PortableJson (Join-Path $layout.app 'native/SOURCE.json') @{binarySha256=(Get-FileHash -LiteralPath (Join-Path $layout.app 'native/ag-guardian-host.exe')).Hash}
    $faulted=Join-Path $fixture 'Portable-Faulted.ps1'
    $portableSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Portable.ps1'))
    $needle='        if (!$Options.NoStart) {'
    Check-Json ($portableSource.Contains($needle)) 'Portable permission injection point changed'
    $injection=@'
        $edited=Read-PortableJson (Join-Path $configRoot 'config.json')
        $edited.theme='later-user-edit'
        Write-PortableJson (Join-Path $configRoot 'config.json') $edited
        throw 'D03 injected after portable permission commit'
'@
    [IO.File]::WriteAllText($faulted,$portableSource.Replace($needle,$injection+"`r`n"+$needle),[Text.UTF8Encoding]::new($true))
    . $faulted
    function Assert-PortableHostStopped {}
    function Stop-PortableService {}
    function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) return $null }
    $failed=$false
    try { Connect-Portable $layout $gemini '' @{NoStart=$true} | Out-Null }
    catch { $failed=$_.Exception.Message -ceq 'D03 injected after portable permission commit' }
    $restored=Read-PortableJson $globalPath
    Check-Json ($failed -and $restored.userSettings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW' -and !$restored.userSettings.enableTerminalSandbox -and $restored.theme -ceq 'later-user-edit') 'Portable journal did not restore permissions while preserving unrelated later edits'
    Check-Json ((Read-PortableJson $projectPath).settings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_AUTO') 'Portable journal did not restore project permissions'
    Check-Json (!(Test-Path -LiteralPath $layout.manifest) -and !(Test-Path -LiteralPath (Join-Path $configRoot 'plugins/gravity-guardian'))) 'Failed Portable connection retained manifest or registration'
    . (Join-Path $PSScriptRoot 'Portable.ps1')
    function Assert-PortableHostStopped {}
    function Stop-PortableService {}
    Connect-Portable $layout $gemini '' @{NoStart=$true} | Out-Null
    Disconnect-Portable $layout | Out-Null
    $restored=Read-PortableJson $globalPath
    Check-Json ($restored.userSettings.permissionPreset -ceq 'AGENT_PERMISSION_PRESET_REQUEST_REVIEW' -and !$restored.sidecars.ContainsKey('gravity-guardian/reviewer') -and $restored.sidecars.other.enabled) 'Portable disconnect lost original permissions or sidecar'
    Assert-JsonValue $restored.list @('unchanged') 'Portable configuration array'
}
Write-Host "PASS D03 Portable permission rollback and disconnect preserve original settings (PowerShell $($PSVersionTable.PSVersion))"
$global:LASTEXITCODE=0
