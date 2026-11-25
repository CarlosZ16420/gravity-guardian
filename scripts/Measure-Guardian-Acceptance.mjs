import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [mode, logDirectory, output] = process.argv.slice(2);
if (!['historical', 'candidate'].includes(mode) || !logDirectory || !output) {
    throw new Error('Usage: node Measure-Guardian-Acceptance.mjs historical|candidate LOG_DIRECTORY OUTPUT_JSON');
}

const requests = new Map();
const files = readdirSync(logDirectory).filter(name => mode === 'historical'
    ? /^2026-11-(?:1[89]|2[0-4])\.\d+\.jsonl$/.test(name)
    : /^\d{4}-\d{2}-\d{2}\.\d+\.jsonl$/.test(name)).sort();
for (const file of files) {
    const lines = readFileSync(join(logDirectory, file), 'utf8').split('\n');
    for (const [index, line] of lines.entries()) {
        if (!line.trim()) continue;
        const row = JSON.parse(line);
        if (!row.requestId) continue;
        const request = requests.get(row.requestId) ?? [];
        request.push({ ...row, file, line: index + 1 });
        requests.set(row.requestId, request);
    }
}

const rows = [];
const afterSnapshot = [];
// The supplied final plan was last written at 17:22:52 China Standard Time.
// The November 24 log continued growing on the same file after that snapshot.
const planSnapshot = Date.parse('2026-11-24T09:22:52Z');
for (const [requestId, records] of requests) {
    const get = event => records.findLast(row => row.event === event);
    const received = get('review_received');
    const completed = get('review_completed');
    const invalidated = get('review_invalidated');
    const hook = get('hook_decision');
    const usages = records.filter(row => row.event === 'review_usage');
    const native = usages.filter(row => row.backend === 'native_guardian');
    const cli = usages.filter(row => row.usage?.source?.startsWith('codex_exec.'));
    const context = get('review_context')?.reviewInput;
    const host = get('guardian_input')?.wire;

    if (mode === 'candidate') {
        if (!completed || native.length === 0) continue;
        const inferenceDispatchCount = native.reduce((total, row) => total + (row.inferenceDispatchCount ?? 0), 0);
        const hookDecision = hook?.hookDecision ?? null;
        rows.push({
            requestId, backend: 'native_guardian', inferenceDispatchCount, hookDecision, cliCalls: cli.length,
            reasonCode: hook?.reasonCode ?? completed.reasonCode, reviewInvalidated: Boolean(invalidated),
            nativeReviewed: inferenceDispatchCount > 0 && cli.length === 0 && !invalidated &&
                native.some(row => row.diagnostics?.completionSource === 'native_guardian_completed') &&
                ['auto_approve', 'deny'].includes(hookDecision) &&
                ['policy_allowed', 'policy_denied'].includes(hook?.reasonCode),
        });
        continue;
    }

    const promptFailure = native.find(row => row.reasonCode === 'native_tool_call_limit' ||
        row.rawErrorKind === 'PromptBuildError' || /exceeds limits for section native_tool_call/.test(completed?.reason ?? ''));
    const fallback = Boolean(promptFailure && cli.length);
    const manual = Boolean(promptFailure && completed?.reasonCode === 'reviewer_unavailable' &&
        completed.decision === 'force_ask' && /exceeds limits for section native_tool_call/.test(completed.reason));
    if (!fallback && !manual) continue;
    const visibleEvidence = {
        authenticatedUserRecordIds: completed?.authorizationSources ?? [],
        completeUserRecordsCaptured: Boolean(context?.user_instructions?.length ||
            host?.authorization?.user_instructions?.length || host?.history?.some(row => row.role === 'user')),
        nativeWireCaptured: Boolean(host),
        actionBodyCaptured: Boolean(received?.payload?.toolCall?.args || context?.planned_action?.toolCall?.args || host?.action?.arguments),
        permissionSnapshotCaptured: Boolean(context?.permission_context || host?.hostFacts?.permission_context),
        referencedFileStatesCaptured: Array.isArray(context?.referenced_file_states ?? host?.hostFacts?.referenced_file_states),
        hookDecisionCaptured: Boolean(hook),
    };
    const missing = [];
    if (!visibleEvidence.actionBodyCaptured) missing.push('action_body');
    if (!visibleEvidence.completeUserRecordsCaptured) missing.push('source_user_records');
    if (!visibleEvidence.nativeWireCaptured) missing.push('exact_native_wire');
    if (!visibleEvidence.permissionSnapshotCaptured) missing.push('permission_snapshot');
    if (!visibleEvidence.referencedFileStatesCaptured) missing.push('referenced_file_states');
    const cases = Date.parse(completed.at) <= planSnapshot ? rows : afterSnapshot;
    cases.push({
        requestId, at: completed.at, log: completed.file, line: completed.line,
        tool: completed.tool, actionFingerprint: completed.actionFingerprint ?? null,
        authorizationCutoff: { stepIdx: completed.stepIdx ?? received?.stepIdx ?? received?.payload?.stepIdx ?? null,
            sourcePosition: context?.native_binding?.cutoff_position ?? null, segment: completed.nativeSegment ?? null },
        visibleEvidence, failureLayer: 'native_prompt_budget', classification: fallback ? 'cli_fallback' : 'manual_handoff',
        nativeErrorCode: promptFailure.reasonCode ?? completed.reasonCode,
        nativeInferenceDispatchCount: promptFailure.inferenceDispatchCount ?? promptFailure.inferenceRequests ?? null,
        historicalDecision: hook?.hookDecision ?? completed.decision, historicalReasonCode: completed.reasonCode,
        reconstruction: missing.length ? 'partial' : 'inputs_captured',
        missing,
    });
}

const summary = mode === 'historical'
    ? {
        logFiles: files.length,
        samples: rows.length,
        cliFallbacks: rows.filter(row => row.classification === 'cli_fallback').length,
        manualHandoffs: rows.filter(row => row.classification === 'manual_handoff').length,
        historicalAllow: rows.filter(row => row.historicalReasonCode === 'policy_allowed').length,
        historicalDeny: rows.filter(row => row.historicalReasonCode === 'policy_denied').length,
        fullReplays: 0,
        partialReconstructions: rows.filter(row => row.reconstruction === 'partial').length,
        syntheticCasesRunByThisScript: 0,
        eligibleSamplesAfterPlanSnapshot: afterSnapshot.length,
    }
    : { logFiles: files.length, samples: rows.length, confirmedNativeReviews: rows.filter(row => row.nativeReviewed).length };
writeFileSync(output, JSON.stringify({ summary, rows, afterSnapshot }, null, 2) + '\n');
console.log(JSON.stringify(summary));
if (mode === 'historical' && (summary.logFiles !== 8 || summary.cliFallbacks !== 27 || summary.manualHandoffs !== 1)) {
    throw new Error('Historical corpus does not match the eight files and 28 cases specified in the plan');
}
