$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskFixture = Join-Path $taskRoot ('.local/privacy-test/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskFixture -Force | Out-Null
$taskFile = Join-Path $taskFixture 'payload.bin'
$taskPrefix = [IO.Path]::GetFullPath($taskRoot)
foreach ($taskEncoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)) {
    foreach ($taskText in @($taskPrefix,$taskPrefix.ToUpperInvariant(),$taskPrefix.Replace('\','\\'))) {
        # Split a forbidden path over the scanner's read boundary.
        $taskBytes = $taskEncoding.GetBytes($taskText)
        $taskPayload = [byte[]]::new(256KB - 3 + $taskBytes.Length)
        [Array]::Copy($taskBytes,0,$taskPayload,256KB - 3,$taskBytes.Length)
        [IO.File]::WriteAllBytes($taskFile,$taskPayload)
        $taskFailure = $null
        try { & (Join-Path $PSScriptRoot 'Check-ReleasePrivacy.ps1') -Directory $taskFixture -BuildRoot $taskRoot }
        catch { $taskFailure = $_.Exception.Message }
        if ($taskFailure -notlike 'Personal build path embedded*') { throw 'Release scanner missed an encoded build path across the buffer boundary' }
    }
}
[IO.File]::WriteAllText($taskFile,'/src/gravity-guardian/native/main.rs /cargo/registry/source.rs build/native-target')
& (Join-Path $PSScriptRoot 'Check-ReleasePrivacy.ps1') -Directory $taskFixture -BuildRoot $taskRoot
Write-Host 'PASS release privacy rejects UTF-8, UTF-16, JSON escapes, case variants and split paths; neutral build paths pass'
