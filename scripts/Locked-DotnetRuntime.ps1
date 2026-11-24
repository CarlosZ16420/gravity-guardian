function Get-LockedDotnetRuntime {
    $lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dotnet-runtime.lock.json') -Raw | ConvertFrom-Json
    $version = [string]$lock.version
    $url = [uri]$lock.url
    $sha256 = ([string]$lock.sha256).ToLowerInvariant()
    $archiveName = "dotnet-runtime-$version-win-x64.zip"
    if ($version -notmatch '^10\.0\.[0-9]+$' -or !$url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or
        $url.Segments[-1] -cne $archiveName -or $sha256 -notmatch '^[a-f0-9]{64}$') {
        throw 'Invalid Windows x64 .NET runtime lock'
    }

    $cache = Join-Path (Split-Path $PSScriptRoot -Parent) '.local/runtime-downloads'
    $archivePath = Join-Path $cache $archiveName
    if (!(Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $sha256) {
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $download = Join-Path $cache ([Guid]::NewGuid().ToString('N') + '.download')
        try {
            Write-Host "Downloading locked .NET $version Windows x64 runtime"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $download -TimeoutSec 120 -MaximumRetryCount 2 -RetryIntervalSec 2
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $sha256) {
                throw "SHA-256 mismatch for the locked .NET runtime archive: $archiveName"
            }
            [IO.File]::Move($download, $archivePath, $true)
        } finally {
            [IO.File]::Delete($download)
        }
    }

    return @{ version = $version; archivePath = $archivePath; sha256 = $sha256 }
}

function Get-LockedDotnetRuntimeFiles([IO.Compression.ZipArchive]$Archive, [string]$Version) {
    $rootFiles = @('dotnet.exe', 'LICENSE.txt', 'ThirdPartyNotices.txt')
    $hostPrefix = "host/fxr/$Version/"
    $frameworkPrefix = "shared/Microsoft.NETCore.App/$Version/"
    $files = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Archive.Entries) {
        if (!$entry.Name) { continue }
        $path = $entry.FullName
        if ($path -cin $rootFiles -or $path.StartsWith($hostPrefix, [StringComparison]::Ordinal) -or
            $path.StartsWith($frameworkPrefix, [StringComparison]::Ordinal)) {
            if ($path -match '(^|/)\.{1,2}(/|$)|[\\:]|\.pdb$') {
                throw "Unexpected file in the locked .NET runtime: $path"
            }
            $files.Add($path, $entry)
        }
    }
    foreach ($required in $rootFiles + @("${hostPrefix}hostfxr.dll", "${frameworkPrefix}coreclr.dll", "${frameworkPrefix}Microsoft.NETCore.App.runtimeconfig.json")) {
        if (!$files.ContainsKey($required)) { throw "Missing file in the locked .NET runtime: $required" }
    }
    return ,$files
}
