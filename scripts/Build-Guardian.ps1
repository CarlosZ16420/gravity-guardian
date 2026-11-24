[CmdletBinding()]
param([ValidateSet('Release','Debug')][string]$Profile='Release',[string]$Toolchain='stable',[switch]$Offline)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskParentRoot=Split-Path $taskRoot -Parent
$taskOrigin=Get-Content -LiteralPath (Join-Path $taskRoot 'native/SOURCE.json') -Raw|ConvertFrom-Json
$taskOutput=Join-Path $taskRoot '.local/guardian-host-build'
New-Item -ItemType Directory -Path $taskOutput -Force|Out-Null

$taskFiles=@('native/SOURCE.json','native/patches/guardian-entry.patch','native/guardian-host/Cargo.toml','native/guardian-host/src/main.rs','native/guardian-host/src/bootstrap.rs','scripts/Build-Guardian.ps1')
$taskHashes=@{};foreach($taskFile in $taskFiles){$taskHashes[$taskFile]=(Get-FileHash -LiteralPath (Join-Path $taskRoot $taskFile) -Algorithm SHA256).Hash.ToLowerInvariant()}
$taskManifest=Join-Path $taskOutput 'SOURCE.json'
$taskExe=Join-Path $taskOutput 'ag-guardian-host.exe'

