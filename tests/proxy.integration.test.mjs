import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const proxyPath = path.resolve(__dirname, '..', 'src', 'proxy.mjs');
const fakePath = path.resolve(__dirname, 'fixtures', 'fake-upstream.mjs');

let child, rl;
let nextId = 1;
const pending = new Map();

function rpc(method, params = {}, timeoutMs = 5000) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => { pending.delete(id); reject(new Error(`timeout ${method}`)); }, timeoutMs);
    pending.set(id, m => {
      clearTimeout(t);
      if (m.error) reject(new Error(JSON.stringify(m.error)));
      else resolve(m.result);
    });
  });
}

before(async () => {
  child = spawn('node', [proxyPath], {
    env: { ...process.env, PW_MCP_CLI: fakePath },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  rl = createInterface({ input: child.stdout });
  rl.on('line', line => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id != null && pending.has(msg.id)) {
      const cb = pending.get(msg.id);
      pending.delete(msg.id);
      cb(msg);
    }
  });
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 't', version: '0' } });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
});

after(() => { child?.kill(); });

test('tools/list returns upstream tools plus extras', async () => {
  const r = await rpc('tools/list');
  const names = r.tools.map(t => t.name);
  assert.ok(names.includes('browser_navigate'));
  assert.ok(names.includes('get_page_text'));
  assert.ok(names.includes('find'));
  // augmented schemas present
  const console = r.tools.find(t => t.name === 'browser_console_messages');
  assert.ok(console.inputSchema.properties.pattern);
  assert.ok(console.inputSchema.properties.onlyErrors);
  const net = r.tools.find(t => t.name === 'browser_network_requests');
  assert.ok(net.inputSchema.properties.urlPattern);
});

test('get_page_text dispatches to browser_evaluate with sliced fn', async () => {
  const r = await rpc('tools/call', { name: 'get_page_text', arguments: { maxChars: 42 } });
  assert.match(r.content[0].text, /^EVAL:.*\.slice\(0, 42\)/);
});

test('find dispatches to browser_evaluate with JSON-encoded query', async () => {
  const r = await rpc('tools/call', { name: 'find', arguments: { query: 'Login', role: 'button' } });
  assert.match(r.content[0].text, /^EVAL:/);
  assert.match(r.content[0].text, /const q = "Login", role = "button"/);
});

test('find with no query yields safe empty-string fn', async () => {
  const r = await rpc('tools/call', { name: 'find', arguments: {} });
  assert.match(r.content[0].text, /const q = ""/);
});

test('browser_console_messages with onlyErrors filters server-side', async () => {
  const r = await rpc('tools/call', { name: 'browser_console_messages', arguments: { onlyErrors: true } });
  assert.equal(r.content[0].text, '[ERROR] boom\n[WARN] careful');
});

test('browser_console_messages with pattern filters by regex', async () => {
  const r = await rpc('tools/call', { name: 'browser_console_messages', arguments: { pattern: '^\\[INFO\\]' } });
  assert.equal(r.content[0].text, '[INFO] hello');
});

test('browser_network_requests with urlPattern filters URLs', async () => {
  const r = await rpc('tools/call', { name: 'browser_network_requests', arguments: { urlPattern: '/api/' } });
  assert.equal(r.content[0].text, 'GET /api/users 200\nGET /api/orders 500');
});

test('unknown tools pass through to upstream', async () => {
  const r1 = await rpc('tools/call', { name: 'browser_navigate', arguments: { url: 'https://example.com' } });
  assert.equal(r1.content[0].text, 'navigated:https://example.com');
  const r2 = await rpc('tools/call', { name: 'browser_click', arguments: { ref: 'abc' } });
  assert.equal(r2.content[0].text, 'clicked:abc');
});

test('upstream tool error surfaces to client', async () => {
  await assert.rejects(rpc('tools/call', { name: 'nonexistent_tool', arguments: {} }), /unknown tool/);
});
