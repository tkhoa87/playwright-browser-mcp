#!/usr/bin/env node
// MCP stdio proxy that fronts @playwright/mcp.
//
// Adds:
//   - get_page_text       text-only page extract (no AX tree)
//   - find                locate elements by text / role (leaf-prefer)
//   - browser_console_messages  extra args: pattern (regex), onlyErrors
//   - browser_network_requests  extra args: urlPattern (regex)
//
// All other tools, notifications, and lifecycle messages pass through.

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { augmentTools, classifyToolCall, filterContent } from './proxy-core.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const upstreamCli = process.env.PW_MCP_CLI
  ?? path.resolve(__dirname, '..', 'node_modules', '@playwright', 'mcp', 'cli.js');

const child = spawn('node', [upstreamCli, ...process.argv.slice(2)], {
  stdio: ['pipe', 'pipe', 'inherit'],
});

child.on('exit', code => process.exit(code ?? 0));
process.on('SIGTERM', () => child.kill('SIGTERM'));
process.on('SIGINT', () => child.kill('SIGINT'));

const writeToClient = msg => process.stdout.write(JSON.stringify(msg) + '\n');
const writeToChild = msg => child.stdin.write(JSON.stringify(msg) + '\n');

// Requests we initiate to the child (id space disjoint from client's).
let nextProxyId = 1_000_000;
const pendingOurs = new Map();

function callChild(method, params) {
  const id = nextProxyId++;
  return new Promise((resolve, reject) => {
    pendingOurs.set(id, { resolve, reject });
    writeToChild({ jsonrpc: '2.0', id, method, params });
  });
}

createInterface({ input: child.stdout }).on('line', line => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { process.stdout.write(line + '\n'); return; }
  if (msg.id != null && pendingOurs.has(msg.id)) {
    const p = pendingOurs.get(msg.id);
    pendingOurs.delete(msg.id);
    if (msg.error) p.reject(msg.error);
    else p.resolve(msg.result);
    return;
  }
  writeToClient(msg);
});

async function handleToolsCall(params) {
  const route = classifyToolCall(params);
  if (route.kind === 'local') {
    return callChild('tools/call', route.upstreamCall);
  }
  if (route.kind === 'filtered') {
    const result = await callChild('tools/call', route.upstreamCall);
    return { ...result, content: filterContent(result.content, route.filterArgs) };
  }
  return callChild('tools/call', params);
}

createInterface({ input: process.stdin }).on('line', async line => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { child.stdin.write(line + '\n'); return; }

  if (msg.method === 'tools/list' && msg.id != null) {
    try {
      const upstream = await callChild('tools/list', msg.params ?? {});
      writeToClient({ jsonrpc: '2.0', id: msg.id, result: { ...upstream, tools: augmentTools(upstream.tools ?? []) } });
    } catch (err) {
      writeToClient({ jsonrpc: '2.0', id: msg.id, error: err });
    }
    return;
  }

  if (msg.method === 'tools/call' && msg.id != null) {
    try {
      const result = await handleToolsCall(msg.params);
      writeToClient({ jsonrpc: '2.0', id: msg.id, result });
    } catch (err) {
      writeToClient({ jsonrpc: '2.0', id: msg.id, error: err });
    }
    return;
  }

  // initialize, notifications, ping, … pass through verbatim.
  child.stdin.write(line + '\n');
}).on('close', () => child.kill());
