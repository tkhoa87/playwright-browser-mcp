#!/usr/bin/env node
// Minimal fake @playwright/mcp upstream — replies over stdio for integration tests.
// Supports tools/list, tools/call (browser_evaluate, browser_console_messages,
// browser_network_requests, browser_navigate), and passes notifications.

import { createInterface } from 'node:readline';

const write = m => process.stdout.write(JSON.stringify(m) + '\n');

const TOOLS = [
  { name: 'browser_navigate', inputSchema: { type: 'object', properties: { url: { type: 'string' } } } },
  { name: 'browser_evaluate', inputSchema: { type: 'object', properties: { function: { type: 'string' } } } },
  { name: 'browser_console_messages', inputSchema: { type: 'object', properties: {} } },
  { name: 'browser_network_requests', inputSchema: { type: 'object', properties: {} } },
  { name: 'browser_click', inputSchema: { type: 'object', properties: { ref: { type: 'string' } } } },
];

createInterface({ input: process.stdin }).on('line', line => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.method === 'initialize') {
    write({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: '2024-11-05', serverInfo: { name: 'fake', version: '0' }, capabilities: { tools: {} } } });
    return;
  }
  if (msg.method === 'notifications/initialized') return;
  if (msg.method === 'tools/list') {
    write({ jsonrpc: '2.0', id: msg.id, result: { tools: TOOLS } });
    return;
  }
  if (msg.method === 'tools/call') {
    const { name, arguments: a = {} } = msg.params ?? {};
    if (name === 'browser_evaluate') {
      // Echo back the function string so tests can inspect it.
      write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `EVAL:${a.function}` }] } });
      return;
    }
    if (name === 'browser_console_messages') {
      write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: '[INFO] hello\n[ERROR] boom\n[WARN] careful' }] } });
      return;
    }
    if (name === 'browser_network_requests') {
      write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: 'GET /api/users 200\nGET /static/app.js 200\nGET /api/orders 500' }] } });
      return;
    }
    if (name === 'browser_navigate') {
      write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `navigated:${a.url}` }] } });
      return;
    }
    if (name === 'browser_click') {
      write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `clicked:${a.ref}` }] } });
      return;
    }
    write({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: `unknown tool ${name}` } });
    return;
  }
});