if((Test-Path -LiteralPath $taskManifest) -and (Test-Path -LiteralPath $taskExe)){
    $taskPrevious=Get-Content -LiteralPath $taskManifest -Raw|ConvertFrom-JsonHashtable
    $taskUnchanged=$taskPrevious.profile -eq $Profile -and $taskPrevious.toolchain -eq $Toolchain -and $taskPrevious.binarySha256 -eq (Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach($taskFile in $taskFiles){if($taskPrevious.sourceSha256[$taskFile] -ne $taskHashes[$taskFile]){$taskUnchanged=$false}}
    if($taskUnchanged){Write-Host "Verified native build: $taskExe";return}
}

# Reuse verified sibling workspace native build if all Rust source/patch hashes and binary hash match.
$taskParentOutput=Join-Path $taskParentRoot '.local/guardian-host-build'
$taskParentManifest=Join-Path $taskParentOutput 'SOURCE.json'
$taskParentExe=Join-Path $taskParentOutput 'ag-guardian-host.exe'
if((Test-Path -LiteralPath $taskParentManifest) -and (Test-Path -LiteralPath $taskParentExe)){
    $taskParentPrev=Get-Content -LiteralPath $taskParentManifest -Raw|ConvertFrom-JsonHashtable
    $taskNativeFiles=@('native/SOURCE.json','native/patches/guardian-entry.patch','native/guardian-host/Cargo.toml','native/guardian-host/src/main.rs','native/guardian-host/src/bootstrap.rs')
    $taskNativeMatch=($taskParentPrev.profile -eq $Profile -and $taskParentPrev.toolchain -eq $Toolchain -and $taskParentPrev.binarySha256 -eq (Get-FileHash -LiteralPath $taskParentExe -Algorithm SHA256).Hash.ToLowerInvariant())
    foreach($nf in $taskNativeFiles){if($taskParentPrev.sourceSha256[$nf] -ne $taskHashes[$nf]){$taskNativeMatch=$false}}
    if($taskNativeMatch){
        Copy-Item -LiteralPath $taskParentExe -Destination $taskExe -Force
        Copy-Item -LiteralPath (Join-Path $taskParentOutput 'UPSTREAM-LICENSE') -Destination (Join-Path $taskOutput 'UPSTREAM-LICENSE') -Force
        if(Test-Path -LiteralPath (Join-Path $taskParentOutput 'UPSTREAM-NOTICE')){Copy-Item -LiteralPath (Join-Path $taskParentOutput 'UPSTREAM-NOTICE') -Destination (Join-Path $taskOutput 'UPSTREAM-NOTICE') -Force}
        @{version=$taskParentPrev.version;protocol=$taskOrigin.protocol;upstreamCommit=$taskOrigin.commit;repository=$taskOrigin.repository;profile=$Profile;toolchain=$Toolchain;compiler=$taskParentPrev.compiler;sourceSha256=$taskHashes;binarySha256=$taskParentPrev.binarySha256;builtAt=$taskParentPrev.builtAt;releaseOptions=$taskParentPrev.releaseOptions}|
            ConvertTo-Json -Depth 8|Set-Utf8NoBom -LiteralPath $taskManifest -Encoding utf8
        Write-Host "Verified native Guardian from parent cache: $taskExe"
        return
    }
}

$taskSource=Join-Path $taskRoot '.local/guardian-host-upstream'
if(!(Test-Path -LiteralPath $taskSource)){
    $taskParentSource=Join-Path $taskParentRoot '.local/guardian-host-upstream'
    if(Test-Path -LiteralPath $taskParentSource){
        # The sibling can use a different patch. Share Git objects, not its working tree.
        & git -c core.longpaths=true -c "safe.directory=$taskParentSource" clone --shared --no-hardlinks -- $taskParentSource $taskSource
        if($LASTEXITCODE -ne 0){throw 'Cannot copy pinned Guardian source'}
    }else{
        if($Offline){throw 'Pinned upstream checkout is not cached'}
        & git -c core.longpaths=true clone --depth 1 --branch $taskOrigin.tag $taskOrigin.repository $taskSource
        if($LASTEXITCODE -ne 0){throw 'Cannot obtain pinned Guardian source'}
    }
}
$taskPatch=Join-Path $taskRoot 'native/patches/guardian-entry.patch'
Push-Location $taskSource
try{
    $taskCommit=(& git -c "safe.directory=$taskSource" rev-parse HEAD)
    if($LASTEXITCODE -ne 0 -or !$taskCommit -or $taskCommit.Trim() -ne $taskOrigin.commit){throw 'Unexpected Guardian source commit'}
    & git -c "safe.directory=$taskSource" apply --reverse --check $taskPatch 2>$null
    if($LASTEXITCODE -ne 0){& git -c "safe.directory=$taskSource" apply --check $taskPatch;if($LASTEXITCODE -ne 0){throw 'Upstream patch does not apply cleanly'};& git -c "safe.directory=$taskSource" apply $taskPatch;if($LASTEXITCODE -ne 0){throw 'Upstream patch failed'}}
    $taskPatchPaths=@('codex-rs/core/Cargo.toml','codex-rs/core/src/client.rs','codex-rs/core/src/codex_thread.rs',
        'codex-rs/core/src/guardian/input_budget.rs','codex-rs/core/src/guardian/mod.rs','codex-rs/core/src/guardian/request_budget.rs',
        'codex-rs/core/src/guardian/review.rs','codex-rs/core/src/session/turn.rs','codex-rs/guardian-context/src/action.rs','codex-rs/guardian-context/src/lib.rs')
    $taskActualPatch=(& git -c "safe.directory=$taskSource" diff --binary -- @taskPatchPaths) -join "`n"
    if($taskActualPatch.TrimEnd() -cne ([IO.File]::ReadAllText($taskPatch).Replace("`r`n","`n").TrimEnd())){throw 'Guardian core differs from the reviewed patch'}
}finally{Pop-Location}

$taskV8=Join-Path $taskRoot ('.local/rusty_v8-'+$taskOrigin.v8Commit)
if(!(Test-Path -LiteralPath (Join-Path $taskV8 'Cargo.toml'))){
    $taskParentV8=Join-Path $taskParentRoot ('.local/rusty_v8-'+$taskOrigin.v8Commit)
    if(Test-Path -LiteralPath (Join-Path $taskParentV8 'Cargo.toml')){
        $taskV8=$taskParentV8
    }else{
        $taskArchive=Join-Path $taskRoot '.local/rusty-v8-pinned.tar.gz'
        if(!(Test-Path -LiteralPath $taskArchive)){
            if($Offline){throw 'Pinned V8 source archive is not cached'}
            Invoke-WebRequest -Uri ('https://codeload.github.com/seanh-oai/rusty_v8/tar.gz/'+$taskOrigin.v8Commit) -OutFile $taskArchive
        }
        if((Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskOrigin.v8ArchiveSha256){throw 'V8 archive hash mismatch'}
        & tar -xf $taskArchive -C (Join-Path $taskRoot '.local')
        if($LASTEXITCODE -ne 0){throw 'V8 source extraction failed'}
    }
}
$taskCargoFile=Join-Path $taskSource 'codex-rs/Cargo.toml'
$taskCargo=[IO.File]::ReadAllText($taskCargoFile)
if(!$taskCargo.Contains('"ag-guardian-host"')){$taskCargo=$taskCargo.Replace('"thread-manager-sample",', '"thread-manager-sample",'+"`n"+'    "ag-guardian-host",')}
$taskV8RelPath=$taskV8.Replace('\','/')
$taskCargo=$taskCargo.Replace('v8 = { git = "https://github.com/seanh-oai/rusty_v8.git", rev = "'+$taskOrigin.v8Commit+'" }','v8 = { path = "'+$taskV8RelPath+'" }')
[IO.File]::WriteAllText($taskCargoFile,$taskCargo,[Text.UTF8Encoding]::new($false))
$taskHost=Join-Path $taskSource 'codex-rs/ag-guardian-host'
New-Item -ItemType Directory -Path $taskHost -Force|Out-Null
Copy-Item -Path (Join-Path $taskRoot 'native/guardian-host/*') -Destination $taskHost -Recurse -Force

$env:CARGO_INCREMENTAL='0'
if (!$env:CARGO_TARGET_DIR) {
    $env:CARGO_TARGET_DIR=Join-Path $taskRoot $(if($Profile -eq 'Release'){'.local/native-release-target'}else{'.local/native-build-target'})
}
if($Profile -eq 'Release'){
    $env:CARGO_PROFILE_RELEASE_DEBUG='0';$env:CARGO_PROFILE_RELEASE_LTO='false';$env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS='16';$env:CARGO_PROFILE_RELEASE_OPT_LEVEL='2'
}else{$env:CARGO_PROFILE_DEV_DEBUG='0'}
Push-Location (Join-Path $taskSource 'codex-rs')
try{
    $taskArguments=@(('+'+$Toolchain),'build','-p','ag-guardian-host')
    if($Profile -eq 'Release'){$taskArguments+='--release'}
    if($Offline){$taskArguments+='--offline'}
    & cargo @taskArguments
    if($LASTEXITCODE -ne 0){throw 'Native Guardian build failed'}
    $taskCompiler=(& rustc ('+'+$Toolchain) --version) -join ' '
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR ($Profile.ToLowerInvariant()+'/ag-guardian-host.exe')) -Destination $taskExe -Force
}finally{Pop-Location}
Copy-Item -LiteralPath (Join-Path $taskSource 'LICENSE') -Destination (Join-Path $taskOutput 'UPSTREAM-LICENSE') -Force
if(Test-Path -LiteralPath (Join-Path $taskSource 'NOTICE')){Copy-Item -LiteralPath (Join-Path $taskSource 'NOTICE') -Destination (Join-Path $taskOutput 'UPSTREAM-NOTICE') -Force}
$taskBuiltIdentity=(& $taskExe --version) | ConvertFrom-Json
if($LASTEXITCODE -ne 0 -or $taskBuiltIdentity.protocol -ne $taskOrigin.protocol -or $taskBuiltIdentity.upstreamCommit -ne $taskOrigin.commit){throw 'Built Guardian has the wrong identity'}
@{version=$taskBuiltIdentity.version;protocol=$taskOrigin.protocol;upstreamCommit=$taskOrigin.commit;repository=$taskOrigin.repository;profile=$Profile;toolchain=$Toolchain;compiler=$taskCompiler;sourceSha256=$taskHashes;binarySha256=(Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash.ToLowerInvariant();builtAt=[DateTime]::UtcNow.ToString('O');releaseOptions='opt-level=2, lto=false, codegen-units=16, debug=0'}|
    ConvertTo-Json -Depth 8|Set-Utf8NoBom -LiteralPath $taskManifest -Encoding utf8
Write-Host "Ready native Guardian: $taskExe"
