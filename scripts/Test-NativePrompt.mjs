import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as zlib from 'node:zlib';
import assert from 'node:assert/strict';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const output = process.argv[2] ? resolve(process.argv[2]) : null;
if (!output) throw new Error('Usage: node scripts/Test-NativePrompt.mjs NEW_OUTPUT_DIRECTORY');
const { commit } = JSON.parse(readFileSync(join(root, 'native/SOURCE.json'), 'utf8'));
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
        const outcome = ['allow', 'deny'][index - 1];
        assert.ok(outcome, 'unexpected extra inference');
        writeFileSync(join(output, 'model-request-' + index + '.json'), JSON.stringify(frame, null, 2));
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
        CARGO_TARGET_DIR: join(root, '.local', 'native-release-target'), CARGO_INCREMENTAL: '0',
        CARGO_PROFILE_RELEASE_OPT_LEVEL: '2', CARGO_PROFILE_RELEASE_LTO: 'false',
        CARGO_PROFILE_RELEASE_CODEGEN_UNITS: '16', CARGO_PROFILE_RELEASE_DEBUG: '0',
        CARGO_PROFILE_RELEASE_STRIP: 'none', CARGO_PROFILE_RELEASE_PANIC: 'unwind',
    };
    for (const name of ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_AUTH_TOKEN','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY']) delete env[name];
    const child = spawn('cargo', ['+stable','test','--offline','--locked','--release','--target','x86_64-pc-windows-msvc',
        '-p','ag-guardian-host','final_native_prompt_roundtrip','--','--ignored','--nocapture'], {cwd: workspace, env, stdio: 'inherit'});
    const [status] = await once(child, 'exit');
    assert.equal(status, 0, 'native round trip failed');
    assert.equal(requests.length, 2);
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
    writeFileSync(join(output, 'summary.json'), JSON.stringify({
        capturedModelRequests: 2, toolDefinitions: 0, actionBytes: Buffer.byteLength(content),
        fullActionMatched: true, authorizationOrderMatched: true, simulatedVerdicts: ['allow', 'deny'],
    }, null, 2));
    console.log('PASS both final Responses bodies preserved the exact action and ordered user evidence with zero tools');
} finally {
    server.close();
}
