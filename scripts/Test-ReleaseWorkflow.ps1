$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $taskRoot ('.local/release-workflow-test/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$commit='1'*40
$version='9.9.9'
$names=@("gravity-guardian-$version-windows-x64.zip","gravity-guardian-$version-lite-windows-x64.zip","gravity-guardian-$version-portable-windows-x64.zip",'checksums.sha256','release-manifest.json','release-build-info.json')
$assets=@(foreach ($name in $names) {
    $path=Join-Path $fixture $name
    [IO.File]::WriteAllText($path,'synthetic upload fixture '+$name)
    @{path='artifacts/'+$name;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();sizeBytes=(Get-Item -LiteralPath $path).Length}
})
$steps=@('Preflight and service tests','Build','Native prompt','Installation','Package','Update and rollback','Standalone and Lite','Portable','Zero CLI trace') | ForEach-Object { @{name=$_;result='success'} }
$proof=@{commit=$commit;version=$version;sourceDirty=$false;result='success';steps=@($steps);assets=$assets}
$proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture 'release-acceptance.json') -Encoding utf8
$global:GravityReleaseWorkflowTestMock=@{release=$null;uploads=0;publishes=0;creates=0;tagMode='correct'}
function gh {
    $global:LASTEXITCODE=0
    $argv=@($args)
    $endpoint=@($argv | Where-Object { $_ -is [string] -and $_.StartsWith('repos/') }) | Select-Object -First 1
    if ($argv[0] -eq 'api') {
        if ($endpoint -match '/releases/tags/') { throw 'Drafts must be accessed by REST ID' }
        if ($endpoint -eq 'repos/fixture/project/releases') {
            $items=@(); if ($global:GravityReleaseWorkflowTestMock.release) { $items=@($global:GravityReleaseWorkflowTestMock.release) }
            ConvertTo-Json -InputObject $items -Depth 8; return
        }
        if ($endpoint -like 'repos/fixture/project/contents/*') {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('# Synthetic release')); return
        }
        if ($endpoint -eq 'repos/fixture/project/releases/42') {
            if ($argv -contains 'PATCH') { $global:GravityReleaseWorkflowTestMock.release.draft=$false; $global:GravityReleaseWorkflowTestMock.publishes++; 'https://example.invalid/release'; return }
            $global:GravityReleaseWorkflowTestMock.release | ConvertTo-Json -Depth 8; return
        }
        if ($endpoint -eq 'repos/fixture/project/git/ref/tags/v9.9.9') {
            switch ($global:GravityReleaseWorkflowTestMock.tagMode) {
                'missing' { $global:LASTEXITCODE=1; "HTTP/2.0 404 Not Found`n{}"; return }
                'forbidden' { $global:LASTEXITCODE=1; "HTTP/2.0 403 Forbidden`n{}"; return }
                'server-error' { $global:LASTEXITCODE=1; "HTTP/2.0 500 Server Error`n{}"; return }
                'network' { $global:LASTEXITCODE=1; 'Network failure mentioning 404 without HTTP status'; return }
                default { "HTTP/2.0 200 OK`n{}"; return }
            }
        }
        if ($endpoint -eq 'repos/fixture/project/commits/v9.9.9') {
            if ($global:GravityReleaseWorkflowTestMock.tagMode -eq 'mismatch') { '2'*40 } else { $commit }; return
        }
    }
    if ($argv[0] -eq 'release' -and $argv[1] -eq 'create') {
        $global:GravityReleaseWorkflowTestMock.creates++
        $global:GravityReleaseWorkflowTestMock.release=@{id=42;draft=$true;target_commitish=$commit;tag_name='v9.9.9';assets=@();html_url='https://example.invalid/draft'}
        'https://example.invalid/draft'; return
    }
    if ($argv[0] -eq 'release' -and $argv[1] -eq 'upload') {
        $global:GravityReleaseWorkflowTestMock.uploads++
        foreach ($file in ($argv | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $item=Get-Item -LiteralPath $file
            $global:GravityReleaseWorkflowTestMock.release.assets+=@{name=$item.Name;state='uploaded';size=$item.Length;digest='sha256:'+(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()}
        }
        return
    }
    throw 'Unexpected GitHub operation in release test'
}
& (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -Repository fixture/project
& (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -Repository fixture/project -Publish
if ($global:GravityReleaseWorkflowTestMock.creates -ne 1 -or $global:GravityReleaseWorkflowTestMock.uploads -ne 1 -or $global:GravityReleaseWorkflowTestMock.publishes -ne 1) { throw 'Draft resume repeated uploads or publication' }
$failure=$null
try { & (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -Repository fixture/project -Publish } catch { $failure=$_.Exception.Message }
if ($failure -notlike 'Release already published*' -or $global:GravityReleaseWorkflowTestMock.publishes -ne 1) { throw 'Published release was not protected from overwrite' }
foreach ($mode in @('mismatch','forbidden','server-error','network')) {
    $global:GravityReleaseWorkflowTestMock.release.draft=$true
    $global:GravityReleaseWorkflowTestMock.tagMode=$mode
    $failure=$null
    try { & (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -Repository fixture/project -Publish } catch { $failure=$_.Exception.Message }
    if (!$failure -or !$global:GravityReleaseWorkflowTestMock.release.draft -or $global:GravityReleaseWorkflowTestMock.publishes -ne 1) { throw "Unsafe tag query published a release: $mode" }
}
$global:GravityReleaseWorkflowTestMock.tagMode='missing'
& (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -Repository fixture/project -Publish
if ($global:GravityReleaseWorkflowTestMock.release.draft -or $global:GravityReleaseWorkflowTestMock.publishes -ne 2) { throw 'Confirmed missing tag did not publish' }
Write-Host 'PASS R07 existing wrong tag, permission/server/network errors stay draft; correct and confirmed absent tags publish'
[IO.File]::AppendAllText((Join-Path $fixture $names[0]),'corrupt')
$failure=$null
try { & (Join-Path $PSScriptRoot 'Publish-Release.ps1') -Directory $fixture -ValidateOnly } catch { $failure=$_.Exception.Message }
if ($failure -notlike 'Accepted asset changed*') { throw 'Modified attachment was not rejected' }
Write-Host 'PASS release drafts use REST IDs, resume without duplicate uploads, verify hashes, and refuse published overwrites'
$resume=Join-Path $fixture 'stale'
New-Item -ItemType Directory -Path $resume | Out-Null
@{fingerprint='stale';commit=$commit} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resume 'release-state.json') -Encoding utf8
$failure=$null
try { & (Join-Path $PSScriptRoot 'Run-Release.ps1') -EvidenceDirectory $resume -Resume } catch { $failure=$_.Exception.Message }
if ($failure -notlike 'Release inputs changed*') { throw 'Stale release results were not rejected' }
Write-Host 'PASS release resume refuses results from different source inputs'
Remove-Variable -Name GravityReleaseWorkflowTestMock -Scope Global
$global:LASTEXITCODE=0
