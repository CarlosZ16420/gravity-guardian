[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory, [string]$BuildRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$prefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in @($BuildRoot,$env:USERPROFILE,$env:CARGO_HOME)) {
    if (!$path) { continue }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
    foreach ($variant in @($full,$full.Replace('\','/'),$full.Replace('\','\\'))) { [void]$prefixes.Add($variant) }
}
$needles = @(foreach ($prefix in $prefixes) {
    foreach ($encoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)) {
        # Latin-1 decoding preserves the bytes, including NULs in UTF-16 strings.
        [Text.Encoding]::Latin1.GetString($encoding.GetBytes($prefix))
    }
})
$overlap = ($needles | ForEach-Object Length | Measure-Object -Maximum).Maximum
$scanned = 0
foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File -Force) {
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        $buffer = [byte[]]::new(256KB)
        $carry = ''
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $text = $carry + [Text.Encoding]::Latin1.GetString($buffer,0,$count)
            foreach ($needle in $needles) {
                if ($text.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Directory),$file.FullName)
                    throw "Personal build path embedded in release file: $relative"
                }
            }
            $carry = $text.Substring([Math]::Max(0,$text.Length-$overlap))
        }
    } finally { $stream.Dispose() }
    $scanned++
}
Write-Host "PASS release payload privacy ($scanned files scanned, no local build/profile paths)"
