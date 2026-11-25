[CmdletBinding()]
param(
    [ValidateSet('Release','Debug','Dev')][string]$Profile='Release',
    [string]$Toolchain='stable',
    [ValidateSet('Default','Baseline','Symbols','Thin','ThinSingleUnit','ThinSize')][string]$ReleaseTuning='Default',
    [switch]$Offline,
    [switch]$ForceBuild,
    [switch]$PrintCacheKey,
    [switch]$SyncWorkspaceOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
if ($Profile -eq 'Dev') { $Profile = 'Debug' }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Release-Paths.ps1')
$parent = Split-Path $root -Parent
$origin = Get-Content -LiteralPath (Join-Path $root 'native/SOURCE.json') -Raw | ConvertFrom-Json
$policyPath = 'policy/upstream-codex/SOURCE.json'
$policy = Get-Content -LiteralPath (Join-Path $root $policyPath) -Raw | ConvertFrom-Json
$local = Join-Path $root '.local'
$buildTemp = Join-Path $local 'build-temp'
$source = Join-Path $local ('guardian-host-upstream-' + $origin.commit)
$output = if ($Profile -eq 'Debug') {
    if ($ReleaseTuning -ne 'Default') { throw 'Release tuning requires the Release profile' }
    Join-Path $local 'guardian-host-dev'
} elseif ($ReleaseTuning -eq 'Default') {
    Join-Path $local 'guardian-host-build'
} else {
    Join-Path $local "guardian-profiles/$ReleaseTuning"
}
$defaultTargetDir = Join-Path $local $(if ($Profile -eq 'Release') { 'native-release-target' } else { 'native-build-target' })
$patch = Join-Path $root 'native/patches/guardian-entry.patch'
$target = 'x86_64-pc-windows-msvc'
$name = 'ag-guardian-host'
$exe = "$name.exe"
$lf = [string][char]10
$utf8 = [Text.UTF8Encoding]::new($false)
function Hash-File($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Hash-Text([string]$value) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($value))).ToLowerInvariant()
}
function Normalize-DirectoryPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $volumeRoot = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $volumeRoot.Length) { return $full.TrimEnd('\', '/') }
    return $full
}
function Write-BuildInput($path, $value) {
    if (!(Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -cne $value) {
        [IO.File]::WriteAllText($path, $value, $utf8)
    }
}
function Sync-FileIfChanged([string]$sourcePath, [string]$destinationPath) {
    $destDir = Split-Path $destinationPath -Parent
    if (!(Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and ((Hash-File $sourcePath) -ceq (Hash-File $destinationPath))) {
        return
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}
function Invoke-SourceGit {
    & git -C $source -c core.longpaths=true -c core.autocrlf=false -c "safe.directory=$source" @args
    if ($LASTEXITCODE -ne 0) { throw "Guardian source verification failed: $($args[0])" }
}
function Read-HostIdentity($path) {
    $identity = & $path --version | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $identity.protocol -cne $origin.protocol -or $identity.upstreamCommit -cne $origin.commit -or !$identity.version) {
        throw 'Native Guardian executable identity mismatch'
    }
    $identity
}
function Test-HostCache($dir) {
    $manifest = Join-Path $dir 'SOURCE.json'
    $binary = Join-Path $dir $exe
    foreach ($path in @($manifest,$binary,(Join-Path $dir 'UPSTREAM-LICENSE'),(Join-Path $dir 'UPSTREAM-NOTICE'))) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    }
    try {
        $saved = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        if ($saved.profile -cne $Profile -or $saved.buildKey -cne $buildKey -or $saved.resolvedCargoLockSha256 -cne $lockHash -or $saved.binarySha256 -cne (Hash-File $binary)) { return $false }
        $identity = Read-HostIdentity $binary
        return $identity.version -ceq $saved.version -and $saved.hostCommit -ceq $origin.commit -and $saved.policySourceCommit -ceq $policy.commit
    } catch {
        Write-Verbose "Rejected native build cache: $($_.Exception.Message)"
        return $false
    }
}

$options = if ($Profile -eq 'Release') {
    $release = [ordered]@{ OPT_LEVEL='2'; LTO='false'; CODEGEN_UNITS='16'; DEBUG='0'; STRIP='none'; PANIC='unwind' }
    switch ($ReleaseTuning) {
        'Default' {
            foreach ($property in $origin.releaseOptions.PSObject.Properties) { $release[$property.Name] = [string]$property.Value }
        }
        'Symbols' { $release.STRIP = 'symbols' }
        'Thin' { $release.LTO = 'thin'; $release.STRIP = 'symbols' }
        'ThinSingleUnit' { $release.LTO = 'thin'; $release.STRIP = 'symbols'; $release.CODEGEN_UNITS = '1' }
        'ThinSize' { $release.LTO = 'thin'; $release.STRIP = 'symbols'; $release.OPT_LEVEL = 's' }
    }
    $release
} else {
    [ordered]@{ OPT_LEVEL='0'; LTO='off'; CODEGEN_UNITS='256'; DEBUG='0'; STRIP='none'; PANIC='unwind' }
}
$cargoProfile = if ($Profile -eq 'Release') { 'RELEASE' } else { 'DEV' }
$incremental = if ($Profile -eq 'Release') { '0' } else { '1' }
$savedEnv = [ordered]@{}
foreach ($envName in @('TMP','TEMP','CARGO_TARGET_DIR','CARGO_INCREMENTAL','CARGO_ENCODED_RUSTFLAGS','CFLAGS','CXXFLAGS','CC_SHELL_ESCAPED_FLAGS')) {
    $savedEnv[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
}
foreach ($entry in $options.GetEnumerator()) {
    $profileVar = 'CARGO_PROFILE_' + $cargoProfile + '_' + $entry.Key
    $savedEnv[$profileVar] = [Environment]::GetEnvironmentVariable($profileVar, 'Process')
}

try {
New-Item -ItemType Directory -Path $local,$buildTemp -Force | Out-Null
$env:TMP = $buildTemp
$env:TEMP = $buildTemp
if ($Profile -eq 'Release') {
    $pathSettings = Get-ReleasePathSettings $root
    foreach ($entry in $pathSettings.environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')
    }
}
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    $peer = Join-Path (Join-Path $parent '.local') (Split-Path $source -Leaf)
    if (Test-Path -LiteralPath (Join-Path $peer '.git')) {
        & git -c core.longpaths=true -c core.autocrlf=false -c "safe.directory=$peer" clone --shared --no-checkout -- $peer $source
        if ($LASTEXITCODE -ne 0) { throw 'Cannot copy pinned Guardian source' }
        Invoke-SourceGit checkout --detach $origin.commit
    } else {
        if ($Offline) { throw 'Pinned Guardian checkout is not cached' }
        & git -c core.longpaths=true -c core.autocrlf=false clone --depth 1 --branch $origin.tag -- $origin.repository $source
        if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch pinned Guardian source' }
    }
}
if ((Invoke-SourceGit rev-parse HEAD) -cne $origin.commit) { throw 'Unexpected Guardian source commit' }
$patchPaths = @(
    'codex-rs/core/Cargo.toml','codex-rs/core/src/client.rs','codex-rs/core/src/codex_thread.rs',
    'codex-rs/core/src/guardian/input_budget.rs','codex-rs/core/src/guardian/mod.rs',
    'codex-rs/core/src/guardian/request_budget.rs','codex-rs/core/src/guardian/review.rs','codex-rs/core/src/session/turn.rs',
    'codex-rs/guardian-context/src/allocation.rs','codex-rs/guardian-context/src/authorization.rs',
    'codex-rs/guardian-context/src/preparation/elastic.rs','codex-rs/guardian-context/src/preparation/transcript.rs'
)
& git -C $source -c core.longpaths=true -c core.autocrlf=false -c "safe.directory=$source" apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -ne 0) {
    Invoke-SourceGit apply --check $patch
    Invoke-SourceGit apply $patch
}
$actualPatch = (Invoke-SourceGit diff --binary HEAD -- @patchPaths) -join $lf
if ($actualPatch.TrimEnd() -cne ([IO.File]::ReadAllText($patch).Replace([string][char]13 + $lf,$lf).TrimEnd())) {
    throw 'Guardian source differs from the reviewed patch'
}

$workspace = Join-Path $source 'codex-rs'
$hostSource = Join-Path $root 'native/guardian-host'
$cargo = ((Invoke-SourceGit show 'HEAD:codex-rs/Cargo.toml') -join $lf) + $lf
$upstreamLock = ((Invoke-SourceGit show 'HEAD:codex-rs/Cargo.lock') -join $lf) + $lf
$v8Git = $origin.v8Repository + '.git'
$v8Pin = 'v8 = { git = "' + $v8Git + '", rev = "' + $origin.v8Commit + '" }'
$v8Source = 'source = "git+' + $v8Git + '?rev=' + $origin.v8Commit + '#' + $origin.v8Commit + '"'
$sample = '    "thread-manager-sample",'
if (!$cargo.Contains($sample) -or !$cargo.Contains($v8Pin) -or !$upstreamLock.Contains($v8Source)) {
    throw 'Pinned upstream Cargo layout or V8 source changed'
}
# Apply only the local graph changes to the upstream lock and require Cargo to accept it unchanged.
$pathLock = $upstreamLock.Replace($v8Source + $lf,'')
$lock = [regex]::Replace($pathLock,'(?s)(\[\[package\]\]\nname = "codex-core"\n.*? "sha1 0\.10\.6",)\n','$1' + $lf + ' "sha2 0.10.9",' + $lf)
if ($lock -ceq $pathLock) { throw 'Cannot add the Guardian core dependency to the lock' }
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $hostSource 'Cargo.toml')),'(?m)^version = "([^"]+)"').Groups[1].Value
if (!$version) { throw 'Missing Guardian host crate version' }
$hostLock = @"
[[package]]
name = "$name"
version = "$version"
dependencies = [
 "anyhow",
 "codex-core-api",
 "codex-guardian-context",
 "codex-guardian-reviewer",
 "codex-guardian-v2",
 "codex-protocol",
 "serde",
 "serde_json",
 "tokio",
 "tokio-util",
]
"@
$lock = $lock.Insert($lock.IndexOf('[[package]]'),$hostLock.Replace([string][char]13 + $lf,$lf) + $lf + $lf)
# The release tag bumps the workspace version after the upstream lock is recorded.
$releaseVersion = [regex]::Match($cargo,'(?m)^version = "([^"]+)"').Groups[1].Value
if (!$releaseVersion) { throw 'Cannot resolve pinned workspace version' }
$lock = [regex]::Replace($lock,'(?m)(^name = "[^"\n]+"\nversion = ")0\.0\.0("\n)(?!source = )',
    [Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Groups[1].Value + $releaseVersion + $match.Groups[2].Value })
