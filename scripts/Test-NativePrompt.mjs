import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as zlib from 'node:zlib';
import assert from 'node:assert/strict';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
let requestedProfile = null;
const positional = [];
const rawArgs = process.argv.slice(2);
for (let i = 0; i < rawArgs.length; i++) {
    const arg = rawArgs[i];
    if (arg === '--dev') {
        requestedProfile = 'Debug';
    } else if (arg === '--release') {
        requestedProfile = 'Release';
    } else if (arg === '--profile') {
        const next = rawArgs[++i];
        if (!next) throw new Error('Missing value after --profile');
        requestedProfile = next.toLowerCase() === 'dev' || next.toLowerCase() === 'debug' ? 'Debug'
            : (next.toLowerCase() === 'release' ? 'Release' : (() => { throw new Error('Unsupported profile: ' + next); })());
    } else if (arg.startsWith('--profile=')) {
        const value = arg.slice('--profile='.length).toLowerCase();
        requestedProfile = value === 'dev' || value === 'debug' ? 'Debug'
            : (value === 'release' ? 'Release' : (() => { throw new Error('Unsupported profile: ' + value); })());
    } else if (arg.startsWith('-')) {
        throw new Error('Unknown option: ' + arg);
    } else {
        positional.push(arg);
    }
}
const output = positional[0] ? resolve(positional[0]) : null;
if (!output) throw new Error('Usage: node scripts/Test-NativePrompt.mjs NEW_OUTPUT_DIRECTORY [--dev|--release] [manifest.json] [repetitions]');
const { commit, releaseOptions } = JSON.parse(readFileSync(join(root, 'native/SOURCE.json'), 'utf8'));
const benchmarkManifest = positional[1] ? JSON.parse(readFileSync(positional[1], 'utf8')) : null;
const repetitions = Number(positional[2] ?? 1);
assert.ok(Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 50);
if (benchmarkManifest) assert.equal(benchmarkManifest.upstreamCommit, commit);
const isDev = requestedProfile ? requestedProfile === 'Debug' : benchmarkManifest?.profile === 'Debug';
const devOptions = { OPT_LEVEL: '0', LTO: 'off', CODEGEN_UNITS: '256', DEBUG: '0', STRIP: 'none', PANIC: 'unwind' };
const profile = isDev ? devOptions : (benchmarkManifest?.releaseOptions ?? releaseOptions);
const workspace = join(root, '.local', 'guardian-host-upstream-' + commit, 'codex-rs');
const hostSource = join(root, 'native/guardian-host');
const workspaceHost = join(workspace, 'ag-guardian-host');
if (!existsSync(join(workspace, 'Cargo.lock')) || !existsSync(join(workspaceHost, 'Cargo.toml'))) {
    throw new Error('Guardian Cargo workspace is not prepared. Run .\\scripts\\Build-Guardian.ps1 -SyncWorkspaceOnly first.');
}
for (const rel of ['Cargo.toml', 'src/main.rs', 'src/bootstrap.rs', 'src/offline_prompt_tests.rs']) {
    const srcPath = join(hostSource, rel);
    const dstPath = join(workspaceHost, rel);
    const srcBuf = readFileSync(srcPath);
    if (!existsSync(dstPath) || !readFileSync(dstPath).equals(srcBuf)) {
        mkdirSync(dirname(dstPath), { recursive: true });
        copyFileSync(srcPath, dstPath);
    }
}
const buildTemp = join(root, '.local', 'build-temp');
mkdirSync(buildTemp, { recursive: true });
const home = join(output, 'codex-home');
mkdirSync(output);
mkdirSync(home);
writeFileSync(join(home, 'config.toml'), 'cli_auth_credentials_store = "file"\n');
writeFileSync(join(home, 'auth.json'), JSON.stringify({ auth_mode: 'apikey', OPENAI_API_KEY: 'local-test-only' }));

const approval = 'SOURCE_APPROVAL_01: explicitly authorize preparing the scratch script.';
const revocation = 'SOURCE_REVOCATION_02: revoke permission to execute or send anything.';
const instructions = [approval, ...Array.from({length: 9}, (_, index) => 'Context update ' + (index + 1)),
    'Long user restriction 中文 with a quoted value "example". '.repeat(240), revocation]
    .map((text, index) => ({position: index * 5 + 1, text}));
