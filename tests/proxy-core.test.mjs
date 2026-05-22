import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  augmentTools,
  classifyToolCall,
  filterContent,
  buildPageTextFn,
  buildFindFn,
  EXTRA_TOOLS,
} from '../src/proxy-core.mjs';

test('augmentTools appends get_page_text and find', () => {
  const out = augmentTools([{ name: 'browser_navigate', inputSchema: { type: 'object', properties: {} } }]);
  const names = out.map(t => t.name);
  assert.deepEqual(names, ['browser_navigate', 'get_page_text', 'find']);
});

test('augmentTools adds pattern + onlyErrors to browser_console_messages', () => {
  const out = augmentTools([{ name: 'browser_console_messages', inputSchema: { type: 'object', properties: { existing: { type: 'string' } } } }]);
  const t = out.find(x => x.name === 'browser_console_messages');
  assert.ok(t.inputSchema.properties.pattern);
  assert.ok(t.inputSchema.properties.onlyErrors);
  assert.equal(t.inputSchema.properties.existing.type, 'string', 'existing prop preserved');
});

test('augmentTools adds urlPattern to browser_network_requests', () => {
  const out = augmentTools([{ name: 'browser_network_requests' }]);
  const t = out.find(x => x.name === 'browser_network_requests');
  assert.ok(t.inputSchema.properties.urlPattern);
});

test('augmentTools is non-destructive (input not mutated)', () => {
  const input = [{ name: 'browser_console_messages', inputSchema: { type: 'object', properties: {} } }];
  const snapshot = JSON.stringify(input);
  augmentTools(input);
  assert.equal(JSON.stringify(input), snapshot);
});

test('EXTRA_TOOLS shape', () => {
  for (const t of EXTRA_TOOLS) {
    assert.ok(t.name);
    assert.ok(t.description);
    assert.equal(t.inputSchema.type, 'object');
  }
});

test('filterContent with no filters returns content untouched', () => {
  const content = [{ type: 'text', text: 'a\nb\nc' }];
  assert.equal(filterContent(content, {}), content);
});

test('filterContent pattern keeps only matching lines', () => {
  const content = [{ type: 'text', text: 'apple\nbanana\nape' }];
  const out = filterContent(content, { pattern: '^ap' });
  assert.equal(out[0].text, 'apple\nape');
});

test('filterContent onlyErrors keeps error/warn lines', () => {
  const content = [{ type: 'text', text: '[INFO] ok\n[ERROR] bad\n[WARN] meh' }];
  const out = filterContent(content, { onlyErrors: true });
  assert.equal(out[0].text, '[ERROR] bad\n[WARN] meh');
});

test('filterContent urlPattern filters URL lines', () => {
  const content = [{ type: 'text', text: 'GET /api/x\nGET /static/y.png\nGET /api/z' }];
  const out = filterContent(content, { urlPattern: '/api/' });
  assert.equal(out[0].text, 'GET /api/x\nGET /api/z');
});

test('filterContent ignores non-text content blocks', () => {
  const content = [{ type: 'image', data: 'abc' }, { type: 'text', text: 'foo\nerror' }];
  const out = filterContent(content, { onlyErrors: true });
  assert.deepEqual(out[0], { type: 'image', data: 'abc' });
  assert.equal(out[1].text, 'error');
});

test('buildPageTextFn injects maxChars literal', () => {
  assert.match(buildPageTextFn(123), /\.slice\(0, 123\)$/);
});

test('buildPageTextFn default 200000 on missing/invalid', () => {
  assert.match(buildPageTextFn(undefined), /\.slice\(0, 200000\)$/);
  assert.match(buildPageTextFn(NaN), /\.slice\(0, 200000\)$/);
});

test('buildPageTextFn clamps negative to 0', () => {
  assert.match(buildPageTextFn(-5), /\.slice\(0, 0\)$/);
});

test('buildFindFn JSON-encodes query (XSS-safe)', () => {
  const fn = buildFindFn('"); alert(1); //', null);
  // The dangerous chars must be inside a JSON string literal, not bare code.
  assert.match(fn, /const q = "\\"\); alert\(1\); \/\/"/);
});

test('buildFindFn role null when absent', () => {
  const fn = buildFindFn('hi');
  assert.match(fn, /const q = "hi", role = null/);
});

test('buildFindFn role encoded when present', () => {
  const fn = buildFindFn('hi', 'button');
  assert.match(fn, /role = "button"/);
});

test('classifyToolCall routes get_page_text to browser_evaluate', () => {
  const r = classifyToolCall({ name: 'get_page_text', arguments: { maxChars: 50 } });
  assert.equal(r.kind, 'local');
  assert.equal(r.upstreamCall.name, 'browser_evaluate');
  assert.match(r.upstreamCall.arguments.function, /\.slice\(0, 50\)/);
});

test('classifyToolCall routes find to browser_evaluate', () => {
  const r = classifyToolCall({ name: 'find', arguments: { query: 'Login', role: 'button' } });
  assert.equal(r.kind, 'local');
  assert.equal(r.upstreamCall.name, 'browser_evaluate');
  assert.match(r.upstreamCall.arguments.function, /const q = "Login", role = "button"/);
});

test('classifyToolCall strips filter args from browser_console_messages', () => {
  const r = classifyToolCall({ name: 'browser_console_messages', arguments: { pattern: 'x', onlyErrors: true, other: 1 } });
  assert.equal(r.kind, 'filtered');
  assert.deepEqual(r.upstreamCall.arguments, { other: 1 });
  assert.deepEqual(r.filterArgs, { pattern: 'x', onlyErrors: true, urlPattern: undefined });
});

test('classifyToolCall strips urlPattern from browser_network_requests', () => {
  const r = classifyToolCall({ name: 'browser_network_requests', arguments: { urlPattern: '/api/' } });
  assert.equal(r.kind, 'filtered');
  assert.deepEqual(r.upstreamCall.arguments, {});
  assert.equal(r.filterArgs.urlPattern, '/api/');
});

test('classifyToolCall passes unknown tools through', () => {
  const r = classifyToolCall({ name: 'browser_click', arguments: { ref: 'foo' } });
  assert.equal(r.kind, 'passthrough');
});
