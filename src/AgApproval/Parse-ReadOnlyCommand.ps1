# Parse only. Proposed commands are never invoked by this program.
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
function Convert-CommandAst([string]$source){
    try {
        if($source.Length -gt 16384){throw 'command_too_large'}
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.DynamicParamBlock -or $ast.EndBlock.Statements.Count -ne 1 -or $ast.EndBlock.Traps.Count){throw 'unsupported_script'}
        $pipeline=$ast.EndBlock.Statements[0]
        if($pipeline -isnot [Management.Automation.Language.PipelineAst] -or $pipeline.Background){throw 'unsupported_pipeline'}
        $commands=@()
        foreach($command in $pipeline.PipelineElements){
            if($command -isnot [Management.Automation.Language.CommandAst] -or $command.Redirections.Count -or $command.InvocationOperator -ne 'Unknown'){throw 'unsupported_command'}
            $elements=@($command.CommandElements)
            if($elements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $elements[0].StringConstantType -ne 'BareWord'){throw 'dynamic_command'}
            $arguments=@()
            for($index=1;$index -lt $elements.Count;$index++){
                $element=$elements[$index]
                if($element -is [Management.Automation.Language.CommandParameterAst]){
                    if($element.Argument){throw 'attached_parameter'}
                    $arguments+=@{parameter=$element.ParameterName;values=@()};continue
                }
                $values=@()
                $literals=if($element -is [Management.Automation.Language.ArrayLiteralAst]){@($element.Elements)}else{@($element)}
                foreach($literal in $literals){
                    if($literal -is [Management.Automation.Language.StringConstantExpressionAst]){$values+=@([string]$literal.Value)}
                    elseif($literal -is [Management.Automation.Language.ConstantExpressionAst] -and ($literal.Value -is [int] -or $literal.Value -is [long])){$values+=@($literal.Value.ToString([Globalization.CultureInfo]::InvariantCulture))}
                    else{throw 'non_literal_argument'}
                }
                $arguments+=@{parameter=$null;values=@($values)}
            }
            $commands+=@{name=[string]$elements[0].Value;arguments=@($arguments)}
        }
        return (@{valid=$true;commands=@($commands)}|ConvertTo-Json -Depth 12 -Compress)
    }catch{
        return (@{valid=$false;reason='syntax_not_in_literal_subset'}|ConvertTo-Json -Compress)
    }
}
if($env:AG_PERSISTENT_PARSER -eq '1'){
    while($null -ne ($line=[Console]::In.ReadLine())){
        try{$decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))}
        catch{[Console]::Out.WriteLine('{"valid":false,"reason":"invalid_frame"}');[Console]::Out.Flush();continue}
        [Console]::Out.WriteLine((Convert-CommandAst $decoded))
        [Console]::Out.Flush()
    }
}else{
    [Console]::Out.WriteLine((Convert-CommandAst ([Console]::In.ReadToEnd())))
}
