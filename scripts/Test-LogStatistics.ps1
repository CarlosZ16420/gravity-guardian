$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskData=Join-Path $taskRoot ('.local/statistics-test/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $taskData 'logs') -Force|Out-Null
$taskRecords=@(
    @{event='review_completed';requestId='old';status='approved';assessmentText='{"outcome":"allow"}'},
    @{event='review_completed';requestId='a';status='approved';assessmentText='{"outcome":"allow"}'},
    @{event='review_completed';requestId='b';status='review_failed';decision='force_ask'},
    @{event='review_completed';requestId='c';status='review_failed'},
    @{event='review_completed';requestId='before-model';status='review_failed'},
    @{event='review_completed';requestId='native';status='delegated';decision='allow';route='native'},
    @{event='review_usage';requestId='a';at='2026-11-03T05:00:00Z';usage=@{status='reported';inputTokens=120;cachedInputTokens=80;outputTokens=12;reasoningOutputTokens=4;totalTokens=132}},
    @{event='review_usage';requestId='b';at='2026-11-03T05:01:00Z';usage=@{status='reported';inputTokens=200;cachedInputTokens=100;outputTokens=20;reasoningOutputTokens=$null;totalTokens=220}},
    @{event='review_usage';requestId='c';at='2026-11-03T05:02:00Z';usage=@{status='not_reported';inputTokens=$null;cachedInputTokens=$null;outputTokens=$null;reasoningOutputTokens=$null;totalTokens=$null}}
)
$taskRecords|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress}|Set-Content -LiteralPath (Join-Path $taskData 'logs/fixture.jsonl') -Encoding utf8
$taskReport=& (Join-Path $PSScriptRoot 'Analyze-Logs.ps1') -DataDirectory $taskData|ConvertFrom-Json
if($taskReport.tokenUsage.totalTokens -ne 352 -or $taskReport.tokenUsage.cachedInputTokens -ne 180){throw 'Token totals double counted or missing'}
if($taskReport.tokenUsage.totalTokensReportedInvocations -ne 2 -or $taskReport.tokenUsage.unknownOrPartialInvocations -ne 1 -or $taskReport.tokenUsage.completedRequestsWithoutUsageRecord -ne 3){throw 'Unknown or historical usage incorrectly counted'}
if($taskReport.tokenUsage.byDayUtc[0].totalTokens -ne 352){throw 'Daily token totals invalid'}
if($taskReport.humanHandoffs -ne 1){throw 'Human handoff was counted as a model denial or approval'}
if($taskReport.modelActivity.invocationsWithEvidence -ne 3 -or $taskReport.modelActivity.completedWithoutModelEvidence -ne 3 -or $taskReport.modelActivity.invocationsWithoutUsageRecord -ne 1){throw 'Hook requests were conflated with real model invocations, or usage and assessments were double counted'}
if($taskReport.nativeDelegations -ne 1 -or $taskReport.modelActivity.failedWithoutModelEvidence -ne 2 -or $taskReport.tokenUsage.modelInvocationsWithoutUsageRecord -ne 1 -or $taskReport.modelActivity.reviewerProcessesWithoutModelEvidence -ne 1){throw 'Native delegation was confused with a failed model call or unknown model usage'}
Write-Host 'PASS local token totals, daily aggregation, failed calls, and unknown historical usage'
$taskNewRecords=@(
    @{event='review_usage';requestId='startup-failed';at='2026-11-04T05:00:00Z';modelCallEvidence=$false;usage=@{status='not_reported';observedEvents=0}},
    @{event='review_completed';requestId='startup-failed';status='review_failed';decision='force_ask';reasonCode='reviewer_unavailable'},
    @{event='review_completed';requestId='blocked';status='blocked';decision='deny';reasonCode='repeated_denials';actionFingerprint='effect';conversationId='session'},
    @{event='review_completed';requestId='timeout';status='review_failed';decision='force_ask';reasonCode='review_timeout'},
    @{event='review_completed';requestId='escalated';status='escalated';decision='force_ask';reasonCode='policy_denied_user_authorized';assessmentText='{"outcome":"deny","risk_level":"critical","user_authorization":"high","rationale":"token egress"}'},
    @{event='review_completed';requestId='invalidated';status='approved';decision='auto_approve';reasonCode='policy_allowed'},
    @{event='review_completed';requestId='redirected';status='redirected';decision='deny';reasonCode='host_protected_redirect'},
    @{event='review_invalidated';requestId='invalidated';decision='deny';reasonCode='evidence_changed'}
)
$taskNewRecords|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress}|Add-Content -LiteralPath (Join-Path $taskData 'logs/fixture.jsonl') -Encoding utf8
$taskNewReport=& (Join-Path $PSScriptRoot 'Analyze-Logs.ps1') -DataDirectory $taskData|ConvertFrom-Json
if($taskNewReport.modelActivity.invocationsWithEvidence -ne 4 -or $taskNewReport.authorizedDenialEscalations -ne 1 -or $taskNewReport.hostProtectedRedirects -ne 1 -or $taskNewReport.humanHandoffs -ne 4 -or $taskNewReport.timeoutHandoffs -ne 1 -or $taskNewReport.repeatedDenialsBlocked -ne 1 -or $taskNewReport.otherTechnicalFailures -ne 5){throw 'v2 technical failures, escalations, redirects, block or process startup were miscounted'}
if($taskNewReport.approved -ne 2){throw 'Invalidated approval counted as applied'}
Write-Host 'PASS v2 reasons, incomplete process evidence and post-audit invalidation'
$taskRetryRecords=@(
    @{event='review_usage';requestId='retry-v050';at='2026-11-05T05:00:00Z';backend='native_guardian';attemptCount=2;usage=@{source='native_guardian.last_attempt_delta';status='reported';totalTokens=20}},
    @{event='review_usage';requestId='retry-partial';at='2026-11-05T05:00:01Z';backend='native_guardian';attemptCount=2;usage=@{source='native_guardian.attempt_deltas';status='partial';attempts=@(@{totalTokens=30})}},
    @{event='review_usage';requestId='retry-complete';at='2026-11-05T05:00:02Z';backend='native_guardian';attemptCount=2;usage=@{source='native_guardian.attempt_deltas';status='reported';totalTokens=55}}
)
$taskRetryRecords|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress}|Set-Content -LiteralPath (Join-Path $taskData 'logs/2026-11-05.000.jsonl') -Encoding utf8
$taskRetryReport=& (Join-Path $PSScriptRoot 'Analyze-Logs.ps1') -DataDirectory $taskData -UtcDate '2026-11-05'|ConvertFrom-Json
if($taskRetryReport.tokenUsage.totalTokens -ne 55 -or $taskRetryReport.tokenUsage.byDayUtc[0].totalTokens -ne 55 -or $taskRetryReport.byReviewerTransport[0].tokens.totalTokens -ne 55){throw 'Retry telemetry double counted or treated a partial report as complete'}
if($taskRetryReport.tokenUsage.legacyLastAttemptOnlyInvocations -ne 1 -or $taskRetryReport.tokenUsage.unknownOrPartialInvocations -ne 2){throw 'Incomplete historical retry usage lost'}
Write-Host 'PASS only complete review totals are included in retry token aggregation'

