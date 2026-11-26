using AgApproval;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

public static class AuditRegressionTests
{
    static void Check(bool ok,string message) { if(!ok)throw new Exception(message); }

    public static async Task RunAsync(string scratch,Settings settings,ReviewInput input,Func<string,Func<Task>,Task> test)
    {
        await test("F04 local frames preserve HTML and escaped strings and enforce exact UTF-8 bounds",async()=>{
            const int inputLimit=1048576;
            foreach(var text in new[]{new string('x',350000),string.Concat(Enumerable.Repeat("<p>内容</p>",35000)),"quotes \" and slash \\ and emoji 😀"})
            {
                var request=new {operation="review",payload=new {content=text}};
                var frame=AgApproval.Program.EncodeIpcFrame(request,inputLimit);
                using var stream=new MemoryStream(Encoding.UTF8.GetBytes(frame+"\n"));
                using var reader=new StreamReader(stream);
                var accepted=await AgApproval.Program.ReadLineAsync(reader,AgApproval.Program.IpcFrameLimit(inputLimit),default);
                Check(Json.Text(JsonNode.Parse(accepted)!["payload"],"content")==text,"IPC changed content");
            }
            var empty=AgApproval.Program.EncodeIpcFrame(new {text=""},inputLimit);
            int size=AgApproval.Program.IpcFrameLimit(inputLimit)-Encoding.UTF8.GetByteCount(empty);
            var exact=AgApproval.Program.EncodeIpcFrame(new {text=new string('x',size)},inputLimit);
            Check(Encoding.UTF8.GetByteCount(exact)==AgApproval.Program.IpcFrameLimit(inputLimit),"boundary setup");
            bool rejected=false;
            try { AgApproval.Program.EncodeIpcFrame(new {text=new string('x',size+1)},inputLimit); }
            catch(InvalidDataException e) when(e.Message=="IPC message too large") {rejected=true;}
            Check(rejected,"oversized frame accepted");
            var pipeName="audit-html-"+Guid.NewGuid().ToString("N");
            using var pipe=new NamedPipeServerStream(pipeName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var html=string.Concat(Enumerable.Repeat("<p>test</p>",35000));
            var server=Task.Run(async()=>{
                await pipe.WaitForConnectionAsync(timeout.Token);
                using var reader=new StreamReader(pipe,leaveOpen:true);
                using var writer=new StreamWriter(pipe,leaveOpen:true){AutoFlush=true};
                var frame=await AgApproval.Program.ReadLineAsync(reader,AgApproval.Program.IpcFrameLimit(inputLimit),timeout.Token);
                Check(Json.Text(JsonNode.Parse(frame),"content")==html,"HTML pipe frame changed");
                await writer.WriteLineAsync("{\"ok\":true}");
            });
            var response=await AgApproval.Program.RequestAsync(new Settings{PipeName=pipeName,MaxInputBytes=inputLimit},new {content=html},TimeSpan.FromSeconds(10));
            await server;
            Check(JsonNode.Parse(response)!["ok"]!.GetValue<bool>(),"HTML named pipe failed");

            // C1 control characters are valid raw JSON but still expand under the IPC encoder.
            // Drive the real Hook entry point with no host, to distinguish size from outage.
            var configPath=Path.Combine(scratch,"oversized-frame-config.json");
            var config=JsonNode.Parse(Json.Encode(settings))!;config["pipeName"]="absent-"+Guid.NewGuid().ToString("N");
            await File.WriteAllTextAsync(configPath,config.ToJsonString());
            var raw="{\"content\":\""+new string('\u0085',200000)+"\"}";
            Check(Encoding.UTF8.GetByteCount(raw)<settings.MaxInputBytes,"raw Hook fixture too large");
            var expanded=System.Text.Json.JsonSerializer.Serialize(JsonNode.Parse(raw),Json.IpcOptions);
            Check(Encoding.UTF8.GetByteCount(expanded)>AgApproval.Program.IpcFrameLimit(settings.MaxInputBytes),"control fixture did not expand");
            var start=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
            if(Path.GetFileNameWithoutExtension(start.FileName).Equals("dotnet",StringComparison.OrdinalIgnoreCase))start.ArgumentList.Add(typeof(AgApproval.Program).Assembly.Location);
            else start.FileName=Path.Combine(Path.GetDirectoryName(typeof(AgApproval.Program).Assembly.Location)!,"gravity-guardian.exe");
            foreach(var arg in new[]{"review","--config",configPath})start.ArgumentList.Add(arg);
            using var child=Process.Start(start)!;
            var stdout=child.StandardOutput.ReadToEndAsync();var stderr=child.StandardError.ReadToEndAsync();
            await child.StandardInput.WriteAsync(raw);child.StandardInput.Close();
            await child.WaitForExitAsync(timeout.Token);
            var hook=JsonNode.Parse(await stdout)!;
            Check(Json.Text(hook,"reason")!.Contains("split this tool call")&&!Json.Text(hook,"reason")!.Contains("service unavailable"),"encoded overflow was reported as service outage: "+await stderr);
        });
        await test("F05 paired outputs retain status, errors and truncation within the existing budget",()=>{
            string Output(string content,string status,string? error)
            {
                var rows=new JsonArray(
                    new JsonObject{["native_position"]=0,["step_index"]=0,["source"]="MODEL",["type"]="PLANNER_RESPONSE",["tool_calls"]=new JsonArray(new JsonObject{["name"]="run_command",["args"]=new JsonObject{["CommandLine"]="verify backup"}})},
                    new JsonObject{["native_position"]=1,["step_index"]=1,["source"]="MODEL",["type"]="GENERIC",["content"]=content,["status"]=status,["error"]=error,["truncation"]=new JsonObject{["upstream_fields"]=new JsonArray("content")}});
                var wire=GuardianFacts.Build(input with {NativeRecords=rows},settings,5000);
                var result=wire["history"]!.AsArray().Single(r=>Json.Text(r,"type")=="function_call_output")!;
                Check(result["output"] is JsonValue,"output protocol changed");
                return Json.Text(result,"output")!;
            }
            var success=Output("Started checking backup.","SUCCESS",null);
            var failed=Output("Started checking backup.","ERROR","No usable backup exists.");
            Check(success!=failed&&Json.Text(JsonNode.Parse(failed),"error")=="No usable backup exists.","failure evidence lost");
            foreach(var content in new[]{"",new string('<',20000)})
            {
                var output=Output(content,"ERROR","No usable backup exists.");
                var doc=JsonNode.Parse(output)!;
                Check(Json.Text(doc,"status")=="ERROR"&&Json.Text(doc,"error")=="No usable backup exists.","body displaced status or error");
                Check(Encoding.UTF8.GetByteCount(output)<=8192,"tool budget expanded");
                Check(doc["truncation"]!["upstream_fields"]![0]!.GetValue<string>()=="content","upstream truncation lost");
                Check(doc["bridge_content_truncated"]!.GetValue<bool>()==(content.Length>0),"body truncation marker wrong");
            }
            return Task.CompletedTask;
        });
        await test("D01 log compaction uses only top-level event types and preserves nested evidence",async()=>{
            var data=Path.Combine(scratch,"compact-event-type");var logs=Path.Combine(data,"logs");Directory.CreateDirectory(logs);
            var path=Path.Combine(logs,"audit.001.jsonl");
            var completed=Json.Encode(new {at=DateTimeOffset.UtcNow,@event="review_completed",requestId="nested",status="approved",detail=new {@event="review_context"}});
            var nestedPayload=Json.Encode(new {at=DateTimeOffset.UtcNow,@event="other",payload=new {content=new string('x',9000),detail=new {@event="tool_completed"}}});
            var malformed="{\"event\":\"review_context\",broken";
            var verbose="{ \"event\" : \"review_context\", \"content\" : \"verbose\" }";
            var tool=Json.Encode(new {@event="tool_completed",payload=new {content=new string('x',9000)}});
            await File.WriteAllLinesAsync(path,[completed,nestedPayload,malformed,verbose,tool]);
            var before=UsageStats.Compute(data).Today.TotalRequests;
            var result=LogCompactor.Compact(data);
            var retained=File.ReadAllLines(path);
            Check(result.DroppedVerboseDumps==1&&retained.Length==4,"top-level event classification failed");
            Check(retained.Contains(completed)&&retained.Contains(nestedPayload)&&retained.Contains(malformed),"nested or unclassified evidence changed");
            Check(JsonNode.Parse(retained[^1])!["payload"]==null,"top-level tool payload was not slimmed");
            Check(before==1&&UsageStats.Compute(data).Today.TotalRequests==before,"nested event lost approval statistics");
        });
        await test("F03 process termination at each per-file commit boundary preserves events and statistics",async()=>{
            foreach(var point in new[]{"writing_temporary","before_replace","after_replace"})
            {
                var data=Path.Combine(scratch,"compact-crash-"+point);var logs=Path.Combine(data,"logs");Directory.CreateDirectory(logs);
                var path=Path.Combine(logs,"audit.007.jsonl");
                var completed=Json.Encode(new {at=DateTimeOffset.UtcNow,@event="review_completed",requestId="crash",status="approved"});
                await File.WriteAllLinesAsync(path,[completed,Json.Encode(new {@event="review_context",content=new string('x',10000)})]);
                var before=UsageStats.Compute(data).Today.TotalRequests;
                var ready=Path.Combine(data,"ready");
                var start=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
                if(Path.GetFileNameWithoutExtension(start.FileName).Equals("dotnet",StringComparison.OrdinalIgnoreCase))start.ArgumentList.Add(typeof(TestMarker).Assembly.Location);
                foreach(var arg in new[]{"--compact-audit-child",data,point,ready})start.ArgumentList.Add(arg);
                using var child=Process.Start(start)!;
                try {
                    for(int i=0;i<200&&!File.Exists(ready)&&!child.HasExited;i++)await Task.Delay(25);
                    Check(File.Exists(ready),"compactor did not reach "+point);
                } finally {if(!child.HasExited)child.Kill(entireProcessTree:true);await child.WaitForExitAsync();}
                Check(File.Exists(path)&&File.ReadAllLines(path).Count(l=>l==completed)==1,"original event lost or duplicated at "+point);
                Check(UsageStats.Compute(data).Today.TotalRequests==before&&before==1,"statistics changed at "+point);
                LogCompactor.Compact(data);
                Check(Directory.GetFiles(logs,"*.jsonl").Single()==path&&UsageStats.Compute(data).Today.TotalRequests==1,"retry renamed or duplicated events");
            }
            var legacy=Path.Combine(scratch,"compact-legacy");var old=Path.Combine(legacy,"logs","compact-stage-old","old-2020-01-01");Directory.CreateDirectory(old);
            var original=Path.Combine(old,"2020-01-01.000.jsonl");await File.WriteAllTextAsync(original,"original evidence");
            Directory.SetCreationTimeUtc(Path.GetDirectoryName(old)!,DateTime.UtcNow.AddHours(-1));
            bool blocked=false;try{LogCompactor.Compact(legacy);}catch(IOException){blocked=true;}
            Check(blocked&&File.ReadAllText(original)=="original evidence","legacy originals were removed or replayed");
        });
    }
}
