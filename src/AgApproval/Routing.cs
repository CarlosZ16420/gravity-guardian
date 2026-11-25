using System.Diagnostics;
using System.IO.Enumeration;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AgApproval;

public sealed record ReviewRoute(string Route, string RuleId, string Reason)
{
    public const string Version = "native-readonly-v2";
    public static ReviewRoute Model(string reason) => new("model", "model_fallback", reason);
    public static ReviewRoute Native(string id) => new("native", id, "Known bounded read-only operation; defer to native permissions without granting additional access.");
}

public static class ReviewRouting
{
    public static Task<ReviewRoute> EvaluateAsync(ReviewInput input, Settings settings, CancellationToken ct)
    {
        var document=JsonNode.Parse(input.Prompt)!;
        var permissions=document["permission_context"]!;
        var planned=document["planned_action"]!;
        var args=planned["toolCall"]!["args"]!.AsObject();
        var workspaces=planned["workspacePaths"]!.AsArray().Select(p=>p!.GetValue<string>()).ToArray();
        return EvaluateRawAsync(input.Tool,input.Conversation,input.Cwd,workspaces,args,permissions,settings,ct);
    }

    public static async Task<ReviewRoute> EvaluateRawAsync(string tool,string conversation,string cwd,string[] workspaces,JsonObject args,JsonNode permissions,Settings settings,CancellationToken ct)
    {
        if (!settings.EnableNativeRouting) return ReviewRoute.Model("Native routing disabled.");
        var global=permissions["global_settings"]!;
        var project=permissions["matching_projects"]!.AsArray();
        var configured=Json.Text(permissions,"configured_permission_preset");
        var sandbox=global["enableTerminalSandbox"]?.GetValue<bool>() == true;
        if(project.Count>1) return ReviewRoute.Model("Ambiguous native project scope.");
        if(project.Count==1 && project[0]?["settings"]?["enableTerminalSandbox"] is JsonValue sandboxOverride)
            sandbox=sandboxOverride.GetValue<bool>();
        if(configured!="AGENT_PERMISSION_PRESET_DEFAULT" || !sandbox)
            return ReviewRoute.Model("Native Default sandbox configuration is not established.");
        if(args["BypassSandbox"] is JsonValue bypass && (!bypass.TryGetValue<bool>(out var bypassValue)||bypassValue))
            return ReviewRoute.Model("Requested or ambiguous sandbox bypass.");
        if(tool=="manage_task")
        {
            if(args.Count==1&&Json.Text(args,"Action")=="list")
                return ReviewRoute.Native("current_conversation_task_list");
            if(args.Any(p=>p.Key is not ("Action" or "TaskId")) || Json.Text(args,"Action")!="status")
                return ReviewRoute.Model("Task mutation or unsupported task arguments.");
            var target=Json.Text(args,"TaskId")??"";
            return Regex.IsMatch(target,"^"+Regex.Escape(conversation)+@"/task-[0-9]+$",RegexOptions.CultureInvariant)
                ? ReviewRoute.Native("current_conversation_task_status") : ReviewRoute.Model("Task does not belong to this conversation.");
        }
        if(tool=="manage_subagents")
        {
            return args.Count==1&&Json.Text(args,"Action")=="list"
                ? ReviewRoute.Native("current_conversation_subagent_list")
                : ReviewRoute.Model("Subagent mutation or unsupported arguments.");
        }
        if(tool=="list_plugin_accounts")
        {
            return args.Count==0
                ? ReviewRoute.Native("plugin_account_status_read")
                : ReviewRoute.Model("Unsupported plugin account arguments.");
        }
        if(tool=="enter_plan_mode")
        {
            return args.Count==0
                ? ReviewRoute.Native("current_conversation_enter_plan")
                : ReviewRoute.Model("Unsupported enter_plan_mode arguments.");
        }
        if(tool=="update_focus")
        {
            if(args.Count!=1||args["focus"] is not JsonValue fv||!fv.TryGetValue<string>(out var focus)||string.IsNullOrWhiteSpace(focus)||focus.Length>512)
                return ReviewRoute.Model("Invalid update_focus arguments.");
            return ReviewRoute.Native("current_conversation_update_focus");
        }
        if(tool=="update_steps")
        {
            if(args.Count!=1||args["steps"] is not JsonArray steps||steps.Count is <1 or >12)
                return ReviewRoute.Model("Unsupported update_steps contract.");
            foreach(var step in steps)
                if(step is not JsonObject s||s.Count!=2||s.Any(p=>p.Key is not ("title" or "status"))||
                    s["title"] is not JsonValue tv||!tv.TryGetValue<string>(out var title)||string.IsNullOrWhiteSpace(title)||title.Length>256||
                    s["status"] is not JsonValue sv||!sv.TryGetValue<string>(out var status)||
                    status is not ("pending" or "in_progress" or "done" or "skipped" or "failed"))
                    return ReviewRoute.Model("Invalid update_steps item.");
            return ReviewRoute.Native("current_conversation_update_steps");
        }
        if(tool=="exit_plan_mode")
        {
            if(args.Any(p=>p.Key!="plan")) return ReviewRoute.Model("Unsupported exit_plan_mode arguments.");
            if(args.ContainsKey("plan")&&(args["plan"] is not JsonValue pv||!pv.TryGetValue<string>(out var plan)||plan.Length>131072))
                return ReviewRoute.Model("Invalid exit_plan_mode plan payload.");
            return ReviewRoute.Native("current_conversation_exit_plan");
        }
        if(tool=="ask_question")
        {
            if(args.Count!=1||args["questions"] is not JsonArray questions||questions.Count is <1 or >5)
                return ReviewRoute.Model("Unsupported question contract.");
            foreach(var question in questions)
                if(question is not JsonObject q||q.Count is <2 or >3||q.Any(p=>p.Key is not ("question" or "options" or "is_multi_select"))||
                    q["question"] is not JsonValue text||!text.TryGetValue<string>(out var title)||string.IsNullOrWhiteSpace(title)||title.Length>4000||
                    (q.ContainsKey("is_multi_select")&&(q["is_multi_select"] is not JsonValue multi||!multi.TryGetValue<bool>(out _)))||
                    q["options"] is not JsonArray options||options.Count is <2 or >16||options.Any(o=>o is not JsonValue v||!v.TryGetValue<string>(out var s)||string.IsNullOrWhiteSpace(s)||s.Length>4000))
                    return ReviewRoute.Model("Invalid structured question parameters.");
            return ReviewRoute.Native("current_conversation_question");
        }
        if(tool=="read_file")
        {
            if(args.Any(p=>p.Key is not ("Path" or "AbsolutePath" or "StartLine" or "EndLine" or "ByteOffset")))
                return ReviewRoute.Model("Unsupported structured read arguments.");
            if(args.ContainsKey("ByteOffset")&&(args["ByteOffset"] is not JsonValue offset||!offset.TryGetValue<long>(out var value)||value!=0))
                return ReviewRoute.Model("Only the observed zero ByteOffset contract is supported.");
            foreach(var key in new[]{"StartLine","EndLine"})
                if(args.ContainsKey(key)&&(args[key] is not JsonValue n||!n.TryGetValue<int>(out var line)||line is <1 or >1000000))
                    return ReviewRoute.Model("Invalid or unsupported structured line range.");
            if(args["StartLine"]!=null&&args["EndLine"]!=null&&args["EndLine"]!.GetValue<int>()<args["StartLine"]!.GetValue<int>())
                return ReviewRoute.Model("Reversed structured line range.");
            if((args.ContainsKey("Path")?1:0)+(args.ContainsKey("AbsolutePath")?1:0)!=1)
                return ReviewRoute.Model("Ambiguous structured read target.");
            var target=Json.Text(args,"Path")??Json.Text(args,"AbsolutePath");
            if(target==null||!Path.IsPathFullyQualified(target)) return ReviewRoute.Model("Structured read must have an absolute target.");
            if(ScopedRead.IsSafe(target,cwd,workspaces,false,false))
                return ReviewRoute.Native("workspace_source_read");
            if(ScopedRead.IsSafeSkillDoc(target))
                return ReviewRoute.Native("verified_skill_doc_read");
            return ReviewRoute.Model("Read target is outside the bounded source-file subset.");
        }
        if(tool!="run_command") return ReviewRoute.Model("Tool has no deterministic read-only rule.");
        if(args.Any(p=>p.Key is not ("CommandLine" or "Cwd" or "cwd" or "WaitMsBeforeAsync" or "toolSummary" or "BypassSandbox")))
            return ReviewRoute.Model("Unsupported command execution arguments.");
        var command=Json.Text(args,"CommandLine")??"";
        if(!Regex.IsMatch(command,@"^\s*(Get-ChildItem|Get-Content|Select-String)(\s|$)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant))
            return ReviewRoute.Model("Interpreter, arbitrary executable or unsupported command.");
        var parsed=await ParseAsync(command,ct);
        if(parsed?["valid"]?.GetValue<bool>()!=true) return ReviewRoute.Model("Full PowerShell syntax is unavailable or outside the literal subset.");
        var commands=parsed["commands"]!.AsArray();
        if(commands.Count is <1 or >2) return ReviewRoute.Model("Unsupported command pipeline.");
        if(!ValidateSource(commands[0]!,cwd,workspaces)) return ReviewRoute.Model("Source command options or paths are not covered.");
        if(commands.Count==2 && !ValidateSelect(commands[1]!)) return ReviewRoute.Model("Pipeline tail is not a bounded read-only projection.");
        return ReviewRoute.Native("literal_workspace_read_command");
    }

    private static bool Arguments(JsonNode command,HashSet<string> allowed,HashSet<string> switches,
        out Dictionary<string,List<string>> values)
    {
        values=new(StringComparer.OrdinalIgnoreCase);string current="positional";
        foreach(var token in command["arguments"]!.AsArray())
        {
            var parameter=Json.Text(token,"parameter");
            if(parameter!=null)
            {
                if(!allowed.Contains(parameter)||values.ContainsKey(parameter)) return false;
                if(current!="positional"&&!switches.Contains(current)&&values[current].Count==0) return false;
                current=parameter;values[current]=new();
            }
            else
            {
                if(switches.Contains(current)) return false;
                if(!values.ContainsKey(current))values[current]=new();
                values[current].AddRange(token!["values"]!.AsArray().Select(v=>v!.GetValue<string>()));
            }
        }
        return values.All(p=>p.Value.Count>0||switches.Contains(p.Key));
    }
    private static HashSet<string> Names(params string[] values)=>new(values,StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> SafeErrorActions=Names("SilentlyContinue","Ignore","Stop","Continue");
    private static readonly HashSet<string> SafeEncodings=Names("utf8","utf8NoBOM","unicode","ascii","default");
    private static readonly Regex SafePropertyName=new(@"^[A-Za-z][A-Za-z0-9_]{0,63}$",RegexOptions.CultureInvariant);
    private static bool ValidateSource(JsonNode command,string cwd,string[] roots)
    {
        var name=Json.Text(command,"name");
        bool list=string.Equals(name,"Get-ChildItem",StringComparison.OrdinalIgnoreCase);
        bool content=string.Equals(name,"Get-Content",StringComparison.OrdinalIgnoreCase);
        bool search=string.Equals(name,"Select-String",StringComparison.OrdinalIgnoreCase);
        if(!list&&!content&&!search)return false;
        var flags=list?Names("Recurse","File","Directory","Name")
            :search?Names("SimpleMatch","CaseSensitive","List","NotMatch")
            :Names("Raw");
        var allowed=Names("Path","LiteralPath","ErrorAction");
        if(list)allowed.UnionWith(Names("Recurse","File","Directory","Name","Depth","Filter"));
        if(search)allowed.UnionWith(Names("Pattern","SimpleMatch","CaseSensitive","List","NotMatch","Context","Encoding"));
        if(content)allowed.UnionWith(Names("Raw","TotalCount","Tail","Encoding"));
        if(!Arguments(command,allowed,flags,out var values))return false;
        if(values.ContainsKey("Path")&&values.ContainsKey("LiteralPath"))return false;
        if(values.ContainsKey("positional")&&(search||values.ContainsKey("Path")||values.ContainsKey("LiteralPath")))return false;
        if(search&&(!values.TryGetValue("Pattern",out var patterns)||patterns.Count==0))return false;
        if(values.TryGetValue("ErrorAction",out var ea)&&(ea.Count!=1||!SafeErrorActions.Contains(ea[0])))return false;
        if(values.TryGetValue("Encoding",out var enc)&&(enc.Count!=1||!SafeEncodings.Contains(enc[0])))return false;
        if(values.TryGetValue("Depth",out var depth)&&(depth.Count!=1||!int.TryParse(depth[0],out int d)||d is <0 or >32))return false;
        if(values.TryGetValue("Filter",out var filter)&&(filter.Count!=1||string.IsNullOrWhiteSpace(filter[0])||filter[0].Length>256||filter[0].IndexOfAny(['\\','/',':','$','`','[',']'])>=0))return false;
        if(values.TryGetValue("Context",out var ctx)&&(ctx.Count is <1 or >2||ctx.Any(c=>!int.TryParse(c,out int cn)||cn is <0 or >20)))return false;
        foreach(var count in new[]{"TotalCount","Tail"})
            if(values.TryGetValue(count,out var numbers)&&(numbers.Count!=1||!int.TryParse(numbers[0],out int n)||n is <1 or >10000))return false;
        var targets=values.GetValueOrDefault("LiteralPath")??values.GetValueOrDefault("Path")??values.GetValueOrDefault("positional");
        if(targets==null){if(!list)return false;targets=new(){cwd};}
        bool allowGlob=!values.ContainsKey("LiteralPath");
        bool recurse=list&&values.ContainsKey("Recurse");
        return targets.Count is >0 and <=16 && targets.All(p=>ScopedRead.IsSafe(p,cwd,roots,allowGlob,list)&&(!recurse||ScopedRead.IsSafeRecursiveListing(p,cwd,roots,allowGlob)));
    }
    private static bool ValidateSelect(JsonNode command)
    {
        var name=Json.Text(command,"name");
        if(string.Equals(name,"Measure-Object",StringComparison.OrdinalIgnoreCase))
            return Arguments(command,Names("Line","Word","Character"),Names("Line","Word","Character"),out _);
        if(!string.Equals(name,"Select-Object",StringComparison.OrdinalIgnoreCase)) return false;
        if(!Arguments(command,Names("First","Last","Skip","Unique","Property","ExpandProperty"),Names("Unique"),out var values)||values.Count==0)
            return false;
        if(values.ContainsKey("Property")&&values.ContainsKey("positional")) return false;
        if(values.ContainsKey("ExpandProperty")&&(values.ContainsKey("Property")||values.ContainsKey("positional"))) return false;
        foreach(var bound in new[]{"First","Last"})
            if(values.TryGetValue(bound,out var count)&&(count.Count!=1||!int.TryParse(count[0],out var n)||n is <1 or >5000)) return false;
        if(values.TryGetValue("Skip",out var skip)&&(skip.Count!=1||!int.TryParse(skip[0],out var s)||s is <0 or >100000)) return false;
        if(values.TryGetValue("ExpandProperty",out var expand)&&(expand.Count!=1||!SafePropertyName.IsMatch(expand[0]))) return false;
        var props=values.GetValueOrDefault("Property")??values.GetValueOrDefault("positional");
        if(props!=null&&(props.Count is <1 or >16||props.Any(p=>!SafePropertyName.IsMatch(p)))) return false;
        return true;
    }

    private static readonly SemaphoreSlim ParserLock=new(1);
    private static Process? ParserProcess;
    private static string? CachedParserScript;
    static ReviewRouting() => AppDomain.CurrentDomain.ProcessExit += (_, _) => TryStopParser();

    private static async Task<JsonNode?> ParseAsync(string command,CancellationToken ct)
    {
        if(!OperatingSystem.IsWindows())return null;
        var executable=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
        if(!File.Exists(executable))return null;
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);deadline.CancelAfter(TimeSpan.FromSeconds(5));
        await ParserLock.WaitAsync(deadline.Token);
        try
        {
            if(CachedParserScript==null)
            {
                using var resource=typeof(ReviewRouting).Assembly.GetManifestResourceStream("AgApproval.Parse-ReadOnlyCommand.ps1")!;
                using var reader=new StreamReader(resource);
                CachedParserScript=await reader.ReadToEndAsync(deadline.Token);
            }
            if(ParserProcess is null or {HasExited:true})
            {
                TryStopParser();
                var start=new ProcessStartInfo(executable){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,
                    RedirectStandardOutput=true,RedirectStandardError=true,StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=Encoding.UTF8};
                start.Environment["AG_PERSISTENT_PARSER"]="1";
                foreach(var argument in new[]{"-NoLogo","-NoProfile","-NonInteractive","-EncodedCommand",Convert.ToBase64String(Encoding.Unicode.GetBytes(CachedParserScript))})
                    start.ArgumentList.Add(argument);
                ParserProcess=Process.Start(start);
                if(ParserProcess==null)return null;
                _=ParserProcess.StandardError.BaseStream.CopyToAsync(Stream.Null);
            }
            var encoded=Convert.ToBase64String(Encoding.UTF8.GetBytes(command));
            await ParserProcess.StandardInput.WriteLineAsync(encoded.AsMemory(),deadline.Token).WaitAsync(deadline.Token);
            await ParserProcess.StandardInput.FlushAsync(deadline.Token).WaitAsync(deadline.Token);
            var line=await Program.ReadLineAsync(ParserProcess.StandardOutput,65536,deadline.Token).WaitAsync(deadline.Token);
            return JsonNode.Parse(line);
        }
        catch(Exception e)when(e is IOException or InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception or System.Text.Json.JsonException or InvalidDataException)
        {
            TryStopParser();
            return null;
        }
        finally
        {
            ParserLock.Release();
        }
    }

    private static void TryStopParser()
    {
        if(ParserProcess==null)return;
        try{if(!ParserProcess.HasExited)ParserProcess.Kill(true);}catch(Exception e)when(e is InvalidOperationException or System.ComponentModel.Win32Exception){}
        try{ParserProcess.Dispose();}catch{}
        ParserProcess=null;
    }
}

public static class ScopedRead
{
    private static readonly HashSet<string> Extensions=new(StringComparer.OrdinalIgnoreCase){
        ".txt",".md",".js",".cjs",".mjs",".ts",".tsx",".jsx",".json",".cs",".csproj",".sln",".slnx",".props",".targets",
        ".ps1",".psm1",".psd1",".py",".rs",".go",".java",".kt",".kts",".swift",".c",".cc",".cpp",".h",".hpp",
        ".sh",".bash",".bat",".cmd",".css",".scss",".sass",".less",".html",".vue",".svelte",".astro",
        ".csv",".yaml",".yml",".toml",".xml",".sql",".graphql",".gql",".proto",".svg",".patch",".diff"
    };
    private static readonly HashSet<string> SafeDotSegments=new(StringComparer.OrdinalIgnoreCase){
        ".agent",".agents",".github",".vscode",".devcontainer",
        ".gitignore",".gitattributes",".editorconfig",".prettierrc",".eslintrc",".prettierignore",".eslintignore"
    };
    public static bool IsSafe(string target,string cwd,string[] roots,bool allowGlob,bool listing)
    {
        try
        {
            if(string.IsNullOrWhiteSpace(target)||target.StartsWith('~')||target.StartsWith(@"\\")||target.Contains('[')||target.Contains(']')||target.Contains('`')||target.Contains('$'))return false;
            if(Regex.IsMatch(target,@"^[A-Za-z]:[^\\/]"))return false;
            var full=Path.GetFullPath(target,cwd);
            if(full[Path.GetPathRoot(full)!.Length..].Contains(':'))return false;
            var root=roots.Select(Path.GetFullPath).FirstOrDefault(r=>Inside(full,r));
            if(root==null||!Inside(Path.GetFullPath(cwd),root)||!CleanExisting(Path.GetFullPath(cwd)))return false;
            var relative=Path.GetRelativePath(root,full);
            var parts=relative.Split(new[]{'\\','/'},StringSplitOptions.RemoveEmptyEntries);
            if(parts.Any(Sensitive)||!CleanExisting(root))return false;
            if(!allowGlob&&parts.Any(p=>p.Contains('*')||p.Contains('?')))return false;
            var current=new List<string>{root};int scanned=0;
            for(int index=0;index<parts.Length;index++)
            {
                var part=parts[index];bool last=index==parts.Length-1;
                if(part==".")continue;
                var next=new List<string>();
                foreach(var parent in current)
                {
                    if(!Directory.Exists(parent))return false;
                    if(part.Contains('*')||part.Contains('?'))
                    {
                        foreach(var entry in Directory.EnumerateFileSystemEntries(parent))
                        {
                            if(++scanned>4096)return false;
                            if(!FileSystemName.MatchesSimpleExpression(part,Path.GetFileName(entry),true))continue;
                            if(!last&&!Directory.Exists(entry))continue;
                            if(Sensitive(Path.GetFileName(entry))||!CleanExisting(entry))return false;
                            next.Add(entry);
                        }
                    }
                    else
                    {
                        var entry=Path.Combine(parent,part);if(!CleanExisting(entry))return false;next.Add(entry);
                    }
                }
                if(next.Count==0)return false;current=next;
            }
            return current.Count>0&&current.All(p=>listing?(File.Exists(p)||Directory.Exists(p)):File.Exists(p)&&Extensions.Contains(Path.GetExtension(p)));
        }
        catch(Exception e)when(e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException){return false;}
    }
    public static bool IsSafeRecursiveListing(string target,string cwd,string[] roots,bool allowGlob)
    {
        try
        {
            var full=Path.GetFullPath(target,cwd);
            var root=roots.Select(Path.GetFullPath).FirstOrDefault(r=>Inside(full,r));
            if(root==null)return false;
            var startDir=allowGlob&&(full.Contains('*')||full.Contains('?'))?Path.GetDirectoryName(full):Directory.Exists(full)?full:Path.GetDirectoryName(full);
            if(startDir==null||!Inside(startDir,root)||!Directory.Exists(startDir)||!CleanExisting(startDir))return false;
            var queue=new Queue<string>();queue.Enqueue(startDir);int visited=0;
            while(queue.TryDequeue(out var dir))
            {
                if(++visited>4096)return false;
                foreach(var sub in Directory.EnumerateDirectories(dir))
                {
                    if((File.GetAttributes(sub)&FileAttributes.ReparsePoint)!=0)return false;
                    queue.Enqueue(sub);
                }
            }
            return true;
        }
        catch(Exception e)when(e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException){return false;}
    }
    public static bool IsSafeSkillDoc(string target)
    {
        try
        {
            if(string.IsNullOrWhiteSpace(target)||!Path.IsPathFullyQualified(target)||target.StartsWith(@"\\")||target.Contains('[')||target.Contains(']')||target.Contains('`')||target.Contains('$'))return false;
            var full=Path.GetFullPath(target);
            if(full[Path.GetPathRoot(full)!.Length..].Contains(':'))return false;
            var profile=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if(string.IsNullOrWhiteSpace(profile))return false;
            var skillRoots=new[]{
                Path.GetFullPath(Path.Combine(profile,".gemini","antigravity","builtin","skills")),
                Path.GetFullPath(Path.Combine(profile,".gemini","config","skills"))
            };
            var matchedRoot=skillRoots.FirstOrDefault(r=>Directory.Exists(r)&&Inside(full,r));
            if(matchedRoot==null||!File.Exists(full)||!CleanExisting(full))return false;
            var relative=Path.GetRelativePath(matchedRoot,full);
            var parts=relative.Split(new[]{'\\','/'},StringSplitOptions.RemoveEmptyEntries);
            if(parts.Length==0||parts.Any(Sensitive))return false;
            return Path.GetExtension(full).ToLowerInvariant() is (".md" or ".txt" or ".json");
        }
        catch(Exception e)when(e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException){return false;}
    }
    private static bool Inside(string path,string root)=>string.Equals(Path.TrimEndingDirectorySeparator(path),Path.TrimEndingDirectorySeparator(root),StringComparison.OrdinalIgnoreCase)
        ||path.StartsWith(Path.TrimEndingDirectorySeparator(root)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase);
    private static bool CleanExisting(string path)
    {
        for(string? p=path;p!=null;p=Path.GetDirectoryName(p))
            if((File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)return false;
        return true;
    }
    internal static bool Sensitive(string part)=>part!="."&&(part==".."||part.EndsWith('.')||part.EndsWith(' ')||(part.StartsWith('.')&&!SafeDotSegments.Contains(part))
        ||Regex.IsMatch(part,@"(?i)(secret|credential|password|private.?key|token|^id_[a-z0-9]+$|\.(pem|pfx|key|p12)$|^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$))",RegexOptions.CultureInvariant));
}
