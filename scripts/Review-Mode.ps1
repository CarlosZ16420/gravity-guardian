# Shared, reversible native permission-mode migration. No permission grants are added.
function ConvertTo-HashtableDeep($InputObject) {
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [PSCustomObject]) {
        $table = @{}
        foreach ($prop in $InputObject.PSObject.Properties) { $table[$prop.Name] = ConvertTo-HashtableDeep $prop.Value }
        return $table
    }
    if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($element in $InputObject) { $items.Add((ConvertTo-HashtableDeep $element)) }
        return , $items.ToArray()
    }
    return $InputObject
}

function ConvertFrom-JsonHashtable([Parameter(Mandatory,ValueFromPipeline)][string]$Json) {
    process {
        if ($PSVersionTable.PSVersion.Major -ge 7) { return ($Json | Microsoft.PowerShell.Utility\ConvertFrom-Json -AsHashtable) }
        return (ConvertTo-HashtableDeep ($Json | Microsoft.PowerShell.Utility\ConvertFrom-Json))
    }
}

function Set-Utf8NoBom([Parameter(Mandatory)][string]$LiteralPath,[Parameter(Mandatory,ValueFromPipeline)][string]$Content,[string]$Encoding='utf8') {
    process {
        [IO.File]::WriteAllText($LiteralPath, $Content, [Text.UTF8Encoding]::new($false))
    }
}

function Get-RelativePathCompat([Parameter(Mandatory)][string]$BasePath,[Parameter(Mandatory)][string]$TargetPath) {
    $prefix = [IO.Path]::GetFullPath($BasePath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($TargetPath)
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw ('Target path is outside base directory: ' + $TargetPath) }
    return $full.Substring($prefix.Length)
}

function Get-CodexNativeSettings {
    @{
        permissionPreset='AGENT_PERMISSION_PRESET_DEFAULT'
        enableTerminalSandbox=$true
        autoExecutionPolicy='CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX'
    }
}

