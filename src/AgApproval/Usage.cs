using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Diagnostics;

namespace AgApproval;

public sealed class CliUsage
{
    private readonly JsonArray reports = new();
    private bool limited;
    private readonly Stopwatch watch = Stopwatch.StartNew();
    private readonly TaskCompletionSource<bool> terminal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private string? candidateAssessment;
    private long? firstOutputMs, completedMs;
    private int parsedEvents;
    private string? lastEventType, lastItemType;
    public Task<bool> Completion => terminal.Task;
    public string? CompletedAssessment { get; private set; }
    public bool HasTurnFailure { get; private set; }
    public bool HasStartedTurn { get; private set; }
    public string? TerminalError { get; private set; }
    public string? ThreadId { get; private set; }
    public bool ThreadIdConflict { get; private set; }

    // Drain all stdout, retaining only small native turn.completed usage objects.
    // Large item/message events are discarded without buffering the entire line.
    public async Task ReadAsync(StreamReader reader)
    {
        var buffer = new char[4096];
        var line = new StringBuilder();
        bool oversized = false;
        int count;
        while ((count = await reader.ReadAsync(buffer)) != 0)
        {
            firstOutputMs ??= watch.ElapsedMilliseconds;
            for (int i = 0; i < count; i++)
            {
                var c = buffer[i];
                if (c == '\n')
                {
                    if (!oversized) Observe(line.ToString());
                    line.Clear(); oversized = false;
                }
                else if (!oversized)
                {
                    if (line.Length >= 65536) { line.Clear(); oversized = true; }
                    else line.Append(c);
                }
            }
        }
        if (!oversized && line.Length > 0) Observe(line.ToString());
    }

    public void Observe(string line)
    {
        try
        {
            var value = JsonNode.Parse(line);
            if (value is not JsonObject) return;
            parsedEvents++;
            var type = Json.Text(value, "type");
            if(type=="thread.started")
            {
                var id=Json.Text(value,"thread_id");
                if(!Guid.TryParse(id,out _)||ThreadId!=null&&ThreadId!=id)ThreadIdConflict=true;
                else ThreadId=id;
            }
            lastEventType = type;
            if (value["item"] is JsonObject) lastItemType = Json.Text(value["item"], "type");
            if (type == "turn.started") { HasStartedTurn=true;candidateAssessment = null; CompletedAssessment = null; }
            if (type == "item.completed" && Json.Text(value["item"], "type") == "agent_message")
            {
                candidateAssessment = null;
                var text = Json.Text(value["item"], "text");
                candidateAssessment = text != null && Encoding.UTF8.GetByteCount(text) <= 16384 ? text : null;
            }
            if (type == "turn.failed") {
                HasTurnFailure=true;var error=Json.Text(value["error"],"message");TerminalError=error is {Length:>2048}?error[..2048]:error;
                terminal.TrySetResult(false);
            }
            if (type != "turn.completed") return;
            CompletedAssessment = candidateAssessment;
            completedMs = watch.ElapsedMilliseconds;
            terminal.TrySetResult(true);
            if (reports.Count >= 32) { limited = true; return; }
            // Preserve the CLI's original usage fields. Null or unrecognized usage is unknown, never zero.
            reports.Add(value["usage"]?.DeepClone());
        }
        catch (JsonException) { }
        catch (InvalidOperationException) { }
    }

    public object Diagnostics() => new { firstOutputMs, turnCompletedMs = completedMs, parsedEvents, lastEventType, lastItemType,
        completedAssessmentCaptured = CompletedAssessment != null, turnFailed = HasTurnFailure,terminalError=TerminalError };

