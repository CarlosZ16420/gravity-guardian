[CmdletBinding()]
param([string]$DataDirectory=(Join-Path $env:USERPROFILE '.gemini/gravity-guardian-data'),[ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$UtcDate)
$ErrorActionPreference='Stop'
$taskLogs=Join-Path $DataDirectory 'logs'
$taskRecords=[Collections.Generic.List[object]]::new()
$taskInvalid=0
$taskFilter=if($UtcDate){$UtcDate+'*.jsonl'}else{'*.jsonl'}
foreach($taskFile in Get-ChildItem -LiteralPath $taskLogs -Filter $taskFilter | Sort-Object Name){
    foreach($taskLine in [IO.File]::ReadLines($taskFile.FullName)){
        if(!$taskLine.Trim()){continue}
        try{$taskRecords.Add(($taskLine|ConvertFrom-Json))}catch{$taskInvalid++}
    }
}
$taskCompleted=@($taskRecords|Where-Object event -eq 'review_completed')
# Preserve the original audit event, but count the final invalidation as the applied result.
foreach($taskInvalidation in @($taskRecords|Where-Object event -eq 'review_invalidated')){
    foreach($taskEntry in @($taskCompleted|Where-Object requestId -eq $taskInvalidation.requestId)){
        $taskEntry.status='review_failed';$taskEntry.decision=$taskInvalidation.decision;$taskEntry.reasonCode=$taskInvalidation.reasonCode
    }
}
$taskDurations=@($taskCompleted|Where-Object {$null -ne $_.elapsedMs}|ForEach-Object {[double]$_.elapsedMs}|Sort-Object)
$taskP95=if($taskDurations.Count){$taskDurations[[Math]::Max(0,[Math]::Ceiling($taskDurations.Count*0.95)-1)]}else{$null}
$taskUsage=@($taskRecords|Where-Object event -eq 'review_usage')
$taskNativeUsage=@($taskUsage|Where-Object backend -eq 'native_guardian')
$taskLegacySet=[Collections.Generic.HashSet[object]]::new()
$taskLegacyLastAttempt=@($taskNativeUsage|Where-Object {$_.usage.source -eq 'native_guardian.last_attempt_delta' -and $_.attemptCount -ne 1})
foreach($taskItem in $taskLegacyLastAttempt){[void]$taskLegacySet.Add($taskItem)}
$taskCountableUsage=@($taskUsage|Where-Object {!$taskLegacySet.Contains($_)})
$taskKnownDispatches=@($taskNativeUsage|ForEach-Object { if($null -ne $_.inferenceDispatchCount){[long]$_.inferenceDispatchCount}elseif($null -ne $_.inferenceRequests){[long]$_.inferenceRequests} })
$taskKnownAttempts=@($taskNativeUsage|ForEach-Object { if($null -ne $_.attemptCount){[long]$_.attemptCount} })
$taskKnownHttp=@($taskNativeUsage|ForEach-Object { if($null -ne $_.httpRequestCount){[long]$_.httpRequestCount} })
$taskHookResults=@($taskRecords|Where-Object event -eq 'hook_decision')
$taskPosts=@($taskRecords|Where-Object event -eq 'tool_completed')
$taskHookBindings=@{}
foreach($taskEvent in $taskHookResults){
    if(!$taskEvent.conversationId -or $null -eq $taskEvent.stepIdx -or !$taskEvent.toolIdentity){continue}
    $taskKey="$($taskEvent.conversationId)|$($taskEvent.stepIdx)|$($taskEvent.toolIdentity)"
    if(!$taskHookBindings.ContainsKey($taskKey)){$taskHookBindings[$taskKey]=[Collections.Generic.List[object]]::new()}
    $taskHookBindings[$taskKey].Add($taskEvent)
}
$taskCorrelated=@(foreach($taskEvent in $taskPosts){
    if(!$taskEvent.conversationId -or $null -eq $taskEvent.stepIdx -or !$taskEvent.toolIdentity){continue}
    $taskKey="$($taskEvent.conversationId)|$($taskEvent.stepIdx)|$($taskEvent.toolIdentity)"
    if($taskHookBindings.ContainsKey($taskKey) -and $taskHookBindings[$taskKey].Count -eq 1){
        $taskPre=$taskHookBindings[$taskKey][0]
        if([DateTimeOffset]$taskPre.at -le [DateTimeOffset]$taskEvent.at){
            @{requestId=$taskPre.requestId;hookDecision=$taskPre.hookDecision;hadError=$taskEvent.hadError}
        }
    }
})
function Get-TokenTotals([object[]]$Entries){
    $taskTotals=@{}
    foreach($taskField in @('inputTokens','cachedInputTokens','outputTokens','reasoningOutputTokens','totalTokens')){
        $taskValues=@($Entries|ForEach-Object{if($null -ne $_.usage.$taskField){[decimal]$_.usage.$taskField}})
        $taskTotals[$taskField]=if($taskValues.Count){($taskValues|Measure-Object -Sum).Sum}else{$null}
        $taskTotals[$taskField+'ReportedInvocations']=$taskValues.Count
    }
    return $taskTotals
}
$taskUsageIdSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($taskItem in $taskUsage){if($taskItem.requestId){[void]$taskUsageIdSet.Add([string]$taskItem.requestId)}}
$taskUsageWithModelEvidence=@($taskUsage|Where-Object {$_.modelCallEvidence -eq $true -or $_.usage.observedEvents -gt 0 -or $_.usage.reportedTurns -gt 0 -or $null -ne $_.usage.totalTokens})
# A received/completed hook is not necessarily a model call. Older versions have
# assessments but no usage events; combine both evidence sources without double counting.
$taskModelIdSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($taskItem in $taskUsageWithModelEvidence){if($taskItem.requestId){[void]$taskModelIdSet.Add([string]$taskItem.requestId)}}
foreach($taskItem in $taskCompleted){if(![string]::IsNullOrWhiteSpace($taskItem.assessmentText) -and $taskItem.requestId){[void]$taskModelIdSet.Add([string]$taskItem.requestId)}}
$taskModelIds=@($taskModelIdSet|Sort-Object)
$taskModelCompleted=@($taskCompleted|Where-Object{$_.requestId -and $taskModelIdSet.Contains([string]$_.requestId)})
$taskModelActivity=@{
    invocationsWithEvidence=$taskModelIds.Count
    approved=@($taskModelCompleted|Where-Object status -eq 'approved').Count
    denied=@($taskModelCompleted|Where-Object status -eq 'denied').Count
    humanHandoffs=@($taskModelCompleted|Where-Object {$_.decision -in 'force_ask','ask'}).Count
    authorizedDenialEscalations=@($taskModelCompleted|Where-Object reasonCode -eq 'policy_denied_user_authorized').Count
    completedWithoutModelEvidence=@($taskCompleted|Where-Object{!$_.requestId -or !$taskModelIdSet.Contains([string]$_.requestId)}).Count
    nativeDelegations=@($taskCompleted|Where-Object status -eq 'delegated').Count
    timeoutHandoffs=@($taskCompleted|Where-Object reasonCode -eq 'review_timeout').Count
    otherTechnicalFailures=@($taskCompleted|Where-Object {$_.status -eq 'review_failed' -and $_.reasonCode -ne 'review_timeout'}).Count
    repeatedDenialsBlocked=@($taskCompleted|Where-Object reasonCode -eq 'repeated_denials').Count
    reasonUnknown=@($taskCompleted|Where-Object {[string]::IsNullOrWhiteSpace($_.reasonCode)}).Count
    bindingUnknown=@($taskCompleted|Where-Object {[string]::IsNullOrWhiteSpace($_.actionFingerprint)}).Count
    reviewerProcessesWithoutModelEvidence=@($taskUsage|Where-Object {!$_.requestId -or !$taskModelIdSet.Contains([string]$_.requestId)}).Count
    failedWithoutModelEvidence=@($taskCompleted|Where-Object{$_.status -eq 'review_failed' -and (!$_.requestId -or !$taskModelIdSet.Contains([string]$_.requestId))}).Count
    invocationsWithoutUsageRecord=@($taskModelIds|Where-Object{!$taskUsageIdSet.Contains([string]$_)}).Count
    meanMilliseconds=$( $taskModelElapsed=@($taskModelCompleted|Where-Object {$null -ne $_.elapsedMs}|ForEach-Object {[double]$_.elapsedMs}); if($taskModelElapsed.Count){($taskModelElapsed|Measure-Object -Average).Average}else{$null} )
    cumulativeMilliseconds=$( $taskModelElapsed=@($taskModelCompleted|Where-Object {$null -ne $_.elapsedMs}|ForEach-Object {[double]$_.elapsedMs}); if($taskModelElapsed.Count){($taskModelElapsed|Measure-Object -Sum).Sum}else{0} )
    nativeGuardianInferenceDispatches=($taskKnownDispatches|Measure-Object -Sum).Sum
    nativeGuardianAttempts=if($taskKnownAttempts.Count){($taskKnownAttempts|Measure-Object -Sum).Sum}else{$null}
    nativeGuardianAttemptObservations=$taskKnownAttempts.Count
    nativeGuardianHttpRequests=if($taskKnownHttp.Count){($taskKnownHttp|Measure-Object -Sum).Sum}else{$null}
    nativeGuardianHttpCountObservations=$taskKnownHttp.Count
    nativeGuardianReviews=@($taskUsage|Where-Object backend -eq 'native_guardian').Count
    nativeGuardianUnknownInferenceCounts=@($taskNativeUsage|Where-Object {$_.requestSubmitted -and $null -eq $_.inferenceRequests -and $null -eq $_.inferenceDispatchCount}).Count
    note='Model invocation evidence is reported usage, a counted inference dispatch, or an original assessment, not a hook receipt. Failed inference may have unknown usage. Cumulative duration may overlap across conversations.'
}
$taskTokenReport=Get-TokenTotals $taskCountableUsage
$taskTokenReport.source='Reported complete native attempt totals and verified CLI usage. Older native last-attempt-only records with other than one known attempt are excluded.'
$taskTokenReport.recordedInvocations=$taskUsage.Count
$taskTokenReport.fullyReportedInvocations=@($taskCountableUsage|Where-Object {$_.usage.status -eq 'reported'}).Count
$taskTokenReport.unknownOrPartialInvocations=$taskUsage.Count-$taskTokenReport.fullyReportedInvocations
$taskTokenReport.legacyLastAttemptOnlyInvocations=$taskLegacyLastAttempt.Count
$taskTokenReport.completedRequestsWithoutUsageRecord=@($taskCompleted|Where-Object {!$_.requestId -or !$taskUsageIdSet.Contains([string]$_.requestId)}).Count
$taskTokenReport.modelInvocationsWithoutUsageRecord=$taskModelActivity.invocationsWithoutUsageRecord
$taskTokenReport.note='Cached input is included in input; reasoning is included in output. Total=input+output. Missing usage is unknown, not zero. Historical requests without usage cannot be reconstructed, and token counts are not ChatGPT quota percentages.'
$taskTokenReport.byDayUtc=@($taskUsage|Group-Object {([DateTimeOffset]$_.at).UtcDateTime.ToString('yyyy-MM-dd')}|Sort-Object Name|ForEach-Object{
    $taskDay=Get-TokenTotals @($_.Group|Where-Object {!$taskLegacySet.Contains($_)})
    $taskDay.date=$_.Name
    $taskDay.recordedInvocations=$_.Count
    $taskDay
})
$taskReport=@{
    logDirectory=$taskLogs;utcDate=$UtcDate;recordCount=$taskRecords.Count;invalidLines=$taskInvalid
    received=@($taskRecords|Where-Object event -eq 'review_received').Count
    completed=$taskCompleted.Count;approved=@($taskCompleted|Where-Object status -eq 'approved').Count
    denied=@($taskCompleted|Where-Object status -eq 'denied').Count
    reviewFailed=@($taskCompleted|Where-Object status -eq 'review_failed').Count
    humanHandoffs=@($taskCompleted|Where-Object {$_.decision -in 'force_ask','ask'}).Count
    authorizedDenialEscalations=@($taskCompleted|Where-Object reasonCode -eq 'policy_denied_user_authorized').Count
    nativeAskHandoffs=@($taskCompleted|Where-Object decision -eq 'ask').Count
    hostProtectedRedirects=@($taskCompleted|Where-Object reasonCode -eq 'host_protected_redirect').Count
    duplicateDeniedRequests=@($taskCompleted|Where-Object reasonCode -eq 'duplicate_policy_denial').Count
    byReasonCode=@($taskCompleted|Group-Object reasonCode|ForEach-Object{@{reasonCode=$(if($_.Name){$_.Name}else{'unknown'});requests=$_.Count}})
    byHookDecision=@($taskHookResults|Group-Object hookDecision|ForEach-Object{@{decision=$_.Name;requests=$_.Count}})
    nativeRecoveryFailures=@($taskNativeUsage|ForEach-Object{$_.diagnostics.sampling}|Where-Object event -eq 'guardian_attempt_failed'|
        Group-Object {$_.failure.reasonCode}|ForEach-Object{@{reasonCode=$_.Name;attempts=$_.Count}})
    telemetryInvalid=@($taskUsage|Where-Object {$_.usage.status -in 'invalid','telemetry_invalid'}).Count
    postToolUse=@{received=$taskPosts.Count;uniquelyCorrelated=$taskCorrelated.Count;correlatedWithoutError=@($taskCorrelated|Where-Object {$_.hadError -eq $false}).Count}
    nativeDelegations=@($taskCompleted|Where-Object status -eq 'delegated').Count
    timeoutHandoffs=@($taskCompleted|Where-Object reasonCode -eq 'review_timeout').Count
    otherTechnicalFailures=@($taskCompleted|Where-Object {$_.status -eq 'review_failed' -and $_.reasonCode -ne 'review_timeout'}).Count
    repeatedDenialsBlocked=@($taskCompleted|Where-Object reasonCode -eq 'repeated_denials').Count
    hookFailures=@($taskRecords|Where-Object event -eq 'hook_review_failed').Count
    p95Milliseconds=$taskP95
    tokenUsage=$taskTokenReport
    modelActivity=$taskModelActivity
    byReviewerTransport=@($taskUsage|Group-Object {if($_.backend -eq 'native_guardian'){'native_guardian'}elseif($_.process.transportMode){$_.process.transportMode}else{'legacy_unknown'}}|ForEach-Object{@{mode=$_.Name;invocations=$_.Count;tokens=(Get-TokenTotals @($_.Group|Where-Object {!$taskLegacySet.Contains($_)}))}})
    byTool=@($taskCompleted|Group-Object tool|ForEach-Object{@{tool=$_.Name;requests=$_.Count;approved=@($_.Group|Where-Object status -eq 'approved').Count;denied=@($_.Group|Where-Object status -eq 'denied').Count;escalated=@($_.Group|Where-Object status -eq 'escalated').Count;failed=@($_.Group|Where-Object status -eq 'review_failed').Count;delegated=@($_.Group|Where-Object status -eq 'delegated').Count}})
    repeatedActions=@($taskCompleted|Where-Object {$_.actionFingerprint}|Group-Object { $_.conversationId+'|'+$_.actionFingerprint }|Where-Object Count -gt 1|Sort-Object Count -Descending|Select-Object -First 10|ForEach-Object{@{conversationId=$_.Group[0].conversationId;actionFingerprint=$_.Group[0].actionFingerprint;count=$_.Count}})
    legacyRepeatedActions=@($taskCompleted|Where-Object {!$_.actionFingerprint -and $_.actionHash}|Group-Object actionHash|Where-Object Count -gt 1|Select-Object -First 10|ForEach-Object{@{actionHash=$_.Name;count=$_.Count;identity='legacy_request_hash_not_effect_identity'}})
    note='Only requests that reached this plugin are counted. Native prompts outside the hook cannot be inferred from these logs alone.'
}
$taskReport|ConvertTo-Json -Depth 10
