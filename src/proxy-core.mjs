// Pure helpers extracted from proxy.mjs for unit testing.
// No I/O, no globals — everything here takes data in and returns data.

export const EXTRA_TOOLS = [
  {
    name: 'get_page_text',
    description:
      "Read the visible text of the current page (document.body.innerText, trimmed by `maxChars`). " +
      "PREFER THIS over `browser_snapshot` whenever you only need to read, summarize, search, " +
      "extract data, verify copy, or confirm what's on the page. It skips the accessibility " +
      "tree entirely and is typically 5–20× faster and orders of magnitude smaller in tokens " +
      "on heavy DOMs (large lists, dashboards, articles). " +
      "Returns plain text only — no refs, no roles, no selectors. " +
      "Use `browser_snapshot` only when you need element refs to act on (click/type/etc.) " +
      "and `find` won't locate them by text/role.",
    inputSchema: {
      type: 'object',
      properties: {
        maxChars: {
          type: 'number',
          description:
            'Maximum number of characters to return. Default 200000. Use a smaller cap ' +
            '(e.g. 2000–5000) when scanning for the gist of a page; raise it only when you ' +
            'specifically need long content like an article body or a long list.',
        },
      },
    },
  },
  {
    name: 'find',
    description:
      "Locate elements on the current page by visible text (case-insensitive substring), " +
      "with an optional ARIA `role` filter. Returns up to 10 leaf-prefer matches; each match " +
      "includes `tag`, `role`, `ariaLabel`, `text` (truncated to 80 chars), and a CSS " +
      "`selector`. Leaf-prefer means containers that wrap another match are dropped, so you " +
      "get the most specific node (button, link, cell) rather than its parent. " +
      "PREFER THIS over `browser_snapshot` whenever you already know the text or role of the " +
      "element you want — e.g. \"find the 'Sign in' button\", \"find the row containing " +
      "'INV-1234'\", \"find the link with text 'Pricing'\". Avoids the full accessibility-tree " +
      "dump and returns a directly usable selector. " +
      "Use `browser_snapshot` only when the element you need is not text-identifiable (icon-" +
      "only button, ambiguous role) or when you need the full structure of the page.",
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description:
            'Substring to match (case-insensitive) against the element\'s visible innerText. ' +
            'Keep it specific — broad queries like "a" or "button" will hit many nodes.',
        },
        role: {
          type: 'string',
          description:
            'Optional ARIA role to require (e.g. "button", "link", "textbox", "checkbox"). ' +
            'Combine with `query` to disambiguate when multiple elements share the same text.',
        },
      },
      required: ['query'],
    },
  },
];

export function augmentTools(tools) {
  const out = tools.map(t => {
    if (t.name === 'browser_snapshot') {
      return {
        ...t,
        description:
          (t.description ?? 'Capture accessibility snapshot of the current page.') +
          ' EXPENSIVE on large pages (multi-second walk of the entire accessibility tree, ' +
          'multi-MB response). Before calling this, ask: do I actually need element refs ' +
          'to act on? If you only need to read text, call `get_page_text`. If you know the ' +
          'text/role of the element you want, call `find`. Use `browser_snapshot` only when ' +
          'neither of those works — e.g. complex layouts, icon-only controls, or when you ' +
          'need the full page structure.',
      };
    }
    if (t.name === 'browser_console_messages') {
      const existing = t.inputSchema ?? { type: 'object', properties: {} };
      return {
        ...t,
        description:
          (t.description ?? 'Returns all console messages.') +
          ' Output can be very verbose on chatty pages — use `pattern` (regex) to filter ' +
          'lines (e.g. `pattern: "\\\\[MyApp\\\\]"`) or `onlyErrors: true` to keep just ' +
          'error/warning lines. Filtering happens server-side, so it cuts response tokens.',
        inputSchema: {
          ...existing,
          properties: {
            ...(existing.properties ?? {}),
            pattern: {
              type: 'string',
              description:
                'Regex. Only console lines matching this expression are returned. ' +
                'Filter is applied to the rendered text of each line (including level prefix). ' +
                'Use when scanning for specific log tags or error messages.',
            },
            onlyErrors: {
              type: 'boolean',
              description:
                'When true, drop any line that does not look like an error or warning. ' +
                'Use when triaging failures — much cheaper than reading all logs.',
            },
          },
        },
      };
    }
    if (t.name === 'browser_network_requests') {
      const existing = t.inputSchema ?? { type: 'object', properties: {} };
      return {
        ...t,
        description:
          (t.description ?? 'Returns a numbered list of network requests since loading the page.') +
          ' Output can be huge on resource-heavy pages — use `urlPattern` (regex) to narrow ' +
          'the list to the calls you care about (e.g. `urlPattern: "/api/"`). Filtering ' +
          'happens server-side; pair with `browser_network_request` (singular) to fetch ' +
          'full details for a specific entry by index.',
        inputSchema: {
          ...existing,
          properties: {
            ...(existing.properties ?? {}),
            urlPattern: {
              type: 'string',
              description:
                'Regex matched against each request line. Use to focus on a subset (API ' +
                'calls, a specific host, a path prefix). Example: "^GET /api/" keeps only ' +
                'GET requests under /api/.',
            },
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