# Use the production post writer, then exercise the distributed script through a
# Lite layout. Runtime selection and compaction remain production code.
. (Join-Path $PSScriptRoot 'Review-Mode.ps1')
$taskCompactFixture=Join-Path $taskData 'script-entry'
$taskCompactBundle=Join-Path $taskCompactFixture 'lite'
$taskCompactData=Join-Path $taskCompactFixture 'data'
$taskCoreScripts=@((Join-Path $taskRoot 'src/AgApproval/bin/Release/net10.0'),(Join-Path $taskRoot 'artifacts/gravity-guardian/scripts')) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'gravity-guardian.dll') } | Select-Object -First 1
if (!$taskCoreScripts) { throw 'Build the C# service before running the script compaction regression' }
$taskDotnet=Join-Path (Split-Path $taskRoot -Parent) '.tools/dotnet/dotnet.exe'
if (!(Test-Path -LiteralPath $taskDotnet)) { $taskDotnet=(Get-Command dotnet.exe).Source }
$taskCoreAssembly=Join-Path $taskCoreScripts 'gravity-guardian.dll'
New-Item -ItemType Directory -Path (Join-Path $taskCompactBundle 'scripts'),(Join-Path $taskCompactBundle 'sidecars/reviewer') -Force | Out-Null
foreach ($name in @('Compact-Logs.ps1','Review-Mode.ps1','Portable.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $taskCompactBundle 'scripts') }
Get-ChildItem -LiteralPath $taskCoreScripts -Filter 'gravity-guardian.*' -File | Copy-Item -Destination (Join-Path $taskCompactBundle 'scripts')
@{type='lite'} | ConvertTo-Json | Set-Utf8NoBom -LiteralPath (Join-Path $taskCompactBundle 'distribution.json')
@{command=$taskDotnet} | ConvertTo-Json | Set-Utf8NoBom -LiteralPath (Join-Path $taskCompactBundle 'sidecars/reviewer/sidecar.json')
$taskPostConfig=Join-Path $taskCompactFixture 'approval.json'
@{dataDirectory=$taskCompactData;enableDetailedLogs=$true;policyDirectory=(Join-Path $taskRoot 'policy/effective-codex');codexHome=(Join-Path $taskCompactFixture 'codex');antigravityConfigDirectory=(Join-Path $taskCompactFixture 'config');transcriptRoots=@((Join-Path $taskCompactFixture 'brain'));guardianPath=$env:ComSpec} |
    ConvertTo-Json -Depth 8 | Set-Utf8NoBom -LiteralPath $taskPostConfig
foreach ($step in @(1,2)) {
    @{conversationId='synthetic-post';stepIdx=$step;toolCall=@{name='write_file';args=@{event=$(if ($step -eq 1) {'review_context'} else {'ordinary_control'});content=('x'*10000)}}} |
        ConvertTo-Json -Depth 8 -Compress | & $taskDotnet $taskCoreAssembly post --config $taskPostConfig | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic production post failed' }
}
$taskSegments=@(Get-ChildItem -LiteralPath (Join-Path $taskCompactData 'logs') -Filter '*.jsonl' -File)
if ($taskSegments.Count -ne 1) { throw 'Unexpected production post segment count' }
$taskCompactLog=Join-Path $taskCompactData 'logs/fixture.000.jsonl'
Move-Item -LiteralPath $taskSegments[0].FullName -Destination $taskCompactLog
$beforeHash=(Get-FileHash -LiteralPath $taskCompactLog).Hash
& (Join-Path $taskCompactBundle 'scripts/Compact-Logs.ps1') -DataDirectory $taskCompactData -PlanOnly | Out-Null
if ((Get-FileHash -LiteralPath $taskCompactLog).Hash -cne $beforeHash) { throw 'Compaction preview wrote the log' }
$result=& (Join-Path $taskCompactBundle 'scripts/Compact-Logs.ps1') -DataDirectory $taskCompactData | ConvertFrom-Json
$retained=@(Get-Content -LiteralPath $taskCompactLog | ForEach-Object { $_ | ConvertFrom-Json })
if ($result.keptEvents -ne 2 -or $result.droppedVerboseDumps -ne 0 -or $retained.Count -ne 2 -or
    $retained[0].event -cne 'tool_completed' -or $retained[1].event -cne 'tool_completed' -or $retained[0].stepIdx -ne 1 -or $retained[1].stepIdx -ne 2 -or $retained[0].payload -or $retained[1].payload) { throw 'Script entry lost a top-level production post record or failed to remove its verbose payload' }
Write-Host 'PASS R05 script uses Lite system runtime and core compactor; preview is read-only and nested event fields never delete top-level production post records'
