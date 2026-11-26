# Internal portable lifecycle helpers, shared by the existing install/uninstall/update entry points.
function Assert-PortablePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/') -or $full.StartsWith('\\')) { throw 'Use a local application folder, not a drive root or network share' }
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw ('Symbolic links are not supported here: ' + $part) }
    }
}

function Get-PortableLayout([string]$Root = '') {
    if (!$Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $marker = Join-Path $Root 'portable.json'
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { return $null }
    $info = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-JsonHashtable
    if ($info.storageMode -cne 'portable' -or $info.layoutVersion -ne 1) { throw 'Unsupported portable layout' }
    Assert-PortablePath $Root
    foreach ($relative in @('app','config','data','backups','temp')) { Assert-PortablePath (Join-Path $Root $relative) }
    @{ root=$Root; app=(Join-Path $Root 'app'); config=(Join-Path $Root 'config/approval.json'); data=(Join-Path $Root 'data'); temp=(Join-Path $Root 'temp'); manifest=(Join-Path $Root 'data/installation.json') }
}

function Write-PortableJson([string]$Path, $Value) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 40 | Set-Utf8NoBom -LiteralPath $temporary
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-PortableJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-JsonHashtable) }
    return $null
}

function Copy-PortableVerified([string]$Source, [string]$Destination) {
    Assert-PortablePath $Source
    Assert-PortablePath $Destination
    $entries = @(Get-ChildItem -LiteralPath $Source -Recurse -Force)
    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Cannot copy a directory containing symbolic links' }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($file in @($entries | Where-Object { !$_.PSIsContainer })) {
        $relative = Get-RelativePathCompat $Source $file.FullName
        $target = Join-Path $Destination $relative
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw ('Existing file differs: ' + $target) }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw ('Copy verification failed: ' + $relative) }
    }
}

function Assert-PortableHostStopped([string]$AntigravityPath = '', [string]$ConfigRoot = '') {
    $defaultConfig=Join-Path $env:USERPROFILE '.gemini/config'
    $isDefault=!$ConfigRoot -or [IO.Path]::GetFullPath($ConfigRoot) -ieq [IO.Path]::GetFullPath($defaultConfig)
    $running = @(Get-Process -Name Antigravity -ErrorAction SilentlyContinue | Where-Object {
        $isDefault -or !$AntigravityPath -or ($_.Path -and $_.Path -ieq $AntigravityPath)
    })
    if ($running.Count) { throw 'Fully exit Antigravity before connecting, disconnecting or updating' }
}

function Invoke-PortableCore($Layout, [string]$Command, [string]$ConfigPath = '', [switch]$Quiet) {
    if (!$ConfigPath) { $ConfigPath = $Layout.config }
    if ($Command -eq 'ensure') {
        # A detached host inherits stdout handles. Capture startup to files, not a PS pipe
        # whose EOF would otherwise wait for the long-lived host to exit.
        $logs = Join-Path (Split-Path $ConfigPath -Parent) '../data/service'
        if ($Layout.data) { $logs=Join-Path $Layout.data 'service' }
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $id=[Guid]::NewGuid().ToString('N').Substring(0,8)
        $output=Join-Path $logs ($id+'.stdout.log')
        $errors=Join-Path $logs ($id+'.stderr.log')
        $arguments=@(('"'+(Join-Path $Layout.app 'scripts/gravity-guardian.dll')+'"'),'ensure','--config',('"'+$ConfigPath+'"'))
        $startup=Start-Process -FilePath (Join-Path $Layout.app 'runtime/dotnet.exe') -ArgumentList $arguments -WorkingDirectory $Layout.app -WindowStyle Hidden -RedirectStandardOutput $output -RedirectStandardError $errors -PassThru
        try {
            if (!$startup.WaitForExit(30000)) { $startup.Kill(); throw 'Approval service startup timed out' }
            if ($null -ne $startup.ExitCode -and $startup.ExitCode -ne 0) { throw ('Approval service startup failed: '+[IO.File]::ReadAllText($errors)) }
        } finally { $startup.Dispose() }
        return
    }
    if ($Quiet) { $result = & (Join-Path $Layout.app 'runtime/dotnet.exe') (Join-Path $Layout.app 'scripts/gravity-guardian.dll') $Command --config $ConfigPath 2>$null }
    else { $result = & (Join-Path $Layout.app 'runtime/dotnet.exe') (Join-Path $Layout.app 'scripts/gravity-guardian.dll') $Command --config $ConfigPath }
    if ($LASTEXITCODE -ne 0) { throw ('Approval command failed: ' + $Command) }
    return $result
}

