using System.Text.Json;

namespace AgApproval;

// Antigravity exposes tool steps, but no verified business-turn identity. Persist
// only the actual verdict for a duplicate of the same bound request.
public sealed class DenialGuard : IAsyncDisposable
{
    public const string Version="bound-request-v2";
    private readonly string path;
    private readonly FileStream lease;
    private readonly State state;

    private DenialGuard(string path,FileStream lease,State state)
    {this.path=path;this.lease=lease;this.state=state;}

    private static string DirectoryFor(Settings settings)=>Path.Combine(settings.DataDirectory,"denial-guard",Version);
    public static async Task<DenialGuard> AcquireAsync(Settings settings,ReviewInput input,string policyHash,CancellationToken ct)
    {
        var directory=DirectoryFor(settings);
        Directory.CreateDirectory(directory);
        ReviewContext.ValidateComponents(directory);
        var key=Json.Hash(Json.Encode(new{input.Conversation,input.StepIndex,input.ActionFingerprint,input.MaterialRevision,input.AuthorizationRevision,input.EvidenceRevision,policyHash,adapter=ReviewAdapter.Hash}));
        var path=Path.Combine(directory,key+".json");
        FileStream? lease=null;
        try
        {
            var lockPath=Path.Combine(directory,"state.lock");
            if(File.Exists(lockPath))ReviewContext.ValidateComponents(lockPath);
            int lockAttempt=0;
            while(lease==null)
            {
                ct.ThrowIfCancellationRequested();
                try{lease=new FileStream(lockPath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);}
                catch(IOException e)when((e.HResult&0xffff) is 32 or 33){await Task.Delay(25,ct);}
                catch(UnauthorizedAccessException)when(lockAttempt++<40){await Task.Delay(25,ct);}
            }
            var state=File.Exists(path)?Read(path):new State();
            var guard=new DenialGuard(path,lease,state);
            if(state.PendingRequest!=null)
            {
                state.InterruptedRequest=state.PendingRequest;
                state.PendingRequest=null;
                state.LastOutcome="unknown";
                await guard.SaveAsync(ct);
            }
            return guard;
        }
        catch{lease?.Dispose();throw;}
    }

    private static State Read(string path)
    {
        ReviewContext.ValidateComponents(path);
        if(new FileInfo(path).Length>131072)throw new InvalidDataException("Request verdict record exceeds limit");
        return JsonSerializer.Deserialize<State>(File.ReadAllText(path),Json.Options)??throw new InvalidDataException("Invalid request verdict record");
    }

    public bool IsBlocked(ReviewInput input)=>state.DenialReason!=null;
    public string? RecordedReason(ReviewInput input)=>state.DenialReason;
    public bool IsEscalated(ReviewInput input)=>state.EscalationRationale!=null;
    public string? RecordedEscalationRisk=>state.EscalationRisk;
    public string? RecordedEscalationRationale=>state.EscalationRationale;
    public string? RecordedEscalationDenialReason=>state.EscalationDenialReason;
    public bool HasPending=>state.PendingRequest!=null;
    public async Task BeginAsync(ReviewInput input,CancellationToken ct){state.PendingRequest=input.Id;await SaveAsync(ct);}
    public async Task CancelPendingAsync(CancellationToken ct){state.PendingRequest=null;state.LastOutcome="aborted";await SaveAsync(ct);}
    public object Snapshot()=>new{version=Version,scope="bound_request",state.LastOutcome,state.InterruptedRequest,denied=state.DenialReason!=null,escalated=state.EscalationRationale!=null};
    public static object Diagnostics(Settings settings)
    {
        var dir=DirectoryFor(settings);
        if(!Directory.Exists(dir))return new{scopes=0,trippedScopes=0,interruptedScopes=0,invalidScopes=0};
        int samples=0,denials=0,invalid=0,interrupted=0;
        foreach(var file in Directory.EnumerateFiles(dir,"*.json").Take(128))
        {
            samples++;
            try{var saved=Read(file);if(saved.DenialReason!=null)denials++;if(saved.PendingRequest!=null)interrupted++;}
            catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException or InvalidDataException){invalid++;}
        }
        return new{scopes=samples,trippedScopes=denials,interruptedScopes=interrupted,invalidScopes=invalid};
    }

    public async Task RecordAsync(ReviewInput input,bool allowed,string reason,CancellationToken ct)
    {
        if(!allowed)state.DenialReason=reason;
        state.LastOutcome=allowed?"allow":"deny";
        state.PendingRequest=null;
        await SaveAsync(ct);
    }

    public async Task RecordAsync(ReviewInput input,GateResponse finalResult,GateResponse policyResult,CancellationToken ct)
    {
        if(finalResult.ReasonCode=="policy_denied_user_authorized")
        {
            state.DenialReason=null;
            state.EscalationRisk=policyResult.Risk??finalResult.Risk??"high";
            state.EscalationRationale=policyResult.Rationale??finalResult.Rationale??finalResult.Reason;
            state.EscalationDenialReason=policyResult.Reason;
            state.LastOutcome="escalated";
        }
        else if(finalResult.Decision!="auto_approve")
        {
            state.DenialReason=finalResult.Reason;
            state.LastOutcome="deny";
        }
        else
        {
            state.LastOutcome="allow";
        }
        state.PendingRequest=null;
        await SaveAsync(ct);
    }

    private async Task SaveAsync(CancellationToken ct)
    {
        var temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary,Json.Encode(state),ct);
            for(int attempt=0;;attempt++)
            {
                try{File.Move(temporary,path,true);break;}
                catch(Exception e)when((e is IOException or UnauthorizedAccessException)&&attempt<20){await Task.Delay(15,ct);}
            }
        }
        finally{try{if(File.Exists(temporary))File.Delete(temporary);}catch(Exception e)when(e is IOException or UnauthorizedAccessException){}}
    }

    public ValueTask DisposeAsync(){lease.Dispose();return ValueTask.CompletedTask;}
    public sealed class State
    {
        public string? PendingRequest{get;set;}
        public string? InterruptedRequest{get;set;}
        public string? LastOutcome{get;set;}
        public string? DenialReason{get;set;}
        public string? EscalationRisk{get;set;}
        public string? EscalationRationale{get;set;}
        public string? EscalationDenialReason{get;set;}
    }
}
