using AgApproval;
using System.Text;
using System.Text.Json.Nodes;

public static class SessionTests
{
    private const string Allow="{\"risk_level\":\"low\",\"user_authorization\":\"high\",\"outcome\":\"allow\",\"rationale\":\"Fixture assessment\"}";
    private static void Check(bool value,string message){if(!value)throw new Exception(message);}
    public static async Task<int> FakeAsync(string[] args)
    {
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = new UTF8Encoding(false);
        foreach(var flag in new[]{"exec","--ignore-user-config","--ignore-rules","read-only","codex-auto-review"})if(!args.Contains(flag))return 21;
        if(args.Contains("--ephemeral"))return 22;
        var wire=JsonNode.Parse(await Console.In.ReadToEndAsync())!;
        var instructionFile=JsonNode.Parse(args.Single(arg=>arg.StartsWith("model_instructions_file=")).Split('=',2)[1])!.GetValue<string>();
        if(wire["current_review"]?["adapter"]?["instructions"]!=null ||
            !(await File.ReadAllTextAsync(instructionFile)).Contains(ReviewAdapter.Instructions,StringComparison.Ordinal))return 24;
        var idFile=Path.Combine(Environment.CurrentDirectory,"fake-thread-id");
        int resume=Array.IndexOf(args,"resume");string id;
        if(resume>=0){if(!File.Exists(idFile)||args[resume+1]!=await File.ReadAllTextAsync(idFile))return 23;id=args[resume+1];}
        else{id=Guid.NewGuid().ToString();await File.WriteAllTextAsync(idFile,id);}
        if(Json.Text(wire["current_review"]?["additional_hook_scope"],"fixture")=="wrong_thread")id=Guid.NewGuid().ToString();
        Console.WriteLine(Json.Encode(new{type="thread.started",thread_id=id}));Console.WriteLine("{\"type\":\"turn.started\"}");
        var fixture=Json.Text(wire["current_review"]?["additional_hook_scope"],"fixture");
        if(fixture=="failure"){Console.WriteLine("{\"type\":\"turn.failed\",\"error\":{\"message\":\"fixture failure\"}}");return 1;}
        var assessment=fixture=="invalid_output"?"invalid":Allow;
        Console.WriteLine(Json.Encode(new{type="item.completed",item=new{type="agent_message",text=assessment}}));
        int sequence=wire["sequence"]!.GetValue<int>();
        Console.WriteLine(Json.Encode(new{type="turn.completed",usage=new{input_tokens=120*sequence,cached_input_tokens=80*sequence,output_tokens=12*sequence,reasoning_output_tokens=4*sequence}}));
        if(fixture=="shutdown_hang"){await Console.Out.FlushAsync();await Task.Delay(30000);}
        await File.WriteAllTextAsync(args[Array.IndexOf(args,"--output-last-message")+1],assessment);return 0;
    }
    public static async Task RunAsync(Settings original,Policy policy,Func<JsonNode> payload,Func<string,Func<Task>,Task> test)
    {
        var settings=System.Text.Json.JsonSerializer.Deserialize<Settings>(Json.Encode(original),Json.Options)!;
        settings.EnableReviewerSessions=true;settings.EnableDetailedLogs=true;settings.ReviewTimeoutSeconds=10;
        settings.DataDirectory=Path.Combine(original.DataDirectory,"session-tests");
        settings.CodexPrefixArguments=original.CodexPrefixArguments.Select(x=>x=="--fake-codex"?"--fake-session-codex":x).ToArray();
        await File.WriteAllTextAsync(Path.Combine(settings.CodexHome,"auth.json"),"{}");
        async Task<ReviewInput> Input(string? fixture=null)
        {
            var p=payload();if(fixture!=null)p["fixture"]=fixture;
            return await ReviewContext.BuildAsync(p,settings,default);
        }
        JsonNode[] Logs()=>Directory.GetFiles(Path.Combine(settings.DataDirectory,"logs"),"*.jsonl").SelectMany(File.ReadAllLines).Select(x=>JsonNode.Parse(x)!).ToArray();
        await test("UTF-8 evidence selection has its own hard budget and preserves explicit omissions",()=>{
            var records=Enumerable.Range(0,80).Select(i=>new JsonObject{["record_id"]="native:"+i,["native_position"]=i,["content"]=new string('中',3000)+"😀",["truncation"]=new JsonObject{["bridge_content_truncated"]=false}}).ToArray();
            var (chosen,omitted)=ReviewEvidence.Select(records,settings,int.MaxValue);
            Check(Encoding.UTF8.GetByteCount(chosen.ToJsonString(Json.PromptOptions))<=settings.MaxEvidenceBytes&&chosen.Count<=40,"evidence exceeded its budget");
            Check(chosen.Count+omitted.Count==80&&chosen.Last()!["native_position"]!.GetValue<int>()==79,"selection lost omission identities or recent evidence");
            foreach(var r in chosen){var c=Json.Text(r,"content")!;Check(Encoding.UTF8.GetByteCount(c)<=4096&&!c.Contains('\uFFFD')&&r!["truncation"]!["bridge_content_truncated"]!.GetValue<bool>(),"unsafe UTF-8 truncation");}
            return Task.CompletedTask;
        });
        await test("session delta reconstructs exact snapshots and never treats a missing reference as evidence",async()=>{
            var sessions=new ReviewerSessions(settings);var one=sessions.Prepare(await Input());
            Check(JsonNode.DeepEquals(ReviewerSessions.Reconstruct(JsonNode.Parse(one.Prompt)!.AsObject(),one.State.Evidence),one.Snapshot),"full reconstruction failed");
            one.ReportedThreadId=Guid.NewGuid().ToString();one.Reusable=true;sessions.Commit(one,Allow);
            var two=sessions.Prepare(await Input());Check(two.Mode=="delta"&&two.AddedEvidence==0,"unchanged evidence resent");
            Check(JsonNode.DeepEquals(ReviewerSessions.Reconstruct(JsonNode.Parse(two.Prompt)!.AsObject(),two.State.Evidence),two.Snapshot),"delta reconstruction failed");
            bool rejected=false;try{ReviewerSessions.Reconstruct(JsonNode.Parse(two.Prompt)!.AsObject(),new Dictionary<string,JsonNode>());}catch(InvalidDataException){rejected=true;}
            Check(rejected,"missing reference silently restored");sessions.Retire(two.State);
        });
        await test("authorization revisions and turn limits force independent full checkpoints",async()=>{
            var sessions=new ReviewerSessions(settings);var input=await Input();var a=sessions.Prepare(input);a.ReportedThreadId=Guid.NewGuid().ToString();a.Reusable=true;sessions.Commit(a,Allow);
            var d=JsonNode.Parse(input.Prompt)!;d["authorization_revision"]=new string('a',64);
            var b=sessions.Prepare(input with{Prompt=d.ToJsonString(Json.PromptOptions)});Check(b.Mode=="full"&&b.State.Scope!=a.State.Scope,"authorization scope mixed");
            a.State.Turns=settings.MaxReviewerSessionTurns;Check(sessions.Prepare(input).Mode=="full","turn cap did not rotate");
            sessions.Retire(b.State);
        });
        await test("official CLI adapter resumes the exact captured UUID and logs per-invocation usage",async()=>{
            var reviewer=new CodexReviewer(settings,policy);await reviewer.ReviewAsync(await Input(),default);await reviewer.ReviewAsync(await Input(),default);
            var transports=Logs().Where(x=>Json.Text(x,"event")=="review_transport").TakeLast(2).ToArray();
            await File.WriteAllTextAsync(Path.Combine(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"../../../../../")),".local/contract/session.json"),transports[1]["wire"]!.ToJsonString());
            Check(Json.Text(transports[0],"mode")=="full"&&Json.Text(transports[1],"mode")=="delta"&&Json.Text(transports[1],"expectedThreadId")!=null,"adapter did not resume");
            var usage=Logs().Where(x=>Json.Text(x,"event")=="review_usage").TakeLast(2).ToArray();Check(usage.Sum(x=>x["usage"]!["totalTokens"]!.GetValue<int>())==264,"cumulative token usage counted twice");
        });
        foreach(var fixture in new[]{"failure","invalid_output","wrong_thread"})await test("failed session is retired: "+fixture,async()=>{
            var reviewer=new CodexReviewer(settings,policy);await reviewer.ReviewAsync(await Input(),default);
            bool failed=false;try{await reviewer.ReviewAsync(await Input(fixture),default);}catch(Exception e)when(e is InvalidOperationException or InvalidDataException or System.Text.Json.JsonException){failed=true;}
            Check(failed,"invalid session result accepted");await reviewer.ReviewAsync(await Input(),default);
            Check(Json.Text(Logs().Last(x=>Json.Text(x,"event")=="review_transport"),"mode")=="full","failed session resumed");
        });
        await test("completed review with forced process termination is usable once and never resumed",async()=>{
            var reviewer=new CodexReviewer(settings,policy);await reviewer.ReviewAsync(await Input("shutdown_hang"),default);await reviewer.ReviewAsync(await Input(),default);
            Check(Json.Text(Logs().Last(x=>Json.Text(x,"event")=="review_transport"),"mode")=="full","terminated process session resumed");
        });
        await test("credential-state change invalidates reuse without reading credential contents",async()=>{
            var sessions=new ReviewerSessions(settings);var input=await Input();var a=sessions.Prepare(input);a.ReportedThreadId=Guid.NewGuid().ToString();a.Reusable=true;sessions.Commit(a,Allow);
            File.SetLastWriteTimeUtc(Path.Combine(settings.CodexHome,"auth.json"),DateTime.UtcNow.AddSeconds(3));
            var b=sessions.Prepare(input);Check(b.Mode=="full"&&b.State.Scope!=a.State.Scope,"changed credential state resumed old context");sessions.Retire(a.State);sessions.Retire(b.State);
        });
        await test("cumulative counter deltas preserve original reports and reject counter regressions",()=>{
            var first=new CliUsage();first.Observe("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":120,\"cached_input_tokens\":80,\"output_tokens\":12}}");
            var second=new CliUsage();second.Observe("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":250,\"cached_input_tokens\":160,\"output_tokens\":24}}");
            var delta=CliUsage.SessionDelta(second.Snapshot(),first.Snapshot());
            Check(delta["totalTokens"]!.GetValue<long>()==142&&delta["rawUsageReports"]![0]!["input_tokens"]!.GetValue<long>()==250&&delta["deltaUsageReports"]![0]!["input_tokens"]!.GetValue<long>()==130,"native cumulative values were lost or double counted");
            bool rejected=false;try{CliUsage.SessionDelta(first.Snapshot(),second.Snapshot());}catch(InvalidDataException){rejected=true;}Check(rejected,"regressed counters became negative usage");return Task.CompletedTask;
        });
        await test("changed evidence is resent and cross-conversation state cannot be reused",async()=>{
            var sessions=new ReviewerSessions(settings);var input=await Input();var a=sessions.Prepare(input);a.ReportedThreadId=Guid.NewGuid().ToString();a.Reusable=true;sessions.Commit(a,Allow);
            var d=JsonNode.Parse(input.Prompt)!;d["conversation_evidence"]![0]!["content"]="Changed evidence body";
            var b=sessions.Prepare(input with{Prompt=d.ToJsonString(Json.PromptOptions)});Check(b.Mode=="delta"&&b.AddedEvidence==1,"changed record hidden by same record ID");
            d["planned_action"]!["conversationId"]=Guid.NewGuid().ToString();var c=sessions.Prepare(input with{Prompt=d.ToJsonString(Json.PromptOptions)});Check(c.Mode=="full"&&c.State.Scope!=a.State.Scope,"foreign conversation shared evidence");sessions.Retire(a.State);sessions.Retire(c.State);
        });
        await test("byte and observed-input budgets rotate before an unbounded continuation",async()=>{
            var sessions=new ReviewerSessions(settings);var input=await Input();var a=sessions.Prepare(input);a.ReportedThreadId=Guid.NewGuid().ToString();a.Reusable=true;sessions.Commit(a,Allow);
            a.State.SentBytes=settings.MaxReviewerSessionBytes-1;var b=sessions.Prepare(input);Check(b.Mode=="full","pending message was not included in byte budget");
            b.ReportedThreadId=Guid.NewGuid().ToString();b.Reusable=true;b.LastInputTokens=settings.MaxReviewerSessionInputTokens;sessions.Commit(b,Allow);
            Check(sessions.Prepare(input).Mode=="full","observed input cap did not rotate");
        });
    }
    public static async Task<int> AuditAsync(string manifestPath,string outputPath)
    {
        var manifest=JsonNode.Parse(await File.ReadAllTextAsync(manifestPath))!;var settings=new Settings{CodexHome=Path.GetDirectoryName(outputPath)!,DataDirectory=Path.Combine(Path.GetDirectoryName(outputPath)!,"state")};
        Directory.CreateDirectory(settings.CodexHome);await File.WriteAllTextAsync(Path.Combine(settings.CodexHome,"auth.json"),"{}");
        var ids=File.ReadLines(Path.Combine(Path.GetDirectoryName(manifestPath)!,"run-calls.jsonl")).Where(x=>x.Trim().Length>0).Select(x=>Json.Text(JsonNode.Parse(x),"requestId")!).ToHashSet();
        var sessions=new ReviewerSessions(settings);long oldBytes=0,selectedBytes=0,wireBytes=0;int count=0,full=0,delta=0;var evidenceLimits=new JsonArray();
        foreach(var chunk in manifest["chunks"]!.AsArray())
        {
            using var file=new FileStream(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".gemini","codex-approval-data","logs",Json.Text(chunk,"file")!),FileMode.Open,FileAccess.Read,FileShare.ReadWrite);
            file.Position=chunk!["start"]!.GetValue<long>();var bytes=new byte[checked((int)(chunk["end"]!.GetValue<long>()-file.Position))];await file.ReadExactlyAsync(bytes);
            foreach(var line in Encoding.UTF8.GetString(bytes).Split('\n').Where(x=>x.Trim().Length>0))
            {
                var r=JsonNode.Parse(line)!;if(Json.Text(r,"event")!="review_context"||!ids.Contains(Json.Text(r,"requestId")!))continue;
                var d=r["reviewInput"]!.DeepClone().AsObject();oldBytes+=Encoding.UTF8.GetByteCount(d.ToJsonString(Json.PromptOptions));
                var selected=ReviewEvidence.Select(d["conversation_evidence"]!.AsArray().Select(x=>x!.AsObject()),settings,int.MaxValue);
                var omitted=d["transcript_omitted_positions"]!.AsArray();foreach(var n in selected.Omitted)omitted.Add(n);
                d["transcript_omitted_records"]=omitted.Count;d["conversation_evidence"]=selected.Selected;
                var action=d["planned_action"]!;var input=new ReviewInput(Json.Text(d,"request_id")!,Json.Text(d,"action_sha256")!,Json.Text(action,"conversationId")!,Json.Text(action["toolCall"],"name")!,Json.Text(action,"cwd")!,d.ToJsonString(Json.PromptOptions),"");
                var plan=sessions.Prepare(input);Check(JsonNode.DeepEquals(ReviewerSessions.Reconstruct(JsonNode.Parse(plan.Prompt)!.AsObject(),plan.State.Evidence),d),"real snapshot reconstruction failed");
                if(plan.Mode=="full")full++;else delta++;count++;selectedBytes+=Encoding.UTF8.GetByteCount(input.Prompt);wireBytes+=Encoding.UTF8.GetByteCount(plan.Prompt);
                evidenceLimits.Add(Encoding.UTF8.GetByteCount(selected.Selected.ToJsonString(Json.PromptOptions)));
                plan.ReportedThreadId=plan.ExpectedThreadId??Guid.NewGuid().ToString();plan.Reusable=true;sessions.Commit(plan,Allow);
            }
        }
        var result=new{count,full,delta,originalPromptBytes=oldBytes,boundedSnapshotBytes=selectedBytes,incrementalWireBytes=wireBytes,exactReconstruction=count,modelCalls=0,note="Offline byte comparison only; not token or billing savings. Current selector was applied to historically retained evidence, not to missing original transcript rows."};
        await File.WriteAllTextAsync(outputPath,Json.Encode(result));Console.WriteLine(Json.Encode(result));return 0;
    }

    public static async Task<int> CompareAsync(string configPath,string manifestPath,string outputDirectory)
    {
        Directory.CreateDirectory(outputDirectory);
        var manifest=JsonNode.Parse(await File.ReadAllTextAsync(manifestPath))!;var docs=new List<JsonObject>();string? conversation=null;
        foreach(var chunk in manifest["chunks"]!.AsArray())
        {
            if(docs.Count==2)break;
            using var file=new FileStream(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".gemini","codex-approval-data","logs",Json.Text(chunk,"file")!),FileMode.Open,FileAccess.Read,FileShare.ReadWrite);
            file.Position=chunk!["start"]!.GetValue<long>();var bytes=new byte[checked((int)(chunk["end"]!.GetValue<long>()-file.Position))];await file.ReadExactlyAsync(bytes);
            foreach(var line in Encoding.UTF8.GetString(bytes).Split('\n').Where(x=>x.Trim().Length>0))
            {
                var record=JsonNode.Parse(line)!;if(Json.Text(record,"event")!="review_context"||record["model"]==null)continue;
                var d=record["reviewInput"]!.AsObject();var conv=Json.Text(d["planned_action"],"conversationId");conversation??=conv;if(conv!=conversation)continue;
                docs.Add((JsonObject)d.DeepClone());if(docs.Count==2)break;
            }
        }
        if(docs.Count!=2)throw new InvalidDataException("Two same-conversation frozen model requests are required");
        var results=new JsonArray();int attempts=0;
        foreach(bool sessionMode in new[]{false,true})
        {
            var settings=Settings.Load(configPath);settings.EnableReviewerSessions=sessionMode;
            settings.DataDirectory=Path.GetFullPath(Path.Combine(outputDirectory,sessionMode?"bounded-sessions":"original-isolated"));
            var policy=new Policy(settings.PolicyDirectory);var reviewer=new CodexReviewer(settings,policy);
            foreach(var original in docs)
            {
                var d=(JsonObject)original.DeepClone();d["request_id"]=Guid.NewGuid().ToString("N");
                if(sessionMode)
                {
                    var selected=ReviewEvidence.Select(d["conversation_evidence"]!.AsArray().Select(x=>x!.AsObject()),settings,int.MaxValue);
                    d["conversation_evidence"]=selected.Selected;foreach(var n in selected.Omitted)d["transcript_omitted_positions"]!.AsArray().Add(n);
                    d["transcript_omitted_records"]=d["transcript_omitted_positions"]!.AsArray().Count;
                }
                var action=d["planned_action"]!;var id=Json.Text(d,"request_id")!;
                var input=new ReviewInput(id,Json.Text(d,"action_sha256")!,Json.Text(action,"conversationId")!,Json.Text(action["toolCall"],"name")!,Json.Text(action,"cwd")!,d.ToJsonString(Json.PromptOptions),Json.Hash(d.ToJsonString(Json.PromptOptions)));
                using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(90));attempts++;
                await File.WriteAllTextAsync(Path.Combine(outputDirectory,id+".input.json"),input.Prompt);
                try
                {
                    var assessment=await reviewer.ReviewAsync(input,deadline.Token);var decision=policy.Apply(assessment,id,input.Hash);
                    results.Add(new JsonObject{["requestId"]=id,["sessionMode"]=sessionMode,["decision"]=decision.Decision,["assessment"]=assessment});
                }
                catch(Exception e){results.Add(new JsonObject{["requestId"]=id,["sessionMode"]=sessionMode,["technicalFailure"]=e.Message});await Save();Console.WriteLine("Comparison stopped after technical failure; no extra model retries.");return 2;}
                await Save();Console.WriteLine(Json.Encode(new{attempt=attempts,sessionMode,completed=true,actionExecuted=false}));
            }
        }
        return 0;
        Task Save()=>File.WriteAllTextAsync(Path.Combine(outputDirectory,"comparison.json"),new JsonObject{["maximumModelCalls"]=4,["attempts"]=attempts,["actionExecuted"]=false,["results"]=results.DeepClone(),["note"]="Four-call frozen-input smoke comparison; not a comprehensive safety or billing experiment."}.ToJsonString(Json.Options));
    }
}
