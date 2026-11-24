using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public static class ReviewEvidence
{
    public const string Version="bounded-evidence-v1";
    public static (JsonArray Selected, List<int> Omitted) Select(IEnumerable<JsonObject> evidence, Settings settings, int availableBytes)
    {
        var selected=new List<JsonObject>();var omitted=new List<int>();int bytes=2;
        int budget=Math.Min(settings.MaxEvidenceBytes,Math.Max(0,availableBytes));
        foreach(var record in evidence.Reverse())
        {
            var copy=(JsonObject)record.DeepClone();
            var content=Json.Text(copy,"content");
            if(content!=null&&Encoding.UTF8.GetByteCount(content)>settings.MaxEvidenceContentBytes)
            {
                copy["content"]=Utf8Prefix(content,settings.MaxEvidenceContentBytes);
                copy["truncation"]!["bridge_content_truncated"]=true;
            }
            int cost=Encoding.UTF8.GetByteCount(copy.ToJsonString(Json.PromptOptions))+1;
            if(selected.Count>=settings.MaxEvidenceRecords||bytes+cost>budget){omitted.Add(record["native_position"]!.GetValue<int>());continue;}
            selected.Add(copy);bytes+=cost;
        }
        return(new JsonArray(selected.OrderBy(r=>r["native_position"]!.GetValue<int>()).Select(r=>(JsonNode)r).ToArray()),omitted);
    }
    public static string Utf8Prefix(string text,int maxBytes)
    {
        int bytes=0,characters=0;
        foreach(var rune in text.EnumerateRunes())
        {if(bytes+rune.Utf8SequenceLength>maxBytes)break;bytes+=rune.Utf8SequenceLength;characters+=rune.Utf16SequenceLength;}
        return text[..characters];
    }
}