$lockPath = Join-Path $workspace 'Cargo.lock'
Write-BuildInput $lockPath $lock
$lockHash = Hash-File $lockPath

$compiler = (& rustc "+$Toolchain" --version --verbose) -join $lf
if ($LASTEXITCODE -ne 0 -or !$compiler) { throw 'Cannot resolve the actual Rust toolchain' }
$cargoVersion = & cargo "+$Toolchain" --version
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the actual Cargo version' }

$resolvedTargetDir = Normalize-DirectoryPath $(if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) { $defaultTargetDir } else { $env:CARGO_TARGET_DIR })
$env:CARGO_TARGET_DIR = $resolvedTargetDir
$env:CARGO_INCREMENTAL = $incremental
foreach ($entry in $options.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(('CARGO_PROFILE_' + $cargoProfile + '_' + $entry.Key),$entry.Value,'Process')
}

$settings = [ordered]@{}
$settingsPattern = "^(CARGO_(PROFILE_${cargoProfile}_.*|BUILD_(RUST.*|TARGET)|TARGET_(?!DIR$).+|ENCODED_RUSTFLAGS|INCREMENTAL)|RUST(C|C_WRAPPER|C_WORKSPACE_WRAPPER|FLAGS)|RUSTY_V8_(ARCHIVE|MIRROR)|V8_FROM_SOURCE|CFLAGS.*|CXXFLAGS.*|CC.*|CXX.*)$"
Get-ChildItem Env: | Where-Object Name -Match $settingsPattern |
    Sort-Object Name | ForEach-Object { $settings[$_.Name] = Hash-Text $_.Value }
