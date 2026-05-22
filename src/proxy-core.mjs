// Pure helpers extracted from proxy.mjs for unit testing.
// No I/O, no globals — everything here takes data in and returns data.

export const EXTRA_TOOLS = [
  {
    name: 'get_page_text',
    description: 'Return document.body.innerText, truncated. Skips the accessibility tree — cheap. Use when you only need page text, not refs.',
    inputSchema: {
      type: 'object',
      properties: {
        maxChars: { type: 'number', description: 'Max characters to return. Default 200000.' },
      },
    },
  },
  {
    name: 'find',
    description: 'Search the DOM for elements whose visible text contains <query>. Optional role filter. Returns up to 10 matches with tag, role, aria-label, text, and a CSS selector. Leaf-prefer: ancestors of other matches are dropped.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Substring to match (case-insensitive) against innerText.' },
        role: { type: 'string', description: 'Optional ARIA role to filter by.' },
      },
      required: ['query'],
    },
  },
];

export function augmentTools(tools) {
  const out = tools.map(t => {
    if (t.name === 'browser_console_messages') {
      return {
        ...t,
        inputSchema: {
          ...(t.inputSchema ?? { type: 'object', properties: {} }),
          properties: {
            ...((t.inputSchema && t.inputSchema.properties) ?? {}),
            pattern: { type: 'string', description: 'Optional regex; only lines matching are returned.' },
            onlyErrors: { type: 'boolean', description: 'Drop non-error lines.' },
          },
        },
      };
    }
    if (t.name === 'browser_network_requests') {
      return {
        ...t,
        inputSchema: {
          ...(t.inputSchema ?? { type: 'object', properties: {} }),
          properties: {
            ...((t.inputSchema && t.inputSchema.properties) ?? {}),
            urlPattern: { type: 'string', description: 'Optional regex matched against the request URL line.' },
          },
        },
      };
    }
    return t;
  });
  return out.concat(EXTRA_TOOLS);
}

export function filterContent(content, { pattern, onlyErrors, urlPattern }) {
  if (!pattern && !onlyErrors && !urlPattern) return content;
  const re = pattern ? new RegExp(pattern) : null;
  const ure = urlPattern ? new RegExp(urlPattern) : null;
  return (content ?? []).map(c => {
    if (c.type !== 'text' || typeof c.text !== 'string') return c;
    const kept = c.text.split('\n').filter(ln => {
      if (re && !re.test(ln)) return false;
      if (ure && !ure.test(ln)) return false;
      if (onlyErrors && !/error|warn/i.test(ln)) return false;
      return true;
    });
    return { ...c, text: kept.join('\n') };
  });
}

export function buildPageTextFn(maxChars) {
  const n = Number.isFinite(maxChars) ? Math.max(0, Math.floor(maxChars)) : 200_000;
  return `() => (document.body && document.body.innerText || '').slice(0, ${n})`;
}

export function buildFindFn(query, role) {
  const q = JSON.stringify(String(query ?? ''));
  const r = role ? JSON.stringify(String(role)) : 'null';
  return `() => {
      const q = ${q}, role = ${r};
      if (!q) return [];
      const ql = q.toLowerCase();
      const hits = [];
      for (const el of document.querySelectorAll('*')) {
        if (role && el.getAttribute('role') !== role) continue;
        const text = (el.innerText || el.textContent || '').trim();
        if (!text) continue;
        if (!text.toLowerCase().includes(ql)) continue;
        hits.push(el);
      }
      const leaves = hits.filter(el => !hits.some(other => other !== el && el.contains(other)));
      leaves.sort((a, b) => (a.innerText || a.textContent || '').length - (b.innerText || b.textContent || '').length);
      return leaves.slice(0, 10).map(el => {
        const text = (el.innerText || el.textContent || '').trim();
        let selector = el.tagName.toLowerCase();
        if (el.id) selector = '#' + el.id;
        else if (el.className && typeof el.className === 'string') selector += '.' + el.className.trim().split(/\\s+/).slice(0,2).join('.');
        return {
          tag: el.tagName.toLowerCase(),
          role: el.getAttribute('role'),
          ariaLabel: el.getAttribute('aria-label'),
          text: text.slice(0, 80),
          selector,
        };
      });
    }`;
}

// Decide how a tools/call should be routed. Returns:
//   { kind: 'local', upstreamCall: {name, arguments}, postProcess?: 'none' }
//   { kind: 'filtered', upstreamCall, filterArgs }
//   { kind: 'passthrough' }
export function classifyToolCall(params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  if (name === 'get_page_text') {
    return {
      kind: 'local',
      upstreamCall: { name: 'browser_evaluate', arguments: { function: buildPageTextFn(args.maxChars) } },
    };
  }
  if (name === 'find') {
    return {
      kind: 'local',
      upstreamCall: { name: 'browser_evaluate', arguments: { function: buildFindFn(args.query, args.role) } },
    };
  }
  if (name === 'browser_console_messages' || name === 'browser_network_requests') {
    const upstream = { ...args };
    const filterArgs = {
      pattern: upstream.pattern,
      onlyErrors: upstream.onlyErrors,
      urlPattern: upstream.urlPattern,
    };
    delete upstream.pattern;
    delete upstream.onlyErrors;
    delete upstream.urlPattern;
    return { kind: 'filtered', upstreamCall: { name, arguments: upstream }, filterArgs };
  }
  return { kind: 'passthrough' };
}