function Assert-CodexModePath([string]$ConfigRoot,[string]$Path) {
    $taskBase=[IO.Path]::GetFullPath($ConfigRoot)
    $taskFull=[IO.Path]::GetFullPath($Path)
    $taskGlobal=Join-Path $taskBase 'config.json'
    $taskProjects=Join-Path $taskBase 'projects'
    if($taskFull -ne $taskGlobal -and ((Split-Path $taskFull -Parent) -ne $taskProjects -or [IO.Path]::GetExtension($taskFull) -ne '.json')) {
        throw 'Review-mode path is outside the native configuration files'
    }
    if((Get-Item -LiteralPath $taskFull).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Review-mode configuration is a reparse point'}
}

function Set-CodexReviewMode([string]$ConfigRoot,[string]$BackupDirectory,[object[]]$PreviousChanges=@()) {
    $taskChanges=@{}
    foreach($taskChange in $PreviousChanges){
        Assert-CodexModePath $ConfigRoot $taskChange.path
        $taskChanges[$taskChange.path]=$taskChange
    }
    $taskCandidates=@(@{path=(Join-Path $ConfigRoot 'config.json');section='userSettings';global=$true})
    $taskProjectRoot=Join-Path $ConfigRoot 'projects'
    if(Test-Path -LiteralPath $taskProjectRoot){
        $taskCandidates+=@(Get-ChildItem -LiteralPath $taskProjectRoot -Filter '*.json' -File | ForEach-Object {@{path=$_.FullName;section='settings';global=$false}})
    }
    $taskDesired=Get-CodexNativeSettings
    foreach($taskCandidate in $taskCandidates){
        $taskPath=$taskCandidate.path
        Assert-CodexModePath $ConfigRoot $taskPath
        $taskHash=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash
        $taskDocument=Get-Content -Encoding UTF8 -LiteralPath $taskPath -Raw|ConvertFrom-JsonHashtable
        $taskSection=$taskDocument[$taskCandidate.section]
        if($null -eq $taskSection){
            if($taskCandidate.global){throw 'Missing native userSettings'}
            continue
        }
        # Explicit Request Review/Default presets are the user's rules. Only migrate Auto overrides.
        if(!$taskCandidate.global -and $taskSection.permissionPreset -ne 'AGENT_PERMISSION_PRESET_AUTO'){continue}
        $taskOriginal=@{}
        $taskChanged=$false
        foreach($taskKey in $taskDesired.Keys){
            $taskOriginal[$taskKey]=@{present=$taskSection.ContainsKey($taskKey);value=$taskSection[$taskKey]}
            if(!$taskSection.ContainsKey($taskKey) -or $taskSection[$taskKey] -cne $taskDesired[$taskKey]){$taskChanged=$true}
            $taskSection[$taskKey]=$taskDesired[$taskKey]
        }
        if(!$taskChanged){continue}
        $taskModeBackup=Join-Path $BackupDirectory 'review-mode'
        New-Item -ItemType Directory -Path $taskModeBackup -Force|Out-Null
        $taskBackupName=if($taskCandidate.global){'global.json'}else{'project-'+[IO.Path]::GetFileName($taskPath)}
        Copy-Item -LiteralPath $taskPath -Destination (Join-Path $taskModeBackup $taskBackupName)
        $taskTemporary=$taskPath+'.codex-review.tmp'
        $taskDocument|ConvertTo-Json -Depth 100|Set-Utf8NoBom -LiteralPath $taskTemporary -Encoding utf8
        if(!$taskChanges.ContainsKey($taskPath)){
            $taskChanges[$taskPath]=@{path=$taskPath;section=$taskCandidate.section;original=$taskOriginal;installed=$taskDesired}
        }
        # Journal before committing each file, so a partial installation has an exact recovery record.
        ConvertTo-Json -InputObject @($taskChanges.Values) -Depth 20|Set-Utf8NoBom -LiteralPath (Join-Path $taskModeBackup 'changes.json') -Encoding utf8
        if((Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash -ne $taskHash){throw 'Native settings changed during review-mode migration'}
        Move-Item -LiteralPath $taskTemporary -Destination $taskPath -Force
    }
    @($taskChanges.Values)
}

function Restore-CodexReviewMode([string]$ConfigRoot,[object[]]$Changes=@()) {
    foreach($taskChange in $Changes){
        if(!(Test-Path -LiteralPath $taskChange.path)){continue}
        Assert-CodexModePath $ConfigRoot $taskChange.path
        $taskHash=(Get-FileHash -LiteralPath $taskChange.path -Algorithm SHA256).Hash
        $taskDocument=Get-Content -Encoding UTF8 -LiteralPath $taskChange.path -Raw|ConvertFrom-JsonHashtable
        $taskSection=$taskDocument[$taskChange.section]
        if($null -eq $taskSection){continue}
        # Restore the preset as a group. A later user mode selection must be preserved in full.
        $taskUntouched=$true
        foreach($taskKey in $taskChange.installed.Keys){
            if(!$taskSection.ContainsKey($taskKey) -or $taskSection[$taskKey] -cne $taskChange.installed[$taskKey]){$taskUntouched=$false}
        }
        if(!$taskUntouched){Write-Warning ('User changed native review mode; preserved: '+$taskChange.path);continue}
        foreach($taskKey in $taskChange.original.Keys){
            $taskPrior=$taskChange.original[$taskKey]
            if($taskPrior.present){$taskSection[$taskKey]=$taskPrior.value}else{$taskSection.Remove($taskKey)}
        }
        $taskTemporary=$taskChange.path+'.codex-review.tmp'
        $taskDocument|ConvertTo-Json -Depth 100|Set-Utf8NoBom -LiteralPath $taskTemporary -Encoding utf8
        if((Get-FileHash -LiteralPath $taskChange.path -Algorithm SHA256).Hash -ne $taskHash){throw 'Native settings changed during review-mode restoration'}
        Move-Item -LiteralPath $taskTemporary -Destination $taskChange.path -Force
    }
}
function Update-ApprovalReviewerConfig {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$PluginDirectory
    )
    if (!$Config.Contains('enableNativeState') -or $Config['reviewerBackend'] -eq 'Cli') {
        $Config['enableNativeState'] = $true
    }
    $Config['reviewerBackend'] = 'NativeGuardian'
    foreach ($taskKey in @('codexPath', 'codexPrefixArguments', 'reviewerTransport', 'enableReviewerSessions',
        'maxContextBytes', 'maxEvidenceBytes', 'maxEvidenceRecords', 'maxEvidenceContentBytes',
        'maxReviewerSessionTurns', 'maxReviewerSessionBytes', 'maxReviewerSessionInputTokens')) {
        $Config.Remove($taskKey)
    }
    $Config['policyDirectory'] = Join-Path $PluginDirectory 'policy/effective-codex'
    $Config['guardianPath'] = Join-Path $PluginDirectory 'native/ag-guardian-host.exe'
}
