[CmdletBinding()]
param([switch]$PrintEnvironment, [string]$BuildRoot = (Split-Path $PSScriptRoot -Parent))

function Get-ReleasePathSettings([string]$Root) {
    $rules = [Collections.Generic.List[object]]::new()
    if ($env:USERPROFILE) { $rules.Add(@{from=[IO.Path]::GetFullPath($env:USERPROFILE);to='/build/user'}) }
    $rules.Add(@{from=[IO.Path]::GetFullPath($Root);to='/src/gravity-guardian'})
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    $rules.Add(@{from=[IO.Path]::GetFullPath($cargoHome);to='/cargo'})
    $rustFlags = [Collections.Generic.List[string]]::new()
    if ($env:CARGO_ENCODED_RUSTFLAGS) {
        foreach ($flag in $env:CARGO_ENCODED_RUSTFLAGS.Split([char]31)) { $rustFlags.Add($flag) }
    } elseif ($env:RUSTFLAGS) {
        # Cargo also splits RUSTFLAGS on whitespace; encoded flags preserve spaces.
        foreach ($flag in ($env:RUSTFLAGS -split '\s+' | Where-Object { $_ })) { $rustFlags.Add($flag) }
    }
    $msvcFlags = [Collections.Generic.List[string]]::new()
    $msvcFlags.Add('/experimental:deterministic')
    foreach ($rule in $rules) {
        foreach ($from in @($rule.from, $rule.from.Replace('\','/')) | Select-Object -Unique) {
            $rustFlags.Add('--remap-path-prefix='+$from+'='+$rule.to)
            $msvcFlags.Add('/pathmap:'+$from+'='+$rule.to)
        }
    }
    # cc-rs uses shlex when this flag is set. Escape backslashes inside quotes.
    $cFlags = ($msvcFlags | ForEach-Object { '"'+$_.Replace('\','\\').Replace('"','\"')+'"' }) -join ' '
    return @{
        environment = @{
            CARGO_ENCODED_RUSTFLAGS = $rustFlags -join [char]31
            CFLAGS = (($env:CFLAGS+' '+$cFlags).Trim())
            CXXFLAGS = (($env:CXXFLAGS+' '+$cFlags).Trim())
            CC_SHELL_ESCAPED_FLAGS = '1'
        }
        msvcArguments = @($msvcFlags.ToArray())
    }
}

if ($PrintEnvironment) { (Get-ReleasePathSettings $BuildRoot).environment | ConvertTo-Json -Compress }
