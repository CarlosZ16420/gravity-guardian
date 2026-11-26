[CmdletBinding()]
param([string]$Directory='', [string]$Repository='', [switch]$Publish, [switch]$ValidateOnly)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
if (!$Directory) { $Directory=Join-Path $taskRoot 'artifacts' }
$Directory=(Resolve-Path -LiteralPath $Directory).Path
$accepted=Get-Content -LiteralPath (Join-Path $Directory 'release-acceptance.json') -Raw | ConvertFrom-Json
$required=@('Preflight and service tests','Build','Native prompt','Installation','Package','Update and rollback','Standalone and Lite','Portable','Zero CLI trace')
if ($accepted.result -cne 'success' -or $accepted.sourceDirty -ne $false -or $accepted.commit -notmatch '^[a-f0-9]{40}$' -or
    @($accepted.steps).Count -ne $required.Count -or @($required | Where-Object { $_ -cnotin $accepted.steps.name }).Count -or
    @($accepted.steps | Where-Object { $_.result -cne 'success' }).Count) { throw 'Expected complete acceptance from a committed source tree' }
$version=[string]$accepted.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version' }
$names=@("gravity-guardian-$version-windows-x64.zip","gravity-guardian-$version-lite-windows-x64.zip","gravity-guardian-$version-portable-windows-x64.zip",'checksums.sha256','release-manifest.json','release-build-info.json')
if ($accepted.assets.Count -ne $names.Count) { throw 'Unexpected accepted asset count' }
$assets=@{}
foreach ($name in $names) {
    $entry=@($accepted.assets | Where-Object { ($_.path.Replace('\','/').Split('/')[-1]) -ceq $name })
    $file=Get-Item -LiteralPath (Join-Path $Directory $name)
    $hash=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    if ($entry.Count -ne 1 -or $hash -cne $entry[0].sha256 -or $file.Length -ne $entry[0].sizeBytes) { throw "Accepted asset changed: $name" }
    $assets[$name]=@{path=$file.FullName;digest='sha256:'+$hash;size=$file.Length}
}
Write-Host "PASS complete acceptance and six asset hashes for $($accepted.commit)"
if ($ValidateOnly) { return }
if (!$Repository) { $Repository=(Get-Content -LiteralPath (Join-Path $taskRoot 'plugin/update-config.json') -Raw | ConvertFrom-Json).repository }
if ($Repository -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid GitHub repository' }
function Invoke-Gh {
    & gh @args
    if ($LASTEXITCODE -ne 0) { throw "GitHub command failed: $($args[0]) ($LASTEXITCODE). The existing draft can be resumed." }
}
$tag="v$version"
$releases=Invoke-Gh api "repos/$Repository/releases" --paginate | ConvertFrom-Json
$draft=@($releases | Where-Object { $_.tag_name -ceq $tag })
if ($draft.Count -eq 0) {
    $notes=Join-Path $env:TEMP ('guardian-release-'+[Guid]::NewGuid().ToString('N')+'.md')
    $body=Invoke-Gh api "repos/$Repository/contents/docs/release-$version.md?ref=$($accepted.commit)" --jq '.content'
    $text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($body -join '')))
    $text=[regex]::Replace($text,'\]\(([^):#]+\.md)(#[^)]*)?\)', { param($match) '](https://github.com/'+$Repository+'/blob/'+$accepted.commit+'/docs/'+$match.Groups[1].Value+$match.Groups[2].Value+')' })
    try {
        [IO.File]::WriteAllText($notes,$text,[Text.UTF8Encoding]::new($false))
        Invoke-Gh release create $tag --repo $Repository --target $accepted.commit --title "Gravity Guardian $tag" --notes-file $notes --draft
    } finally { [IO.File]::Delete($notes) }
    $draft=@(Invoke-Gh api "repos/$Repository/releases" --paginate | ConvertFrom-Json | Where-Object { $_.tag_name -ceq $tag })
}
if ($draft.Count -ne 1 -or !$draft[0].draft -or $draft[0].target_commitish -cne $accepted.commit) { throw 'Release already published or draft target differs; nothing was overwritten' }
$id=$draft[0].id
$missing=@($names | Where-Object { $_ -cnotin $draft[0].assets.name } | ForEach-Object { $assets[$_].path })
if ($missing.Count) { Invoke-Gh release upload $tag --repo $Repository @missing }
# Draft tags may not exist yet. Always read and publish the known REST ID.
$remote=Invoke-Gh api "repos/$Repository/releases/$id" | ConvertFrom-Json
if ($remote.assets.Count -ne $names.Count) { throw 'Unexpected remote attachment count' }
foreach ($asset in $remote.assets) {
    $expected=$assets[$asset.name]
    if (!$expected -or $asset.state -cne 'uploaded' -or $asset.digest -cne $expected.digest -or $asset.size -ne $expected.size) { throw "Remote attachment differs: $($asset.name)" }
}
Write-Host "PASS verified draft: $($remote.html_url)"
if ($Publish) {
    # target_commitish cannot move an existing tag. Resolve it before making a draft public.
    $tagQuery = & {
        $ErrorActionPreference='Continue'
        $output = & gh api "repos/$Repository/git/ref/tags/$tag" --include 2>&1
        @{output=@($output);exitCode=$LASTEXITCODE}
    }
    if ($tagQuery.exitCode -ne 0) {
        $statuses=[regex]::Matches(($tagQuery.output -join "`n"),'(?m)^HTTP/\S+\s+(\d{3})(?:\s|$)')
        if (!$statuses.Count -or $statuses[$statuses.Count-1].Groups[1].Value -cne '404') {
            throw 'Cannot verify release tag; draft was not published'
        }
    } else {
        $existingTarget=Invoke-Gh api "repos/$Repository/commits/$tag" --jq '.sha'
        if ($existingTarget -cne $accepted.commit) { throw 'Existing release tag target differs; draft was not published' }
    }
    Invoke-Gh api --method PATCH "repos/$Repository/releases/$id" -F draft=false -f make_latest=true --jq '.html_url'
    $published=Invoke-Gh api "repos/$Repository/releases/$id" | ConvertFrom-Json
    $target=Invoke-Gh api "repos/$Repository/commits/$tag" --jq '.sha'
    if ($published.draft -or $target -cne $accepted.commit) { throw 'Published release target differs' }
}
