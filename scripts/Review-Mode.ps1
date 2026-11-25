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
    $defaults = [ordered]@{
        enableNativeAskHandoff = $false
        escalateAuthorizedDenials = $true
        delegateProtectedPaths = $true
        maxNativeHistoryBytes = 8388608
        enableDetailedLogs = $false
        maxLogSegmentBytes = 16777216
        maxInputBytes = 1048576
    }
    foreach ($taskDefault in $defaults.GetEnumerator()) {
        if (!$Config.Contains($taskDefault.Key)) {
            $Config[$taskDefault.Key] = $taskDefault.Value
        }
    }
    $Config['policyDirectory'] = Join-Path $PluginDirectory 'policy/effective-codex'
    $Config['guardianPath'] = Join-Path $PluginDirectory 'native/ag-guardian-host.exe'
}
function Get-ApprovalDistribution([string]$Bundle) {
    $metadata = Join-Path $Bundle 'distribution.json'
    if (!(Test-Path -LiteralPath $metadata -PathType Leaf)) { return 'standalone' }
    $type = (Get-Content -Encoding UTF8 -LiteralPath $metadata -Raw | ConvertFrom-Json).type
    if ($type -cnotin @('standalone','lite')) { throw "Unknown package distribution: $type" }
    return $type
}

function Test-ApprovalX64Executable([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }
            $reader.BaseStream.Position = 0x3c
            $reader.BaseStream.Position = $reader.ReadUInt32()
            return $reader.ReadUInt32() -eq 0x4550 -and $reader.ReadUInt16() -eq 0x8664
        } finally { $reader.Dispose() }
    } catch { return $false }
}

function Test-ApprovalX64Runtime([string]$Path) {
    if (!(Test-ApprovalX64Executable $Path)) { return $false }
    try {
        $start = [Diagnostics.ProcessStartInfo]::new($Path, '--list-runtimes')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEndAsync()
            $errorOutput = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(5000)) { $process.Kill(); return $false }
            return $process.ExitCode -eq 0 -and $output.GetAwaiter().GetResult() -match '(?m)^Microsoft\.NETCore\.App 10\.0\.\d+ \['
        } finally { $process.Dispose() }
    } catch { return $false }
}

function Resolve-ApprovalRuntime([string]$Bundle, [switch]$Installed, [string[]]$SystemCandidates) {
    $bundled = Join-Path $Bundle 'runtime/dotnet.exe'
    if ((Get-ApprovalDistribution $Bundle) -eq 'standalone') {
        if (!(Test-Path -LiteralPath $bundled -PathType Leaf)) { throw "Standalone .NET executable is missing: $bundled" }
        return $bundled
    }
    if (Test-Path -LiteralPath (Join-Path $Bundle 'runtime')) { throw 'Lite package contains a bundled runtime' }
    if ($Installed) {
        $sidecar = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $Bundle 'sidecars/reviewer/sidecar.json') -Raw | ConvertFrom-Json
        if ([IO.Path]::IsPathRooted([string]$sidecar.command) -and (Test-Path -LiteralPath $sidecar.command -PathType Leaf)) {
            return [string]$sidecar.command
        }
    }
    if (!$PSBoundParameters.ContainsKey('SystemCandidates')) {
        $SystemCandidates = @(
            foreach ($directory in @($env:ProgramW6432, $env:ProgramFiles)) {
                if ($directory) { Join-Path $directory 'dotnet/dotnet.exe' }
            }
            Get-Command dotnet.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source
        )
    }
    $prefix = [IO.Path]::GetFullPath($Bundle).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($candidate in ($SystemCandidates | Select-Object -Unique)) {
        if (![IO.Path]::IsPathRooted($candidate)) { continue }
        $path = [IO.Path]::GetFullPath($candidate)
        if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $path.Contains('%')) { continue }
        if (Test-ApprovalX64Runtime $path) { return $path }
    }
    throw 'Gravity Steward Lite requires the x64 .NET 10 Runtime. Install it with winget install Microsoft.DotNet.Runtime.10 --architecture x64 or download https://dotnet.microsoft.com/download/dotnet/10.0.'
}

function Set-ApprovalHookRuntime([string]$Bundle, [string]$Runtime) {
    if ((Get-ApprovalDistribution $Bundle) -ne 'lite') { return }
    $path = Join-Path $Bundle 'hooks.json'
    $hooks = Get-Content -Encoding UTF8 -LiteralPath $path -Raw | ConvertFrom-JsonHashtable
    $events = $hooks['codex-approval']
    $commands = foreach ($event in $events.Values) {
        foreach ($item in $event) {
            if ($item.Contains('hooks')) { $item['hooks'] } else { $item }
        }
    }
    $template = '.\runtime\dotnet.exe '
    foreach ($handler in $commands) {
        if ($handler.command.StartsWith($template, [StringComparison]::Ordinal)) {
            $arguments = $handler.command.Substring($template.Length)
        } elseif ($handler.command -match '^cmd\.exe /D /V:OFF /S /C ""[^"]+" (.+)"$') {
            $arguments = $Matches[1]
        } else { throw 'Unknown release hook command' }
        $handler.command = 'cmd.exe /D /V:OFF /S /C ""' + $Runtime + '" ' + $arguments + '"'
    }
    $hooks | ConvertTo-Json -Depth 16 | Set-Utf8NoBom -LiteralPath $path
}

function Clear-DelegatedProtectedGrants([string]$ConfigRoot, [string]$DataDirectory) {
    if ([string]::IsNullOrWhiteSpace($DataDirectory)) { return }
    $ledgerPath = Join-Path $DataDirectory 'delegated-grants.json'
    $lockPath = Join-Path $DataDirectory 'delegated-grants.lock'
    $owned = @()
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        if ((Get-Item -LiteralPath $ledgerPath).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Delegated grants ledger is a reparse point'
        }
        $ledger = Get-Content -Encoding UTF8 -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
        if ($ledger.ownedGrants) {
            $owned = @($ledger.ownedGrants | ForEach-Object { [string]$_ } | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
        }
    }
    if ($owned.Count -gt 0 -and ![string]::IsNullOrWhiteSpace($ConfigRoot)) {
        $configPath = Join-Path $ConfigRoot 'config.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            Assert-CodexModePath $ConfigRoot $configPath
            $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            $document = Get-Content -Encoding UTF8 -LiteralPath $configPath -Raw | ConvertFrom-JsonHashtable
            $allow = $document.userSettings.globalPermissionGrants.allow
            if ($null -ne $allow) {
                $filtered = @($allow | Where-Object { $owned -cnotcontains [string]$_ })
                if ($filtered.Count -ne @($allow).Count) {
                    $document.userSettings.globalPermissionGrants.allow = @($filtered)
                    $temp = $configPath + '.codex-delegation.tmp'
                    $document | ConvertTo-Json -Depth 100 | Set-Utf8NoBom -LiteralPath $temp -Encoding utf8
                    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $configHash) {
                        throw 'Native settings changed during delegated grant cleanup'
                    }
                    Move-Item -LiteralPath $temp -Destination $configPath -Force
                }
            }
        }
    }
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { Remove-Item -LiteralPath $ledgerPath -Force }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
