// HTMLFormElement getters: method / action / elements
// Verifies the smoke-test gap surfaced as B6 in the smoke report.

test(() => {
  const form = document.getElementById('f1');
  assert_true(form !== null);
  assert_equals(form.tagName, 'FORM');
  // method attribute is "POST" → form.method returns lowercase 'post'
  assert_equals(form.method, 'post');
}, 'form.method returns the normalized method attribute');

test(() => {
  const form = document.getElementById('f-default');
  assert_true(form !== null);
  // No method attribute → defaults to 'get'
  assert_equals(form.method, 'get');
}, 'form.method defaults to "get" when attribute missing');

test(() => {
  const form = document.getElementById('f-bogus');
  // method="PATCH" is invalid → falls back to 'get'
  assert_equals(form.method, 'get');
}, 'form.method normalizes unknown methods to "get"');

test(() => {
  const form = document.getElementById('f1');
  assert_equals(form.action, '/submit');
}, 'form.action returns the action attribute literal');

test(() => {
  const form = document.getElementById('f-default');
  // No action attribute → returns document URL
  assert_equals(form.action, document.URL);
}, 'form.action falls back to document.URL when attribute missing');

test(() => {
  const form = document.getElementById('f1');
  const els = form.elements;
  assert_true(els !== null && els !== undefined);
  // 4 listed elements: 2 input, 1 select, 1 textarea
  assert_equals(els.length, 4);
  // Iteration order matches document order
  assert_equals(els[0].tagName, 'INPUT');
  assert_equals(els[0].name, 'user');
  assert_equals(els[1].tagName, 'INPUT');
  assert_equals(els[1].name, 'csrf');
  assert_equals(els[2].tagName, 'SELECT');
  assert_equals(els[3].tagName, 'TEXTAREA');
}, 'form.elements returns descendant form controls in document order');

test(() => {
  const form = document.getElementById('f-with-image');
  // input[type=image] is explicitly excluded from form.elements per spec
  const els = form.elements;
  for (let i = 0; i < els.length; i++) {
    const el = els[i];
    assert_false(el.tagName === 'INPUT' && (el.getAttribute('type') || '').toLowerCase() === 'image');
  }
}, 'form.elements excludes input[type=image]');

test(() => {
  const form = document.getElementById('f1');
  // Setter writes to the attribute and round-trips through the getter.
  form.method = 'GET';
  assert_equals(form.method, 'get');
  assert_equals(form.getAttribute('method'), 'GET');
  form.action = '/elsewhere';
  assert_equals(form.action, '/elsewhere');
  assert_equals(form.getAttribute('action'), '/elsewhere');
}, 'form.method / form.action setters reflect to attributes');

test(() => {
  // Non-form elements must not expose the form-specific getters.
  const div = document.getElementById('not-a-form');
  assert_equals(div.method, undefined);
  assert_equals(div.action, undefined);
  assert_equals(div.elements, undefined);
}, 'method/action/elements are undefined on non-FORM elements');