const projectRules = [{path:'fixture/AGENTS.md',scope:'fixture',content:'Write only under the fixture root.'}];
const projectAuthorizations = {fixture:'Previously confirmed permission to prepare local drafts.'};
const content = '# Local synthetic fixture 中文 "quoted" C:\\fixture\n'.repeat(4000) + "Write-Output 'END_OF_ACTION'\n";
const fixture = {
    id:'offline-test', operation:'assess', scope:'a'.repeat(64),
    history: [{type:'message',role:'assistant',content:[{type:'input_text',text:'Observed fixture context.'}]}],
    authorization: {user_instructions:instructions, project_rules:projectRules, project_authorizations:projectAuthorizations},
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
        assert.ok(index <= 2 * repetitions + 2, 'unexpected extra inference');
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
    const defaultTargetDir = join(root, '.local', isDev ? 'native-build-target' : 'native-release-target');
    const env = {
        ...process.env, AG_GUARDIAN_HOST: '1', CODEX_HOME: home,
        TMP: buildTemp, TEMP: buildTemp,
        AG_TEST_PROMPT_FIXTURE: fixturePath, AG_TEST_RESPONSES_URL: 'http://127.0.0.1:' + server.address().port,
        AG_TEST_PROMPT_REPETITIONS: String(repetitions),
        CARGO_TARGET_DIR: process.env.CARGO_TARGET_DIR ?? defaultTargetDir,
        CARGO_INCREMENTAL: isDev ? '1' : '0',
    };
    const cargoProfilePrefix = isDev ? 'CARGO_PROFILE_DEV_' : 'CARGO_PROFILE_RELEASE_';
    for (const [key, value] of Object.entries(profile)) env[cargoProfilePrefix + key] = value;
    for (const name of ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_AUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY']) delete env[name];
    const cargoArgs = ['+stable', 'test', '--offline', '--locked'];
    if (!isDev) cargoArgs.push('--release');
    cargoArgs.push('--target', 'x86_64-pc-windows-msvc', '-p', 'ag-guardian-host', '--', '--include-ignored', '--nocapture');
    const child = spawn('cargo', cargoArgs, {cwd: workspace, env, stdio: ['ignore','pipe','inherit']});
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
    assert.equal(requests.length, 2 * repetitions + 2);
    assert.equal(latency.length, requests.length);
    const factsPrefix = 'Host-observed Antigravity facts for the current action, not user authorization: ';
    const authPrefix = 'Antigravity authorization evidence (current request):\n';
    for (const frame of requests) {
        assert.equal(frame.model, 'codex-auto-review');
        assert.equal(frame.tools?.length ?? 0, 0);
        const action = frame.input.find(item => item.type === 'function_call' && item.name === 'write_file');
        assert.ok(action, 'full native tool proposal missing');
        assert.deepEqual(JSON.parse(action.arguments), JSON.parse(fixture.action.arguments));
        const evidence = frame.input.filter(item => item.role === 'user')
            .flatMap(item => item.content)
            .filter(part => part.text?.startsWith(authPrefix));
        assert.equal(evidence.length, 1, 'expected exactly one copy of current authorization evidence');
        assert.deepEqual(JSON.parse(evidence[0].text.slice(authPrefix.length)), fixture.authorization);
        const facts = frame.input.filter(item => item.role === 'assistant')
            .flatMap(item => item.content)
            .filter(part => part.text?.startsWith(factsPrefix));
        assert.equal(facts.length, 1, 'expected exactly one copy of current host facts');
    }
    const trunkTurn1 = requests[requests.length - 2];
    const trunkTurn2 = requests[requests.length - 1];
    assert.equal(JSON.parse(trunkTurn1.input.find(i => i.role === 'assistant' && i.content?.some(p => p.text?.startsWith(factsPrefix))).content.find(p => p.text?.startsWith(factsPrefix)).text.slice(factsPrefix.length)).turn, 1);
    assert.equal(JSON.parse(trunkTurn2.input.find(i => i.role === 'assistant' && i.content?.some(p => p.text?.startsWith(factsPrefix))).content.find(p => p.text?.startsWith(factsPrefix)).text.slice(factsPrefix.length)).turn, 2);
    assert.ok(trunkTurn2.input.some(i => i.role === 'user' && i.content?.some(p => p.text?.includes('Delta turn 2 observed context.'))), 'TrunkReused missing delta history');
    const sorted = [...latency].sort((a,b) => a-b);
    const percentile = fraction => sorted[Math.ceil(fraction * sorted.length) - 1];
    writeFileSync(join(output, 'summary.json'), JSON.stringify({
        capturedModelRequests: requests.length, toolDefinitions: 0, actionBytes: Buffer.byteLength(content),
        fullActionMatched: true, authorizationOrderMatched: true, simulatedVerdicts: ['allow', 'deny'],
        authorizationSourceCount: instructions.length, projectScopesMatched: true, oversizedAuthorizationRejectedBeforeInference: true,
        trunkReusedVerified: true, oversizedActionAttributedCorrectly: true,
        profile: isDev ? 'Debug' : 'Release', buildOptions: profile,
        releaseOptions: profile, reviewP50Ms: percentile(0.50), reviewP95Ms: percentile(0.95),
    }, null, 2));
    console.log('PASS final Responses bodies preserved the exact action, ordered user evidence, and separate project scope with zero tools');
    console.log('PASS authorization exceeding the model budget stopped before inference');
} finally {
    server.close();
}
