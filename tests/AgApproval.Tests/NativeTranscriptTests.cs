using AgApproval;
using System.Text.Json.Nodes;

public static class NativeTranscriptTests
{
    // Freeze each historical request at its original frontier; never execute its tool.
    public static async Task<int> ReplayAsync(string config,string log,string output)
    {
        output=Path.GetFullPath(output);
        if(Directory.Exists(output))throw new InvalidOperationException("Replay output already exists");
        Directory.CreateDirectory(output);
        var settings=Settings.Load(config);settings.EnableNativeState=false;
        settings.TranscriptRoots=[Path.Combine(output,"brain")];
        var results=new JsonArray();
        foreach(var line in await File.ReadAllLinesAsync(log))
        {
            var entry=JsonNode.Parse(line)!;
            if(Json.Text(entry,"event")!="review_received")continue;
            var payload=entry["payload"]!.DeepClone();var step=payload["stepIdx"]!.GetValue<int>();
            var source=await File.ReadAllLinesAsync(Json.Text(payload,"transcriptPath")!);
            var frozen=source.Where(s=>!string.IsNullOrWhiteSpace(s)).TakeWhile(s=>JsonNode.Parse(s)!["step_index"]!.GetValue<int>()<step);
            var path=Path.Combine(settings.TranscriptRoots[0],Json.Text(payload,"conversationId")!,".system_generated","logs","transcript_full.jsonl");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);await File.WriteAllTextAsync(path,string.Join("\n",frozen)+"\n");
            payload["transcriptPath"]=path;
            var result=new JsonObject{["requestId"]=Json.Text(entry,"requestId"),["step"]=step,["tool"]=Json.Text(payload["toolCall"],"name")};
            try
            {
                var input=await ReviewContext.BuildAsync(payload,settings,default);
                if(settings.ReviewerBackend=="NativeGuardian")_=GuardianFacts.Build(input,settings,5000);
                var doc=JsonNode.Parse(input.Prompt)!;
                result["valid"]=true;result["bindingMethod"]=Json.Text(doc["native_binding"],"binding_method");
            }
            catch(Exception e){result["valid"]=false;result["error"]=e.Message;}
            results.Add(result);
        }
        var report=new JsonObject{["cases"]=results.Count,["passed"]=results.Count(r=>r!["valid"]!.GetValue<bool>()),["modelCalled"]=false,["actionExecuted"]=false,["results"]=results};
        await File.WriteAllTextAsync(Path.Combine(output,"results.json"),report.ToJsonString(Json.PromptOptions));
        Console.WriteLine(report.ToJsonString());return report["passed"]!.GetValue<int>()==results.Count&&results.Count>0?0:1;
    }

    public static async Task RunAsync(string scratch,Func<string,Func<Task>,Task> test)
    {
        var path=Path.Combine(scratch,"native-transcript-2.32.jsonl");
        JsonObject Call(string name,JsonObject? args=null)=>new(){["name"]=name,["args"]=args??new JsonObject()};
        async Task Write(JsonArray calls)=>await File.WriteAllTextAsync(path,
            Json.Encode(new{step_index=0,source="USER_EXPLICIT",type="USER_INPUT",content="Inspect only. Do not write."})+"\n"+
            new JsonObject{["step_index"]=1,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=calls}.ToJsonString()+"\n");
        async Task Reject(JsonObject call,int step=2)
        {
            try{await NativeTranscript.ReadAsync(path,step,call,default);}
            catch(InvalidDataException){return;}
            throw new Exception("Invalid or changed native action was accepted");
        }
        await test("2.32 Hook IDs do not prevent exact transcript action binding",async()=>{
            var native=Call("read_file",new(){["Path"]="public.cs"});await Write(new(native.DeepClone()));
            var hook=native.DeepClone().AsObject();hook["id"]="call_123";
            var evidence=await NativeTranscript.ReadAsync(path,2,hook,default);
            if(evidence.Method!="exact_tool_arguments_preceding_native_step"||hook["id"]?.GetValue<string>()!="call_123")throw new Exception("ID normalization changed source evidence");
            var changed=hook.DeepClone().AsObject();changed["args"]!["Path"]="private.cs";await Reject(changed);
            changed=hook.DeepClone().AsObject();changed["name"]="write_file";await Reject(changed);
            changed=hook.DeepClone().AsObject();changed["future_scope"]="unknown action effect";await Reject(changed);
        });
        await test("2.32 omitted empty arguments remain compatible throughout history",async()=>{
            var empty=new JsonObject{["name"]="list_plugin_accounts"};await Write(new(empty));
            var hook=Call("list_plugin_accounts");hook["id"]="call_empty";
            _=await NativeTranscript.ReadAsync(path,2,hook,default);
            await File.AppendAllTextAsync(path,Json.Encode(new{step_index=2,source="MODEL",type="GENERIC",content="accounts listed"})+"\n"+
                new JsonObject{["step_index"]=3,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=new JsonArray(Call("read_file",new(){["Path"]="public.cs"}))}.ToJsonString()+"\n");
            _=await NativeTranscript.ReadAsync(path,4,Call("read_file",new(){["Path"]="public.cs"}),default);
            await Reject(Call("list_plugin_accounts",new(){["unexpected"]=true}));
        });
        await test("2.32 metadata normalization preserves indexed multi-tool binding",async()=>{
            var first=Call("read_file",new(){["Path"]="first.cs"});var second=Call("read_file",new(){["Path"]="second.cs"});
            await Write(new(first,second.DeepClone()));second["id"]="call_second";
            var evidence=await NativeTranscript.ReadAsync(path,3,second,default);
            if(evidence.Method!="indexed_native_tool_batch")throw new Exception("Batch index lost");
            var wrong=first.DeepClone().AsObject();wrong["id"]="call_second";await Reject(wrong,3);
        });
        await test("2.32 compatibility rejects malformed IDs, null and non-object arguments",async()=>{
            foreach(var malformed in new[]{new JsonObject{["name"]="empty",["args"]=null},new(){["name"]="empty",["args"]=new JsonArray()},new(){["name"]="empty",["id"]=7},new(){["name"]=""}})
            {await Write(new(malformed));await Reject(Call("empty"));}
            await Write(new(Call("empty")));var badHook=Call("empty");badHook["id"]=null;await Reject(badHook);
        });
        await test("service restart step rollback (84 -> 69 without 503) recovers active branch and purges superseded proposals",async()=>{
            var abandoned=Call("run_command",new(){["CommandLine"]="rm -rf superseded"});
            var resumedReads=new JsonArray(
                Call("read_file",new(){["Path"]="state.mjs"}),
                Call("read_file",new(){["Path"]="index.json"}),
                Call("read_file",new(){["Path"]="tasks.json"}),
                Call("read_file",new(){["Path"]="submit.mjs"}));
            var lines=new List<string>{
                Json.Encode(new{step_index=0,source="USER_EXPLICIT",type="USER_INPUT",content="Inspect only. Never delete anything."}),
                new JsonObject{["step_index"]=1,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=new JsonArray(Call("read_file",new(){["Path"]="early.cs"}))}.ToJsonString(),
                Json.Encode(new{step_index=2,source="MODEL",type="GENERIC",content="early content"}),
                Json.Encode(new{step_index=69,source="USER_EXPLICIT",type="USER_INPUT",content="Continue Task B locally."}),
                new JsonObject{["step_index"]=83,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=new JsonArray(abandoned.DeepClone())}.ToJsonString(),
                Json.Encode(new{step_index=84,source="MODEL",type="GENERIC",content="interrupted before restart"}),
                Json.Encode(new{step_index=69,source="USER_EXPLICIT",type="USER_INPUT",content="Continue Task B locally."}),
                Json.Encode(new{step_index=70,source="SYSTEM",type="SYSTEM_MESSAGE",content="Session resumed"}),
                new JsonObject{["step_index"]=71,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=resumedReads}.ToJsonString()
            };
            await File.WriteAllTextAsync(path,string.Join("\n",lines)+"\n");
            var evidence=await NativeTranscript.ReadAsync(path,72,Call("read_file",new(){["Path"]="state.mjs"}),default);
            if(evidence.Method!="indexed_native_tool_batch"||evidence.Segment!=7)throw new Exception("Restart rollback segment was not established");
            if(!evidence.ActiveNonUserPositions!.Contains(2)||evidence.ActiveNonUserPositions.Contains(5)||evidence.ActiveNonUserPositions.Contains(6))
                throw new Exception("Ancestor evidence was lost or superseded branch evidence leaked");
            await Reject(abandoned,84);
        });
    }
}
