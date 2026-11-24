[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$taskRoot = Split-Path $PSScriptRoot -Parent
$taskViolations = [Collections.Generic.List[string]]::new()

$taskIgnoreDirs = @('.git', '.local', '.tools', '.research', 'artifacts', 'bin', 'obj', 'effective-codex')
$taskForbiddenPatterns = @(
    @{ Name = 'Hardcoded Windows profile path'; Regex = '[A-Z]:[\\/]Users[\\/]+(?!Public[\\/]|Default[\\/])[\w.-]+' },
    @{ Name = 'Private key material'; Regex = '-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----' },
    @{ Name = 'Access token'; Regex = '\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})\b' }
)

$taskSelfPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

function Test-IgnoredDirectory([string]$FullPath) {
    $rel = $FullPath.Substring([IO.Path]::GetFullPath($taskRoot).Length).TrimStart('\', '/')
    $parts = $rel -split '[\\/]'
    foreach ($p in $parts) {
        if ($taskIgnoreDirs -contains $p) { return $true }
    }
    return $false
}

# 1. Forbidden directories/files check
foreach ($forbiddenDir in @('.research')) {
    $candidate = Join-Path $taskRoot $forbiddenDir
    if (Test-Path -LiteralPath $candidate) {
        $taskViolations.Add("Forbidden directory present: $forbiddenDir")
    }
}

# 2. Check all files under public-edition (excluding generated/ignored dirs)
$taskTextExts = @('.cs', '.cpp', '.h', '.rc', '.manifest', '.csproj', '.ps1', '.psm1', '.mjs', '.js', '.json', '.md', '.txt', '.yml', '.yaml', '.toml', '.rs', '.patch', '.xml', '.config')
$taskFiles = Get-ChildItem -LiteralPath $taskRoot -Recurse -File -Force | Where-Object { !(Test-IgnoredDirectory $_.FullName) }

foreach ($file in $taskFiles) {
    $full = [IO.Path]::GetFullPath($file.FullName)
    $rel = $full.Substring([IO.Path]::GetFullPath($taskRoot).Length).TrimStart('\', '/')
    if ($rel -match '\.jsonl$' -and $rel -notmatch '^tests[\\/]fixtures[\\/]') {
        $taskViolations.Add("Unexpected JSONL log/data file in public tree: $rel")
    }
    if ($rel -match '(?:^|[\\/])(?:auth|approval|panel-settings)\.json$') {
        $taskViolations.Add("Personal runtime config file in public tree: $rel")
    }
    if ($full -eq $taskSelfPath) { continue }
    if ($taskTextExts -contains $file.Extension.ToLowerInvariant() -or $file.Name -in @('LICENSE', 'NOTICE', '.gitignore', '.gitattributes')) {
        $content = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        foreach ($rule in $taskForbiddenPatterns) {
            if ($content -match $rule.Regex) {
                $taskViolations.Add("$($rule.Name) matched in $rel")
            }
        }
    }
}

# 3. Verify LICENSE and NOTICE exist
foreach ($req in @('LICENSE', 'NOTICE', 'plugin/pricing.json', 'plugin/update-config.json')) {
    if (!(Test-Path -LiteralPath (Join-Path $taskRoot $req) -PathType Leaf)) {
        $taskViolations.Add("Missing required public release file: $req")
    }
}

if ($taskViolations.Count -gt 0) {
    foreach ($v in $taskViolations) { Write-Host ("HYGIENE VIOLATION: " + $v) -ForegroundColor Red }
    throw "Public hygiene check failed with $($taskViolations.Count) violation(s)."
}

Write-Host "PASS public hygiene check ($($taskFiles.Count) source files scanned, 0 violations)"