function Stop-PortableService($Layout) {
    if (!(Test-Path -LiteralPath $Layout.config)) { return }
    New-Item -ItemType Directory -Path $Layout.data -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Layout.data 'uninstalled'), 'service stopped')
    $runtime = Resolve-ApprovalRuntime $Layout.app -Installed
    $assembly = Join-Path $Layout.app 'scripts/gravity-guardian.dll'
    $status = $null
    $query = & {
        # Windows PowerShell 5.1 turns redirected native stderr into error records.
        # A missing pipe is expected here; let the process check below decide safety.
        $ErrorActionPreference = 'Continue'
        $raw = & $runtime $assembly status --config $Layout.config 2>$null
        @{ exitCode=$LASTEXITCODE; output=$raw }
    }
    $statusRaw = $query.output
    if ($query.exitCode -ne 0 -or !$statusRaw) {
        # A stopped host has no pipe and status exits nonzero. Confirm using this exact
        # runtime, assembly and configuration; a failed query must abort the switch.
        Start-Sleep -Milliseconds 2200
        $matching = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -ieq $runtime -and $_.CommandLine -and
            $_.CommandLine.IndexOf($assembly,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $_.CommandLine.IndexOf($Layout.config,[StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($matching.Count) { throw 'Cannot confirm approval service state; switching was stopped' }
        return
    }
    $status = ($statusRaw -join [Environment]::NewLine) | ConvertFrom-Json
    if ($status.status -notin @('running','stopped')) { throw 'Unknown approval service state; switching was stopped' }
    if ($status.status -eq 'running' -and !$status.pid) { throw 'Approval service did not report its process; switching was stopped' }
    if ($status -and $status.pid) {
        & $runtime $assembly stop --config $Layout.config | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Approval service stop request failed; switching was stopped' }
        $process = Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue
        if ($process) { try { if (!$process.WaitForExit(15000)) { throw 'Approval service did not stop' } } finally { $process.Dispose() } }
    }
    # supervise checks the stop marker every two seconds.
    Start-Sleep -Milliseconds 2200
}

function Set-PortableSidecar([string]$ConfigRoot, $Value) {
    $path = Join-Path $ConfigRoot 'config.json'
    Assert-CodexModePath $ConfigRoot $path
    $hash = (Get-FileHash -LiteralPath $path).Hash
    $document = Read-PortableJson $path
    if (!$document.sidecars) { $document.sidecars = @{} }
    if ($null -eq $Value) { $document.sidecars.Remove('gravity-guardian/reviewer') }
    else { $document.sidecars['gravity-guardian/reviewer'] = $Value }
    $temporary = $path + '.gravity-guardian.tmp'
    $document | ConvertTo-Json -Depth 100 | Set-Utf8NoBom -LiteralPath $temporary
    if ((Get-FileHash -LiteralPath $path).Hash -ne $hash) { throw 'Antigravity settings changed during connection' }
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Write-PortableRegistration($Layout, [string]$Registration) {
    New-Item -ItemType Directory -Path (Join-Path $Registration 'sidecars/reviewer') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Layout.app 'plugin.json') -Destination (Join-Path $Registration 'plugin.json') -Force
    $events = @{}
    foreach ($entry in @(@('PreToolUse','review',120), @('PostToolUse','post',5), @('SessionStart','session',5))) {
        # The system PowerShell guard is independent of the portable program. It emits a valid
        # blocking response even if the runtime cannot start, exits abnormally or returns no JSON.
        $rootLiteral = $Layout.root.Replace("'", "''")
        $operation = $entry[1]
        $fallback = if ($operation -eq 'review') { '{"decision":"deny","reason":"Gravity Guardian could not complete automatic review. Repair the local approval service before retrying."}' } else { '{}' }
        $code = @"
`$ErrorActionPreference='Stop'; [Console]::InputEncoding=[Text.UTF8Encoding]::new(`$false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false)
try {
  `$root='$rootLiteral'; `$runtime=Join-Path `$root 'app/runtime/dotnet.exe'; `$dll=Join-Path `$root 'app/scripts/gravity-guardian.dll'; `$config=Join-Path `$root 'config/approval.json'
  `$start=[Diagnostics.ProcessStartInfo]::new(); `$start.FileName=`$runtime; `$start.Arguments='"'+`$dll+'" $operation --config "'+`$config+'"'; `$start.WorkingDirectory=Join-Path `$root 'app'; `$start.UseShellExecute=`$false; `$start.CreateNoWindow=`$true; `$start.RedirectStandardInput=`$true; `$start.RedirectStandardOutput=`$true; `$start.RedirectStandardError=`$true; `$start.StandardOutputEncoding=[Text.UTF8Encoding]::new(`$false)
  `$p=[Diagnostics.Process]::Start(`$start); `$output=`$p.StandardOutput.ReadToEndAsync(); `$errors=`$p.StandardError.ReadToEndAsync()
  [Console]::OpenStandardInput().CopyTo(`$p.StandardInput.BaseStream); `$p.StandardInput.Close()
  if(!`$p.WaitForExit($([int]$entry[2] * 1000 - 1000))){try{`$p.Kill()}catch{}; throw 'Approval timeout'}
  `$text=`$output.GetAwaiter().GetResult().Trim(); if(`$p.ExitCode -ne 0 -or !`$text){throw 'Approval failed'}
  `$json=`$text | ConvertFrom-Json; if('$operation' -eq 'review' -and `$json.decision -cnotin @('allow','ask','deny','force_ask','auto_approve')){throw 'Invalid approval response'}
  [Console]::WriteLine(`$text)
} catch { [Console]::WriteLine('$fallback') } finally { if(`$p){`$p.Dispose()} }
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $handler = @{ type='command'; command=('powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded); timeout=[int]$entry[2] }
        $events[$entry[0]] = if ($entry[0] -eq 'SessionStart') { @($handler) } else { @(@{ matcher='*'; hooks=@($handler) }) }
    }
    Write-PortableJson (Join-Path $Registration 'hooks.json') @{ 'gravity-guardian'=$events }
    Write-PortableJson (Join-Path $Registration 'sidecars/reviewer/sidecar.json') @{
        command=(Join-Path $Layout.app 'runtime/dotnet.exe'); args=@((Join-Path $Layout.app 'scripts/gravity-guardian.dll'),'supervise','--config',$Layout.config)
        restart_policy='on-failure'; display_name='Gravity Guardian'; description='Native codex-auto-review permission reviewer'
    }
    Write-PortableJson (Join-Path $Registration 'binding.json') @{ storageMode='portable'; portableRoot=$Layout.root }
}

function Connect-Portable($Layout, [string]$GeminiRoot, [string]$AntigravityPath, [Collections.IDictionary]$Options) {
    $GeminiRoot = [IO.Path]::GetFullPath($GeminiRoot)
    $configRoot = Join-Path $GeminiRoot 'config'
    $registration = Join-Path $configRoot 'plugins/gravity-guardian'
    Assert-PortablePath $registration
    if ($configRoot -ieq $Layout.root -or $configRoot.StartsWith($Layout.root+'\',[StringComparison]::OrdinalIgnoreCase) -or $Layout.root.StartsWith($configRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an application folder outside the Antigravity configuration directory'
    }
    # Quoted shell parameters cannot represent these characters consistently across host versions.
    if ($Layout.root.IndexOfAny([char[]]'%"`') -ge 0 -or $Layout.root.Length -gt 110) { throw 'Choose a shorter application folder without percent, quote or backtick characters' }
    if ($Options.ContainsKey('DataDirectory') -and $Options.DataDirectory -and [IO.Path]::GetFullPath($Options.DataDirectory) -ine $Layout.data) { throw 'Portable data must remain in the application data folder' }
    foreach ($required in @('runtime/dotnet.exe','scripts/gravity-guardian.dll','native/ag-guardian-host.exe','native/SOURCE.json','plugin.json','hooks.json')) {
        if (!(Test-Path -LiteralPath (Join-Path $Layout.app $required) -PathType Leaf)) { throw ('Missing portable program file: ' + $required) }
    }
    $hostSettings = Read-PortableJson (Join-Path $configRoot 'config.json')
    if (!$hostSettings -or !$hostSettings.ContainsKey('userSettings')) { throw 'Open Antigravity once before connecting Gravity Guardian' }
    if (!$hostSettings.sidecars) { $hostSettings.sidecars=@{} }
    $binding = Read-PortableJson (Join-Path $registration 'binding.json')
    if ($binding -and $binding.portableRoot -ine $Layout.root) { throw 'Disconnect the currently connected portable copy first' }
    $previous = Read-PortableJson $Layout.manifest
    if ($previous -and $previous.configRoot -ine $configRoot) { throw 'Disconnect the current Antigravity target first' }
    $legacy = Read-PortableJson (Join-Path $registration 'approval.json')
    $oldData = if ($legacy) { [string]$legacy.dataDirectory } else { '' }
    $oldManifest = if ($oldData) { Read-PortableJson (Join-Path $oldData 'installation.json') } else { $null }
    if ($oldManifest -and ($oldManifest.configRoot -ine $configRoot -or $oldManifest.pluginDirectory -ine $registration)) { throw 'The previous installation record belongs to another target' }
    if ($Options.PlanOnly) { @{ storageMode='portable'; programDirectory=$Layout.app; dataDirectory=$Layout.data; configuration=$Layout.config; registrationDirectory=$registration; migrateFrom=$oldData } | ConvertTo-Json; return }
    Assert-PortableHostStopped $AntigravityPath $configRoot
    $identity = Read-PortableJson (Join-Path $Layout.app 'native/SOURCE.json')
    if ((Get-FileHash -LiteralPath (Join-Path $Layout.app 'native/ag-guardian-host.exe')).Hash -ine $identity.binarySha256) { throw 'Guardian integrity check failed' }
    $backup = Join-Path $Layout.root ('backups/connect-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $priorLocal = Read-PortableJson $Layout.manifest
    $hadRegistration = Test-Path -LiteralPath $registration
    if ($hadRegistration) {
        $plugin = Read-PortableJson (Join-Path $registration 'plugin.json')
        if ($plugin.name -cne 'gravity-guardian') { throw 'Refusing to replace another plugin' }
        Copy-PortableVerified $registration (Join-Path $backup 'registration')
    }
    $restore = if ($previous -and ($binding -or $previous.connected -eq $true)) { $previous } elseif ($oldManifest) { $oldManifest } else { @{ oldSidecar=$hostSettings.sidecars['gravity-guardian/reviewer']; reviewModeChanges=@() } }
    $oldSidecar = $hostSettings.sidecars['gravity-guardian/reviewer']
    $modeChanges = @()
    $registrationChanged = $false
    try {
        if ($legacy) {
            Assert-PortablePath $oldData
            $oldRoot = [IO.Path]::GetFullPath($oldData).TrimEnd('\','/')
            if ($oldRoot -ieq $Layout.root -or $oldRoot.StartsWith($Layout.root+'\',[StringComparison]::OrdinalIgnoreCase) -or $Layout.root.StartsWith($oldRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source and target data directories overlap' }
            $oldLayout = @{ app=$registration; config=(Join-Path $registration 'approval.json'); data=$oldRoot }
            Stop-PortableService $oldLayout
            Clear-DelegatedProtectedGrants -ConfigRoot $configRoot -DataDirectory $oldRoot
            if (Test-Path -LiteralPath (Join-Path $oldRoot 'logs')) { Copy-PortableVerified (Join-Path $oldRoot 'logs') (Join-Path $Layout.data 'logs') }
            if (Test-Path -LiteralPath (Join-Path $oldRoot 'approval-takeover-paused')) {
                New-Item -ItemType Directory -Path $Layout.data -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $oldRoot 'approval-takeover-paused') -Destination $Layout.data -Force
            }
            if ($oldManifest.backupDirectory) {
                if ((Split-Path ([IO.Path]::GetFullPath($oldManifest.backupDirectory)) -Parent) -ine (Join-Path $oldRoot 'backups')) { throw 'Invalid original installation backup location' }
                $origin = Join-Path $Layout.root 'backups/migrated-origin'
                Copy-PortableVerified $oldManifest.backupDirectory $origin
                $restore = $oldManifest.Clone(); $restore.backupDirectory=$origin
            }
        } elseif ($previous) { Stop-PortableService $Layout; Clear-DelegatedProtectedGrants -ConfigRoot $configRoot -DataDirectory $Layout.data }
        if (!(Test-Path -LiteralPath $Layout.config)) {
            $settings = @{ schemaVersion=2; model='codex-auto-review'; effort='low'; enableNativeState=$true; enableNativeRouting=$true; enableDetailedLogs=$false; enableNativeAskHandoff=$false; escalateAuthorizedDenials=$true; delegateProtectedPaths=$true }
            if ($legacy) { foreach ($key in $legacy.Keys) { $settings[$key]=$legacy[$key] } }
            foreach ($key in @('dataDirectory','policyDirectory','guardianPath','guardianPrefixArguments','codexHome','antigravityConfigDirectory','transcriptRoots','nativeStateLogPath','pipeName')) { $settings.Remove($key) }
            $settings.schemaVersion=2
            if ($Options.ContainsKey('Proxy')) { $settings.proxy=$Options.Proxy }
            if ($Options.ContainsKey('EnableDetailedLogs')) { $settings.enableDetailedLogs=[bool]$Options.EnableDetailedLogs }
            if ($Options.ContainsKey('ReviewRouting')) { $settings.enableNativeRouting=$Options.ReviewRouting -eq 'Conservative' }
            Write-PortableJson $Layout.config $settings
            $oldPricing=Join-Path $registration 'pricing.json'
            if ($legacy -and (Test-Path -LiteralPath $oldPricing) -and (Get-FileHash -LiteralPath $oldPricing).Hash -ine (Get-FileHash -LiteralPath (Join-Path $Layout.app 'pricing.json')).Hash) {
                Copy-Item -LiteralPath $oldPricing -Destination (Join-Path (Split-Path $Layout.config) 'pricing.json')
            }
            $preferences = if ($oldData) { Read-PortableJson (Join-Path $oldData 'panel-settings.json') } else { $null }
            if ($preferences) { Write-PortableJson (Join-Path (Split-Path $Layout.config) 'panel-settings.json') @{ autoCheckUpdates=[bool]$preferences.autoCheckUpdates; autoUpdate=[bool]$preferences.autoUpdate } }
        }
        $manifest = @{
            storageMode='portable'; connected=$true; portableRoot=$Layout.root; programDirectory=$Layout.app; pluginDirectory=$registration; configRoot=$configRoot; geminiRoot=$GeminiRoot; antigravityPath=$AntigravityPath
            codexHome=$(if ($legacy.codexHome) { $legacy.codexHome } elseif ($previous.codexHome) { $previous.codexHome } elseif ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
            oldSidecar=$restore.oldSidecar; reviewModeChanges=@($restore.reviewModeChanges); backupDirectory=$restore.backupDirectory; sidecarId='gravity-guardian/reviewer'; distribution='standalone'; dotnetPath=(Join-Path $Layout.app 'runtime/dotnet.exe')
        }
        foreach ($key in @('transcriptRoots','nativeStateLogPath')) { if ($legacy -and $legacy[$key]) { $manifest[$key]=$legacy[$key] } elseif ($previous -and $previous[$key]) { $manifest[$key]=$previous[$key] } }
        Write-PortableJson $Layout.manifest $manifest
        if ($hadRegistration) {
            Get-Process -Name GravityGuardian -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and $_.Path.StartsWith($registration+'\',[StringComparison]::OrdinalIgnoreCase)
            } | ForEach-Object { $_.Kill(); if (!$_.WaitForExit(10000)) { throw 'Installed panel did not stop' } }
            Assert-PortablePath $registration
            Remove-Item -LiteralPath $registration -Recurse -Force
        }
        $registrationChanged=$true
        Write-PortableRegistration $Layout $registration
        Set-PortableSidecar $configRoot @{ enabled=$true }
        if (!$Options.ContainsKey('ReviewMode') -or $Options.ReviewMode -eq 'Codex') {
            $modeChanges = @(Set-CodexReviewMode -ConfigRoot $configRoot -BackupDirectory $backup -PreviousChanges @($restore.reviewModeChanges))
            $manifest.reviewModeChanges=$modeChanges
            Write-PortableJson $Layout.manifest $manifest
        }
        Remove-Item -LiteralPath (Join-Path $Layout.data 'uninstalled') -Force -ErrorAction SilentlyContinue
        if (!$Options.NoStart) {
            Invoke-PortableCore $Layout 'ensure' | Out-Null
            $running=Invoke-PortableCore $Layout 'status' | ConvertFrom-Json
            if ($running.status -cne 'running' -or $running.portableRoot -ine $Layout.root) { throw 'Portable approval service did not become healthy' }
            Invoke-PortableCore $Layout 'check-guardian' | Out-Null
        }
        $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $run=(Get-ItemProperty -LiteralPath $runKey -Name GravityGuardian -ErrorAction SilentlyContinue).GravityGuardian
        if ($legacy -and $run -and $run.StartsWith(('"'+(Join-Path $registration 'app/GravityGuardian.exe')+'"'),[StringComparison]::OrdinalIgnoreCase)) {
            Set-ItemProperty -LiteralPath $runKey -Name GravityGuardian -Value ('"'+(Join-Path $Layout.root 'GravityGuardian.exe')+'" --minimized')
        }
        @{ ok=$true; storageMode='portable'; programDirectory=$Layout.app; dataDirectory=$Layout.data; configuration=$Layout.config; registrationDirectory=$registration; migratedFrom=$oldData } | ConvertTo-Json
    } catch {
        $failure = $_
        if ($registrationChanged) {
            try { Stop-PortableService $Layout; Clear-DelegatedProtectedGrants -ConfigRoot $configRoot -DataDirectory $Layout.data } catch {}
            $journal = Read-PortableJson (Join-Path $backup 'review-mode/rollback.json')
            if ($journal) { Restore-CodexReviewMode -ConfigRoot $configRoot -Changes @($journal) }
            Set-PortableSidecar $configRoot $oldSidecar
            Assert-PortablePath $registration
            if (Test-Path -LiteralPath $registration) { Remove-Item -LiteralPath $registration -Recurse -Force }
            if ($hadRegistration) { Copy-PortableVerified (Join-Path $backup 'registration') $registration }
        }
        if ($priorLocal) { Write-PortableJson $Layout.manifest $priorLocal }
        else { Remove-Item -LiteralPath $Layout.manifest -Force -ErrorAction SilentlyContinue }
        if ($legacy) {
            Remove-Item -LiteralPath (Join-Path $oldData 'uninstalled') -Force -ErrorAction SilentlyContinue
            try { Invoke-PortableCore @{ app=$registration; config=(Join-Path $registration 'approval.json') } 'ensure' | Out-Null } catch {}
        } elseif ($priorLocal -and $registrationChanged) {
            Remove-Item -LiteralPath (Join-Path $Layout.data 'uninstalled') -Force -ErrorAction SilentlyContinue
            try { Invoke-PortableCore $Layout 'ensure' | Out-Null } catch {}
        }
        throw $failure
    }
}

function Disconnect-Portable($Layout, [switch]$PlanOnly) {
    $manifest = Read-PortableJson $Layout.manifest
    if (!$manifest) { throw 'No portable connection record was found' }
    $registration = Join-Path $manifest.configRoot 'plugins/gravity-guardian'
    $binding = Read-PortableJson (Join-Path $registration 'binding.json')
    if (!$binding -or $binding.portableRoot -ine $Layout.root) { throw 'The Antigravity connection belongs to another location' }
    Assert-PortablePath $registration
    if ($PlanOnly) { @{ action='disconnect'; registrationDirectory=$registration; preservedData=$Layout.data } | ConvertTo-Json; return }
    Assert-PortableHostStopped $manifest.antigravityPath $manifest.configRoot
    Stop-PortableService $Layout
    Clear-DelegatedProtectedGrants -ConfigRoot $manifest.configRoot -DataDirectory $Layout.data
    Restore-CodexReviewMode -ConfigRoot $manifest.configRoot -Changes @($manifest.reviewModeChanges)
    $hostSettings = Read-PortableJson (Join-Path $manifest.configRoot 'config.json')
    if ($hostSettings.sidecars -and $hostSettings.sidecars['gravity-guardian/reviewer'].enabled -eq $true) { Set-PortableSidecar $manifest.configRoot $manifest.oldSidecar }
    $manifest.connected=$false
    Write-PortableJson $Layout.manifest $manifest
    Remove-Item -LiteralPath $registration -Recurse -Force
    $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $run=(Get-ItemProperty -LiteralPath $runKey -Name GravityGuardian -ErrorAction SilentlyContinue).GravityGuardian
    if ($run -and $run.StartsWith(('"'+(Join-Path $Layout.root 'GravityGuardian.exe')+'"'),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-ItemProperty -LiteralPath $runKey -Name GravityGuardian
    }
    @{ ok=$true; disconnected=$true; preservedData=$Layout.data } | ConvertTo-Json
}

function Restore-PortableUpdate($Layout) {
    $record = Join-Path $Layout.data 'update-transaction.json'
    $transaction = Read-PortableJson $record
    if (!$transaction) { return }
    $backup = [IO.Path]::GetFullPath((Join-Path $Layout.root $transaction.backup))
    if ($transaction.portableRoot -ine $Layout.root -or (Split-Path $backup -Parent) -ine (Join-Path $Layout.root 'backups') -or (Split-Path $backup -Leaf) -notmatch '^update-[a-f0-9]{8}$') { throw 'Invalid portable recovery location' }
    Assert-PortablePath $backup
    # A marker can exist before the first move. Only restore components with a verified backup.
    $oldApp = Join-Path $backup 'app'
    if (Test-Path -LiteralPath $oldApp) {
        Assert-PortablePath $Layout.app
        if (Test-Path -LiteralPath $Layout.app) {
            try { Stop-PortableService $Layout } catch {}
            Move-Item -LiteralPath $Layout.app -Destination (Join-Path $backup 'failed-app')
        }
        Move-Item -LiteralPath $oldApp -Destination $Layout.app
    }
    foreach ($name in @('GravityGuardian.exe','portable.json','README.md')) {
        $saved = Join-Path $backup $name
        if (Test-Path -LiteralPath $saved) {
            $target = Join-Path $Layout.root $name
            $pending = $target + '.restore'
            Copy-Item -LiteralPath $saved -Destination $pending -Force
            if (Test-Path -LiteralPath $target) { [IO.File]::Replace($pending, $target, (Join-Path $backup ($name+'.replaced')), $true) }
            else { Move-Item -LiteralPath $pending -Destination $target }
        }
    }
    $manifest = Read-PortableJson $Layout.manifest
    if ($manifest -and (Read-PortableJson (Join-Path $manifest.pluginDirectory 'binding.json')).portableRoot -ieq $Layout.root) {
        Write-PortableRegistration $Layout $manifest.pluginDirectory
        Remove-Item -LiteralPath (Join-Path $Layout.data 'uninstalled') -Force -ErrorAction SilentlyContinue
        Invoke-PortableCore $Layout 'ensure' | Out-Null
    }
    Remove-Item -LiteralPath $record -Force
}

function Update-Portable($Layout, [string]$PackageZip, [string]$ExpectedSha256, [int]$WaitPid, [switch]$RelaunchPanel, [switch]$SkipProcessCheck) {
    if ((Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash -ine $ExpectedSha256.Trim()) { throw 'Update package SHA-256 mismatch' }
    $manifest = Read-PortableJson $Layout.manifest
    if (!$SkipProcessCheck) { Assert-PortableHostStopped $manifest.antigravityPath $manifest.configRoot }
    if (Test-Path -LiteralPath (Join-Path $Layout.data 'update-transaction.json')) { throw 'Finish the previous portable update recovery first' }
    $id = [Guid]::NewGuid().ToString('N').Substring(0,8)
    $stage = Join-Path $Layout.root ('temp/u-'+$id)
    Assert-PortablePath $stage
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($PackageZip)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = [long]0
        $prefix = $null
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if (!$prefix) { $prefix=$name.Split('/')[0]+'/' }
            if (!$name.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Update ZIP must have one top-level folder' }
            $relative=$name.Substring($prefix.Length)
            if (!$relative -or $relative.EndsWith('/')) { continue }
            if ($relative -match '(^|/)\.\.?(/|$)|:|^/|(^|/)(auth\.json|config|data|backups|temp)(/|$)' -or !$names.Add($relative)) { throw ('Unsafe or duplicate ZIP path: '+$relative) }
            if ($relative -notlike 'app/*' -and $relative -cnotin @('GravityGuardian.exe','portable.json','README.md')) { throw ('Unexpected portable file: '+$relative) }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'ZIP symbolic links are not supported' }
            $total += $entry.Length
            if ($total -gt 310MB) { throw 'Unpacked update exceeds 310 MiB' }
            $target = [IO.Path]::GetFullPath((Join-Path $stage $relative))
            if (!$target.StartsWith($stage+'\',[StringComparison]::OrdinalIgnoreCase) -or $target.Length -gt 250) { throw 'Update path is outside the staging directory or too long' }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target)
        }
    } finally { $archive.Dispose() }
    $package = Read-PortableJson (Join-Path $stage 'app/package-manifest.json')
    $marker = Read-PortableJson (Join-Path $stage 'portable.json')
    if ($package.storageMode -cne 'portable' -or $marker.storageMode -cne 'portable' -or $marker.layoutVersion -ne 1) { throw 'This is not a supported portable update package' }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$expected.Add('app/package-manifest.json')
    foreach ($file in $package.files) {
        if (!$names.Contains($file.path) -or !$expected.Add($file.path)) { throw 'Update file list mismatch' }
        if ((Get-FileHash -LiteralPath (Join-Path $stage $file.path)).Hash -ine $file.sha256) { throw ('Update file hash mismatch: '+$file.path) }
    }
    if ($expected.Count -ne $names.Count) { throw 'Update contains unlisted files' }
    $newPlugin = Read-PortableJson (Join-Path $stage 'app/plugin.json')
    $native = Read-PortableJson (Join-Path $stage 'app/native/SOURCE.json')
    $nativeExe = Join-Path $stage 'app/native/ag-guardian-host.exe'
    if ($newPlugin.name -cne 'gravity-guardian' -or $newPlugin.version -cne $package.version -or (Get-FileHash -LiteralPath $nativeExe).Hash -ine $native.binarySha256) { throw 'Update program identity mismatch' }
    $version = & $nativeExe --version | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $version.protocol -cne $native.protocol -or $version.upstreamCommit -cne $native.upstreamCommit) { throw 'Updated Guardian failed its offline preflight' }
    if ($WaitPid -gt 0) {
        $waiting = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
        if ($waiting -and !$waiting.WaitForExit(15000)) { throw 'Panel did not exit before updating' }
    }
    $worker = Join-Path $Layout.data 'updates'
    New-Item -ItemType Directory -Path $worker -Force | Out-Null
    foreach ($name in @('Apply-Update.ps1','Review-Mode.ps1','Portable.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        $target = Join-Path $worker $name
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
    }
    $backup = Join-Path $Layout.root ('backups/update-'+$id)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in @('GravityGuardian.exe','portable.json','README.md')) { Copy-Item -LiteralPath (Join-Path $Layout.root $name) -Destination (Join-Path $backup $name) }
    $record = Join-Path $Layout.data 'update-transaction.json'
    Write-PortableJson $record @{ portableRoot=$Layout.root; backup=('backups/update-'+$id); workerPid=$PID; workerStarted=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc().ToString() }
    try {
        if ($manifest) { Stop-PortableService $Layout; Clear-DelegatedProtectedGrants -ConfigRoot $manifest.configRoot -DataDirectory $Layout.data }
        Move-Item -LiteralPath $Layout.app -Destination (Join-Path $backup 'app')
        Move-Item -LiteralPath (Join-Path $stage 'app') -Destination $Layout.app
        foreach ($name in @('GravityGuardian.exe','portable.json','README.md')) {
            $pending = Join-Path $stage $name
            [IO.File]::Replace($pending,(Join-Path $Layout.root $name),(Join-Path $backup ($name+'.swap')),$true)
        }
        if ($manifest -and (Read-PortableJson (Join-Path $manifest.pluginDirectory 'binding.json')).portableRoot -ieq $Layout.root) {
            Write-PortableRegistration $Layout $manifest.pluginDirectory
            Remove-Item -LiteralPath (Join-Path $Layout.data 'uninstalled') -Force -ErrorAction SilentlyContinue
            Invoke-PortableCore $Layout 'ensure' | Out-Null
            Invoke-PortableCore $Layout 'check-guardian' | Out-Null
            $status = Invoke-PortableCore $Layout 'status' | ConvertFrom-Json
            if ($status.version -cne $package.version -or $status.portableRoot -ine $Layout.root) { throw 'Updated service identity mismatch' }
        }
        Remove-Item -LiteralPath $record -Force
        Remove-Item -LiteralPath $stage -Recurse -Force
        # Root is checked above; prune only completed, known program backups, never migration data.
        $backupsRoot = Join-Path $Layout.root 'backups'
        foreach ($expired in @(Get-ChildItem -LiteralPath $backupsRoot -Directory | Where-Object { $_.Name -match '^update-[a-f0-9]{8}$' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 2)) {
            Assert-PortablePath $expired.FullName
            if ((Split-Path $expired.FullName -Parent) -ine $backupsRoot) { throw 'Invalid backup cleanup target' }
            Remove-Item -LiteralPath $expired.FullName -Recurse -Force
        }
        @{ ok=$true; storageMode='portable'; version=$package.version; programDirectory=$Layout.app } | ConvertTo-Json
    } catch {
        $failure=$_
        Restore-PortableUpdate $Layout
        throw $failure
    }
    if ($RelaunchPanel) { Start-Process -FilePath (Join-Path $Layout.root 'GravityGuardian.exe') -WorkingDirectory $Layout.root }
}
