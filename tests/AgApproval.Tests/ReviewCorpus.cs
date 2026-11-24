using AgApproval;
using System.Text;
using System.Text.Json.Nodes;

public static class ReviewCorpus
{
    public static async Task<string> PrepareAsync(string logs,string output,string policyHash)
    {
        var sessions = (Environment.GetEnvironmentVariable("AG_APPROVAL_REPLAY_SESSIONS") ?? "")
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (sessions.Length == 0)
            throw new InvalidOperationException("Set AG_APPROVAL_REPLAY_SESSIONS to the comma-separated archived session IDs.");
        output=Path.GetFullPath(output);Directory.CreateDirectory(output);
        var contexts=new Dictionary<string,(JsonObject Input,string File,int Line)>();var completed=new List<JsonObject>();
        foreach(var file in Directory.GetFiles(logs,"*.jsonl").Order())
        {
            int line=0;foreach(var raw in File.ReadLines(file))
            {
                line++;if(string.IsNullOrWhiteSpace(raw))continue;var row=JsonNode.Parse(raw)!.AsObject();
                var id=Json.Text(row,"requestId");if(id==null)continue;
                if(Json.Text(row,"event")=="review_context"&&row["reviewInput"] is JsonObject input&&Json.Text(input,"schema_version")=="1.0")contexts[id]=(input,file,line);
                if(Json.Text(row,"event")=="review_completed"&&Json.Text(row,"status")=="denied"&&sessions.Contains(Json.Text(row,"conversationId"))&&
                    DateTimeOffset.Parse(Json.Text(row,"at")!)<=DateTimeOffset.Parse("2026-11-04T10:05:45Z"))completed.Add(row);
            }
        }
        var manifest=new JsonArray();
        foreach(var row in completed)
        {
            var assessment=JsonNode.Parse(Json.Text(row,"assessmentText")!)!;if(Json.Text(assessment,"outcome")!="deny")continue;
            var id=Json.Text(row,"requestId")!;if(!contexts.TryGetValue(id,out var source))throw new InvalidDataException("Missing archived denied input "+id);
            if(Json.Text(row,"policyHash")!=policyHash)throw new InvalidDataException("Historical policy differs from configured fixed policy");
            var legacy=source.Input;var converted=HistoricalReplay.ConvertLegacy(legacy,policyHash);var action=legacy["planned_action"]!;
            var oldPath=Path.Combine(output,id+".v1.json");var newPath=Path.Combine(output,id+".v2.json");
            // Retain the complete archived input. No further minimization of conversation evidence.
            await File.WriteAllTextAsync(oldPath,legacy.ToJsonString(Json.PromptOptions),new UTF8Encoding(false));
            await File.WriteAllTextAsync(newPath,converted.ToJsonString(Json.PromptOptions),new UTF8Encoding(false));
            var users=legacy["transcript"]!.AsArray().Where(r=>r!["is_authenticated_user_input"]!.GetValue<bool>()).ToArray();
            manifest.Add(new JsonObject{["requestId"]=id,["conversationId"]=Json.Text(action,"conversationId"),["step"]=action["stepIdx"]!.DeepClone(),["tool"]=Json.Text(action["toolCall"],"name"),
                ["originalAt"]=row["at"]!.DeepClone(),["sourceFile"]=source.File,["sourceLine"]=source.Line,["originalAssessment"]=assessment.DeepClone(),["policyHash"]=policyHash,
                ["userRecords"]=users.Length,["lastUserStep"]=users.Last()!["step_index"]!.DeepClone(),["v1Path"]=oldPath,["v2Path"]=newPath,["v1Hash"]=Json.Hash(legacy.ToJsonString(Json.PromptOptions)),["v2Hash"]=Json.Hash(converted.ToJsonString(Json.PromptOptions)),
                ["archivedRecords"]=legacy["transcript"]!.AsArray().Count,["newlyOmittedRecords"]=0,["actionExecuted"]=false});
        }
        var path=Path.Combine(output,"manifest.json");await File.WriteAllTextAsync(path,manifest.ToJsonString(Json.PromptOptions));
        return Json.Encode(new{manifestPath=path,originalModelDenials=manifest.Count,newlyOmittedRecords=0,actionExecuted=false,byTool=manifest.GroupBy(r=>Json.Text(r,"tool")).ToDictionary(g=>g.Key!,g=>g.Count())});
    }
    public static async Task RunAsync(Settings settings,string manifestPath)
    {
        var manifest=JsonNode.Parse(await File.ReadAllTextAsync(manifestPath))!.AsArray();var policy=new Policy(settings.PolicyDirectory);
        var output=Path.Combine(Path.GetDirectoryName(Path.GetFullPath(manifestPath))!,"runs",DateTime.UtcNow.ToString("yyyyMMdd-HHmmss"));Directory.CreateDirectory(output);
        settings.DataDirectory=output;
        // Fixed corpus: one old and one v2 review per record, sequential. Never sample until allowed.
        foreach(var entry in manifest)
        foreach(var version in new[]{"v1","v2"})
        {
            var prompt=await File.ReadAllTextAsync(Json.Text(entry,version+"Path")!);
            if(Json.Hash(prompt)!=Json.Text(entry,version+"Hash"))throw new InvalidDataException("Corpus integrity changed");
            if(Json.Text(entry,"policyHash")!=policy.Hash)throw new InvalidDataException("Corpus policy changed");
            var doc=JsonNode.Parse(prompt)!;var action=doc["planned_action"]!;var id=Guid.NewGuid().ToString("N");
            var input=new ReviewInput(id,Json.Text(doc,"action_sha256")!,Json.Text(action,"conversationId")!,Json.Text(action["toolCall"],"name")!,Json.Text(action,"cwd")!,prompt,Json.Hash(prompt));
            Console.WriteLine(Json.Encode(new{phase="started",originalRequestId=Json.Text(entry,"requestId"),version,output,actionExecuted=false}));
            GateResponse result;string? text=null;using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(90));
            try{text=await new CodexReviewer(settings,policy).ReviewAsync(input,deadline.Token);result=policy.Apply(text,id,input.Hash);}
            catch(OperationCanceledException){result=GateResponse.NeedsHuman(id,input.Hash,"Corpus review timeout","review_timeout");}
            catch(Exception e){result=GateResponse.NeedsHuman(id,input.Hash,e.Message);}
            var record=new{originalRequestId=Json.Text(entry,"requestId"),version,policyHash=policy.Hash,adapterInstructionHash=version=="v1"?Json.Hash(Json.Text(doc,"integration")!):ReviewAdapter.Hash,model=settings.Model,effort=settings.Effort,result,assessment=text,actionExecuted=false};
            await File.WriteAllTextAsync(Path.Combine(output,Json.Text(entry,"requestId")+"."+version+".json"),Json.Encode(record));Console.WriteLine(Json.Encode(record));
            if(result.Decision=="force_ask"){Console.WriteLine("Corpus stopped on technical failure; no remaining calls or business actions were attempted.");return;}
        }
    }
    public static async Task<string> ValidateBindingsAsync(string manifestPath)
    {
        var manifest=JsonNode.Parse(await File.ReadAllTextAsync(manifestPath))!.AsArray();
        var output=Path.Combine(Path.GetDirectoryName(Path.GetFullPath(manifestPath))!,"binding-fixtures");Directory.CreateDirectory(output);
        var methods=new Dictionary<string,int>();var failures=new List<object>();
        foreach(var entry in manifest)
        {
            var doc=JsonNode.Parse(await File.ReadAllTextAsync(Json.Text(entry,"v1Path")!))!;var action=doc["planned_action"]!;
            var text=new StringBuilder();int position=1;
            foreach(var record in doc["transcript"]!.AsArray())
            {
                int target=record!["native_position"]!.GetValue<int>();while(position<target){text.Append('\n');position++;}
                text.Append(record.ToJsonString()).Append('\n');position++;
            }
            var path=Path.Combine(output,Json.Text(entry,"requestId")+".jsonl");await File.WriteAllTextAsync(path,text.ToString());
            try{
                var bound=await NativeTranscript.ReadAsync(path,action["stepIdx"]!.GetValue<int>(),action["toolCall"]!.AsObject(),default);
                methods[bound.Method]=methods.GetValueOrDefault(bound.Method)+1;
            }catch(Exception e){failures.Add(new{requestId=Json.Text(entry,"requestId"),reason=e.Message});}
        }
        var report=Json.Encode(new{cases=manifest.Count,bound=methods.Values.Sum(),methods,failures,modelCalled=false,actionExecuted=false});
        await File.WriteAllTextAsync(Path.Combine(output,"summary.json"),report);
        if(failures.Count>0)throw new InvalidDataException(report);
        return report;
    }
}