$hashes = [ordered]@{}
foreach ($file in @('native/SOURCE.json','native/patches/guardian-entry.patch','native/guardian-host/Cargo.toml',
        'native/guardian-host/src/main.rs','native/guardian-host/src/bootstrap.rs',
        'scripts/Build-Guardian.ps1','scripts/Release-Paths.ps1',$policyPath)) {
    $hashes[$file] = Hash-File (Join-Path $root $file)
}
$testHashes = [ordered]@{
    'native/guardian-host/src/offline_prompt_tests.rs' = Hash-File (Join-Path $root 'native/guardian-host/src/offline_prompt_tests.rs')
}
$buildKey = Hash-Text ([ordered]@{ profile=$Profile; compiler=$compiler; cargoVersion=$cargoVersion; target=$target;
    sourceSha256=$hashes; resolvedCargoLockSha256=$lockHash; options=$options; settings=$settings } | ConvertTo-Json -Depth 8 -Compress)
if ($PrintCacheKey) {
    [ordered]@{
        profile = $Profile
        releaseTuning = $ReleaseTuning
        outputDirectory = $output
        cargoTargetDir = $resolvedTargetDir
        cargoIncremental = $incremental
        options = $options
        settings = $settings
        sourceSha256 = $hashes
        testSourceSha256 = $testHashes
        buildKey = $buildKey
        cacheHit = (Test-HostCache $output)
    } | ConvertTo-Json -Depth 8
    return
}
if (!$SyncWorkspaceOnly -and !$ForceBuild -and (Test-HostCache $output)) {
    Write-Host "Verified native build: $(Join-Path $output $exe)"
    return
}
$parentOutputDirName = if ($Profile -eq 'Release') { 'guardian-host-build' } else { 'guardian-host-dev' }
$parentOutput = Join-Path $parent ".local/$parentOutputDirName"
if (!$SyncWorkspaceOnly -and !$ForceBuild -and $ReleaseTuning -eq 'Default' -and (Test-HostCache $parentOutput)) {
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    foreach ($file in @($exe,'UPSTREAM-LICENSE','UPSTREAM-NOTICE','SOURCE.json')) {
        Copy-Item -LiteralPath (Join-Path $parentOutput $file) -Destination $output -Force
    }
    Write-Host 'Reused verified native build from parent workspace'
    return
}