    public JsonObject Snapshot()
    {
        long input = 0, output = 0, cached = 0, reasoning = 0;
        int valid = 0;
        bool cachedComplete = true, reasoningComplete = true;
        foreach (var report in reports)
        {
            if (!Count(report, "input_tokens", out var i) || !Count(report, "output_tokens", out var o)) continue;
            try
            {
                var nextInput = checked(input + i); var nextOutput = checked(output + o);
                _ = checked(nextInput + nextOutput);
                input = nextInput; output = nextOutput; valid++;
                if (Count(report, "cached_input_tokens", out var c) && c <= i) cached = checked(cached + c);
                else cachedComplete = false;
                if (Count(report, "reasoning_output_tokens", out var r) && r <= o) reasoning = checked(reasoning + r);
                else reasoningComplete = false;
            }
            catch (OverflowException) { limited = true; }
        }
        return new JsonObject {
            ["source"] = "codex_exec.turn.completed",
            ["status"] = reports.Count == 0 ? "not_reported" : valid == 0 ? "invalid" : valid == reports.Count && !limited ? "reported" : "partial",
            ["reportedTurns"] = valid, ["observedEvents"] = reports.Count, ["captureLimited"] = limited,
            ["inputTokens"] = valid > 0 ? JsonValue.Create(input) : null,
            ["cachedInputTokens"] = valid > 0 && cachedComplete ? JsonValue.Create(cached) : null,
            ["outputTokens"] = valid > 0 ? JsonValue.Create(output) : null,
            ["reasoningOutputTokens"] = valid > 0 && reasoningComplete ? JsonValue.Create(reasoning) : null,
            // Cached input is already part of input; reasoning is already part of output.
            ["totalTokens"] = valid > 0 ? JsonValue.Create(input + output) : null,
            ["rawUsageReports"] = reports.DeepClone()
        };
    }

    // exec 0.166 emits ThreadTokenUsage.total even after resume. Keep those
    // native reports intact, but aggregate only this invocation's counter delta.
    public static JsonObject SessionDelta(JsonObject current,JsonObject previous)
    {
        var result=(JsonObject)current.DeepClone();
        result["source"]="codex_exec.turn.completed.cumulative_difference";
        result["rawCounterSemantics"]="session_cumulative";
        var delta=new JsonObject();
        foreach(var (field,wire) in new[]{("inputTokens","input_tokens"),("cachedInputTokens","cached_input_tokens"),("outputTokens","output_tokens"),("reasoningOutputTokens","reasoning_output_tokens")})
        {
            if(current[field]==null||previous[field]==null){result[field]=null;continue;}
            var difference=checked(current[field]!.GetValue<long>()-previous[field]!.GetValue<long>());
            if(difference<0)throw new InvalidDataException("CLI cumulative usage counters regressed");
            result[field]=difference;delta[wire]=difference;
        }
        if(result["inputTokens"]==null||result["outputTokens"]==null)throw new InvalidDataException("CLI cumulative usage baseline unavailable");
        if(result["cachedInputTokens"]?.GetValue<long>()>result["inputTokens"]!.GetValue<long>()||result["reasoningOutputTokens"]?.GetValue<long>()>result["outputTokens"]!.GetValue<long>())throw new InvalidDataException("Invalid CLI cumulative usage delta");
        result["totalTokens"]=checked(result["inputTokens"]!.GetValue<long>()+result["outputTokens"]!.GetValue<long>());
        result["deltaUsageReports"]=new JsonArray(delta);
        return result;
    }

    private static bool Count(JsonNode? node, string key, out long count)
    {
        count = 0;
        return node is JsonObject obj && obj[key] is JsonValue value && value.TryGetValue(out count) && count >= 0;
    }
}

public sealed class BoundedTextCapture(int limit = 8192)
{
    private readonly StringBuilder tail = new();
    private long characters;
    public async Task ReadAsync(StreamReader reader)
    {
        var buffer = new char[4096]; int count;
        while ((count = await reader.ReadAsync(buffer)) != 0)
        {
            characters += count; tail.Append(buffer, 0, count);
            if (tail.Length > limit) tail.Remove(0, tail.Length - limit);
        }
    }
    public object Snapshot() => new { characters, truncated = characters > limit, tail = tail.ToString() };
}
