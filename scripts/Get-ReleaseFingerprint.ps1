[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskPaths=(& git -c "safe.directory=$($taskRoot.Replace('\','/'))" -C $taskRoot ls-files --cached --others --exclude-standard -z) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate release inputs' }
$taskHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
try {
    foreach ($path in ($taskPaths.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)) {
        $taskHash.AppendData([Text.Encoding]::UTF8.GetBytes($path+[char]0))
        $full=Join-Path $taskRoot $path
        if (Test-Path -LiteralPath $full -PathType Leaf) { $taskHash.AppendData([IO.File]::ReadAllBytes($full)) }
        else { $taskHash.AppendData([Text.Encoding]::UTF8.GetBytes('<deleted>')) }
    }
    foreach ($entry in (Get-ChildItem Env: | Where-Object Name -match '^(RUST.*|CARGO_(PROFILE_.*|ENCODED_RUSTFLAGS|TARGET_DIR)|CFLAGS.*|CXXFLAGS.*|CC.*|CXX.*)$' | Sort-Object Name)) {
        $taskHash.AppendData([Text.Encoding]::UTF8.GetBytes($entry.Name+'='+$entry.Value+[char]0))
    }
    [Convert]::ToHexString($taskHash.GetHashAndReset()).ToLowerInvariant()
} finally { $taskHash.Dispose() }