$v8Root = Join-Path $local 'guardian-v8-source'
$v8Stable = Join-Path $v8Root ('rusty_v8-' + $origin.v8Commit)
$v8Marker = Join-Path $v8Stable '.archive-sha256'
$v8Ready = (Test-Path -LiteralPath (Join-Path $v8Stable 'Cargo.toml') -PathType Leaf) -and
    (Test-Path -LiteralPath $v8Marker -PathType Leaf) -and
    ([IO.File]::ReadAllText($v8Marker).Trim() -ceq $origin.v8ArchiveSha256)
if (!$v8Ready) {
    $archiveName = 'rusty-v8-' + $origin.v8Commit + '.tar.gz'
    $archive = Join-Path $local $archiveName
    if (!(Test-Path -LiteralPath $archive)) {
        $parentArchive = Join-Path $parent ".local/$archiveName"
        if (Test-Path -LiteralPath $parentArchive -PathType Leaf) {
            $archive = $parentArchive
        } else {
            if ($Offline) { throw 'Pinned V8 archive is not cached' }
            $repoPath = ([Uri]$origin.v8Repository).AbsolutePath.Trim('/')
            $download = $archive + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            Invoke-WebRequest -Uri "https://codeload.github.com/$repoPath/tar.gz/$($origin.v8Commit)" -OutFile $download
            if ((Hash-File $download) -cne $origin.v8ArchiveSha256) { throw 'V8 download SHA-256 mismatch' }
            Move-Item -LiteralPath $download -Destination $archive
        }
    }
    if ((Hash-File $archive) -cne $origin.v8ArchiveSha256) { throw 'V8 archive SHA-256 mismatch' }
    $v8Stage = Join-Path $v8Root ('.stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $v8Stage -Force | Out-Null
    try {
        & tar -xf $archive -C $v8Stage
        if ($LASTEXITCODE -ne 0) { throw 'V8 source extraction failed' }
        $v8Extracted = Join-Path $v8Stage ('rusty_v8-' + $origin.v8Commit)
        if (!(Test-Path -LiteralPath (Join-Path $v8Extracted 'Cargo.toml') -PathType Leaf)) { throw 'Unexpected V8 archive layout' }
        if (Test-Path -LiteralPath $v8Stable) { Remove-Item -LiteralPath $v8Stable -Recurse -Force }
        [IO.File]::WriteAllText((Join-Path $v8Extracted '.archive-sha256'), $origin.v8ArchiveSha256, $utf8)
        Move-Item -LiteralPath $v8Extracted -Destination $v8Stable
    } finally {
        if (Test-Path -LiteralPath $v8Stage) { Remove-Item -LiteralPath $v8Stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
$v8 = $v8Stable.Replace('\','/')
$cargo = $cargo.Replace($v8Pin,('v8 = { path = "' + $v8 + '" }')).Replace($sample,($sample + $lf + '    "ag-guardian-host",'))
Write-BuildInput (Join-Path $workspace 'Cargo.toml') $cargo
$hostDirectory = Join-Path $workspace $name
New-Item -ItemType Directory -Path (Join-Path $hostDirectory 'src') -Force | Out-Null
foreach ($file in @('Cargo.toml','src/main.rs','src/bootstrap.rs','src/offline_prompt_tests.rs')) {
    Sync-FileIfChanged (Join-Path $hostSource $file) (Join-Path $hostDirectory $file)
}
if ($SyncWorkspaceOnly) {
    Write-Host "Synced Guardian workspace: $workspace"
    return
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
Push-Location $workspace
try {
    $arguments = @("+$Toolchain",'build','--locked','--target',$target,'-p',$name)
    if ($Profile -eq 'Release') { $arguments += '--release' }
    if ($Offline) { $arguments += '--offline' }
    & cargo @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Native Guardian build failed' }
} finally { Pop-Location }
$built = Join-Path $resolvedTargetDir "$target/$($Profile.ToLowerInvariant())/$exe"
$identity = Read-HostIdentity $built
if ((Hash-File $lockPath) -cne $lockHash) { throw 'Cargo modified the pinned lockfile' }
foreach ($file in $hashes.Keys) {
    if ((Hash-File (Join-Path $root $file)) -cne $hashes[$file]) { throw "Guardian input changed during the build: $file" }
}
$manifest = [ordered]@{ version=$identity.version; protocol=$origin.protocol; upstreamCommit=$origin.commit;
    hostCommit=$origin.commit; policySourceCommit=$policy.commit; nativePolicySourceCommit=$origin.commit; repository=$origin.repository;
    profile=$Profile; toolchain=$Toolchain; compiler=$compiler; cargoVersion=$cargoVersion; target=$target;
    sourceSha256=$hashes; testSourceSha256=$testHashes; resolvedCargoLockSha256=$lockHash; v8Commit=$origin.v8Commit; v8ArchiveSha256=$origin.v8ArchiveSha256;
    binarySha256=(Hash-File $built); buildKey=$buildKey; builtAt=[DateTime]::UtcNow.ToString('O');
    cargoIncremental=$incremental; cargoTargetDir=$resolvedTargetDir; buildPathRemapping=$(if ($Profile -eq 'Release') { 1 } else { 0 }); buildOptions=$options; releaseOptions=$options }
foreach ($file in @('LICENSE','NOTICE')) {
    Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $output "UPSTREAM-$file") -Force
}
Copy-Item -LiteralPath $built -Destination (Join-Path $output $exe) -Force
$manifest | ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath (Join-Path $output 'SOURCE.json') -Encoding utf8
Write-Host "Ready native Guardian: $(Join-Path $output $exe)"
} finally {
    foreach ($entry in $savedEnv.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -LiteralPath ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
    }
}
