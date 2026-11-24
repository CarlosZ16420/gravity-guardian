[CmdletBinding()]
param([Parameter(Mandatory)][string]$PluginDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskPlugin=[IO.Path]::GetFullPath($PluginDirectory)
$taskHooks=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $taskPlugin 'hooks.json') -Raw|ConvertFrom-Json
$taskCases=@(
    @{event='PreInvocation';handler=$taskHooks.'codex-approval'.PreInvocation[0];input='{"lastUserInput":"normal chat message"}'},
    @{event='PreToolUse';handler=$taskHooks.'codex-approval'.PreToolUse[0].hooks[0];input='invalid-json';decision='deny'},
    @{event='PostToolUse';handler=$taskHooks.'codex-approval'.PostToolUse[0].hooks[0];input='{"conversationId":"hook-launch-test","stepIdx":0,"toolCall":{"name":"hook-launch-test","args":{}}}'},
    @{event='SessionStart';handler=$taskHooks.'codex-approval'.SessionStart[0];input='{"conversationId":"hook-launch-test"}'}
)
foreach($taskCase in $taskCases){
    # Execute the actual shipped command through Windows' shell from the plugin root.
    # Invalid review JSON exercises the deny wrapper without invoking the model or executing a tool.
    $taskStart=[Diagnostics.ProcessStartInfo]::new()
    $taskStart.FileName=$env:ComSpec
    $taskStart.Arguments='/D /S /C '+$taskCase.handler.command
    $taskStart.WorkingDirectory=$taskPlugin
    $taskStart.UseShellExecute=$false
    $taskStart.CreateNoWindow=$true
    $taskStart.RedirectStandardInput=$true
    $taskStart.RedirectStandardOutput=$true
    $taskStart.RedirectStandardError=$true
    $taskProcess=[Diagnostics.Process]::Start($taskStart)
    try{
        $taskOutput=$taskProcess.StandardOutput.ReadToEndAsync()
        $taskError=$taskProcess.StandardError.ReadToEndAsync()
        $taskProcess.StandardInput.Write($taskCase.input)
        $taskProcess.StandardInput.Close()
        if(!$taskProcess.WaitForExit(10000)){$taskProcess.Kill($true);throw ($taskCase.event+' command did not finish')}
        $taskStdout=$taskOutput.GetAwaiter().GetResult()
        $taskStderr=$taskError.GetAwaiter().GetResult()
        if($taskProcess.ExitCode -ne 0){throw ($taskCase.event+' command failed: '+$taskStderr)}
        $taskResult=$taskStdout|ConvertFrom-JsonHashtable
        if($taskCase.decision){
            if($taskResult.decision -ne $taskCase.decision){throw 'Invalid review input did not produce a JSON deny'}
        }elseif($taskResult.Count -ne 0){throw ($taskCase.event+' did not return an empty JSON object')}
        Write-Host ('PASS '+$taskCase.event+' shipped Windows hook command')
    }finally{$taskProcess.Dispose()}
}
