// DOM-level coverage for <form method="post"> per spec/subspecs/agent-browser.md §4.
// Asserts the parser preserves method/action through to JS via the Element
// surface that AWR exposes (getAttribute). The end-to-end submit through
// the TUI pipeline is exercised by the Zig-side integration test in
// tests/browser_form_post_test.zig — together they prove the full pipe.
test(() => {
  const f1 = document.getElementById('f1');
  assert_true(f1 !== null, 'form#f1 should be in the DOM');
  assert_equals(f1.tagName, 'FORM', 'form#f1 tagName');
  // The method attribute survives parsing as the original (lowercase) value.
  assert_equals(f1.getAttribute('method'), 'post', 'method attribute parsed as "post"');
  assert_equals(f1.getAttribute('action'), '/submit', 'action attribute parsed as /submit');
}, '<form method="post"> parse preserves method and action attributes');

test(() => {
  const f2 = document.getElementById('f2');
  assert_true(f2 !== null, 'form#f2 should be in the DOM');
  // No method attribute → null per getAttribute (default GET semantics live
  // in the form-submit pipeline, not on the element attribute itself).
  assert_equals(f2.getAttribute('method'), null, 'form#f2 has no method attribute');
}, '<form> with no method attribute returns null from getAttribute');

test(() => {
  const f3 = document.getElementById('f3');
  assert_true(f3 !== null, 'form#f3 should be in the DOM');
  // The parser preserves the raw attribute casing; canonicalization to
  // POST/GET happens at submit time per WHATWG. Do a case-insensitive check
  // so this test stays robust to future parser-level lowercasing.
  const raw = String(f3.getAttribute('method') || '').toLowerCase();
  assert_equals(raw, 'post', 'mixed-case method attribute parsed as post');
  assert_equals(f3.getAttribute('action'), 'http://other.example/api', 'absolute action preserved');
}, '<form method="PoSt"> parse preserves attribute case-insensitively');

test(() => {
  const forms = document.forms;
  assert_true(typeof forms.length === 'number', 'document.forms exposes length');
  assert_equals(forms.length, 3, 'document.forms collects all three <form> elements');
}, 'document.forms includes <form method="post">');
