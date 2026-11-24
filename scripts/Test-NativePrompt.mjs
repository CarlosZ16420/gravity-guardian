import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as zlib from 'node:zlib';
import assert from 'node:assert/strict';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const output = process.argv[2] ? resolve(process.argv[2]) : null;
if (!output) throw new Error('Usage: node scripts/Test-NativePrompt.mjs NEW_OUTPUT_DIRECTORY');
const { commit, releaseOptions } = JSON.parse(readFileSync(join(root, 'native/SOURCE.json'), 'utf8'));
const benchmarkManifest = process.argv[3] ? JSON.parse(readFileSync(process.argv[3], 'utf8')) : null;
const repetitions = Number(process.argv[4] ?? 1);
assert.ok(Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 50);
if (benchmarkManifest) assert.equal(benchmarkManifest.upstreamCommit, commit);
const profile = benchmarkManifest?.releaseOptions ?? releaseOptions;
const workspace = join(root, '.local', 'guardian-host-upstream-' + commit, 'codex-rs');
const home = join(output, 'codex-home');
mkdirSync(output);
mkdirSync(home);
writeFileSync(join(home, 'config.toml'), 'cli_auth_credentials_store = "file"\n');
writeFileSync(join(home, 'auth.json'), JSON.stringify({ auth_mode: 'apikey', OPENAI_API_KEY: 'local-test-only' }));

const approval = 'SOURCE_APPROVAL_01: explicitly authorize preparing the scratch script.';
const revocation = 'SOURCE_REVOCATION_02: revoke permission to execute or send anything.';
const content = '# Local synthetic fixture 中文 "quoted" C:\\fixture\n'.repeat(4000) + "Write-Output 'END_OF_ACTION'\n";
const fixture = {
    history: [approval, revocation].map(text => ({type: 'message', role: 'user', content: [{type: 'input_text', text}]})),
    action: {type: 'function_call', name: 'write_file', call_id: 'proposed-offline-fixture',
        arguments: JSON.stringify({Path: join(output, 'never-executed.ps1'), Content: content})},
};
const fixturePath = join(output, 'fixture.json');
writeFileSync(fixturePath, JSON.stringify(fixture));
const requests = [];
const latency = [];
const server = createServer(async (req, res) => {
    try {
        if (req.method === 'GET' && new URL(req.url, 'http://localhost').pathname.endsWith('/models')) {
            res.writeHead(200, {'content-type': 'application/json'});
            res.end(JSON.stringify({models: [], data: []}));
            return;
        }
        assert.equal(req.method, 'POST');
        assert.match(req.url, /\/responses(?:\?|$)/);
        assert.equal(req.headers.authorization, 'Bearer local-test-only');
        const bytes = [];
        for await (const chunk of req) bytes.push(chunk);
        let body = Buffer.concat(bytes);
        if (req.headers['content-encoding'] === 'gzip') body = zlib.gunzipSync(body);
        if (req.headers['content-encoding'] === 'zstd') body = zlib.zstdDecompressSync(body);
        const frame = JSON.parse(body);
        requests.push(frame);
        const index = requests.length;
        const outcome = ['allow', 'deny'][(index - 1) % 2];
        assert.ok(index <= 2 * repetitions, 'unexpected extra inference');
        if (index <= 2) writeFileSync(join(output, 'model-request-' + index + '.json'), JSON.stringify(frame, null, 2));
        const id = 'fixture-' + index;
        const events = [
            {type: 'response.created', response: {id}},
            {type: 'response.output_item.done', item: {type: 'message', role: 'assistant', id: 'msg-' + index,
                content: [{type: 'output_text', text: JSON.stringify({outcome})}]}},
            {type: 'response.completed', response: {id, usage: {input_tokens: 40000, input_tokens_details: null,
                output_tokens: 8, output_tokens_details: null, total_tokens: 40008}}},
        ];
        res.writeHead(200, {'content-type': 'text/event-stream'});
        res.end(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''));
    } catch (error) {
        console.error(error.message);
        res.writeHead(400);
        res.end();
    }
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
try {
    const env = {
        ...process.env, AG_GUARDIAN_HOST: '1', CODEX_HOME: home,
        AG_TEST_PROMPT_FIXTURE: fixturePath, AG_TEST_RESPONSES_URL: 'http://127.0.0.1:' + server.address().port,
        AG_TEST_PROMPT_REPETITIONS: String(repetitions),
        CARGO_TARGET_DIR: process.env.CARGO_TARGET_DIR ?? join(root, '.local', 'native-release-target'),
        CARGO_INCREMENTAL: '0',
    };
    for (const [key, value] of Object.entries(profile)) env['CARGO_PROFILE_RELEASE_' + key] = value;
    for (const name of ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_AUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY']) delete env[name];
    const child = spawn('cargo', ['+stable','test','--offline','--locked','--release','--target','x86_64-pc-windows-msvc',
        '-p','ag-guardian-host','--','--include-ignored','--nocapture'], {cwd: workspace, env, stdio: ['ignore','pipe','inherit']});
    const lines = createInterface({ input: child.stdout });
    const drain = (async () => {
        for await (const line of lines) {
            console.log(line);
            const sample = /^native_review_ms=(\d+(?:\.\d+)?)$/.exec(line);
            if (sample) latency.push(Number(sample[1]));
        }
    })();
    const [status] = await once(child, 'exit');
    await drain;
    assert.equal(status, 0, 'native round trip failed');
    assert.equal(requests.length, 2 * repetitions);
    assert.equal(latency.length, requests.length);
    for (const frame of requests) {
        assert.equal(frame.model, 'codex-auto-review');
        assert.equal(frame.tools?.length ?? 0, 0);
        const action = frame.input.find(item => item.type === 'function_call' && item.name === 'write_file');
        assert.ok(action, 'full native tool proposal missing');
        assert.deepEqual(JSON.parse(action.arguments), JSON.parse(fixture.action.arguments));
        const lines = frame.input.filter(item => item.role === 'user')
            .flatMap(item => item.content.flatMap(part => part.text?.split('\n') ?? []));
        const approvalLine = lines.indexOf('user: ' + approval);
        const revocationLine = lines.indexOf('user: ' + revocation);
        assert.ok(approvalLine >= 0 && revocationLine > approvalLine,
            'authorization and revocation must arrive exactly and in source order');
    }
    const sorted = [...latency].sort((a,b) => a-b);
    const percentile = fraction => sorted[Math.ceil(fraction * sorted.length) - 1];
    writeFileSync(join(output, 'summary.json'), JSON.stringify({
        capturedModelRequests: requests.length, toolDefinitions: 0, actionBytes: Buffer.byteLength(content),
        fullActionMatched: true, authorizationOrderMatched: true, simulatedVerdicts: ['allow', 'deny'],
        releaseOptions: profile, reviewP50Ms: percentile(0.50), reviewP95Ms: percentile(0.95),
    }, null, 2));
    console.log('PASS both final Responses bodies preserved the exact action and ordered user evidence with zero tools');
} finally {
    server.close();
}
