// External-script fixture for AWR's S2 (<script src>) acceptance test.
//
// A page that references this file via `<script src="./tools.js">`
// demonstrates that AWR loads subresources by URL, not just inline
// tags. The registered tool mirrors the one in webmcp_mock.html so
// callers can reuse the same invocation shape.

navigator.modelContext.registerTool(
  {
    name: 'external_ping',
    description: 'Proves external <script src> was fetched and executed.',
    inputSchema: {
      type: 'object',
      properties: { note: { type: 'string' } },
    },
  },
  function (args) {
    return { pong: true, note: (args && args.note) || null };
  }
);

window.__awrExternalLoaded__ = true;
