// CSS Selectors §5: a comma-separated selector list matches the union
// of its parts. Verifies the C.8 parser fix (previously only the last
// token was honored, so 'a,b,c' returned only matches for 'c').

test(() => {
  const all = document.querySelectorAll('input,button,select,textarea');
  // 4 listed tags in the test fixture, all distinct
  assert_equals(all.length, 4);
  // Document order must be preserved across the union
  assert_equals(all[0].tagName, 'INPUT');
  assert_equals(all[1].tagName, 'BUTTON');
  assert_equals(all[2].tagName, 'SELECT');
  assert_equals(all[3].tagName, 'TEXTAREA');
}, 'querySelectorAll honors a comma-separated tag list (union)');

test(() => {
  // Selector list with mixed types: tag, .class, #id
  const all = document.querySelectorAll('h1, .alert, #cta');
  // <h1>, <p class="alert">, <a id="cta">
  assert_equals(all.length, 3);
}, 'querySelectorAll honors mixed tag/.class/#id list');

test(() => {
  // Each part may be a complex selector with combinators
  const all = document.querySelectorAll('section > p, .alert');
  // <p>inside section</p> and <p class="alert">
  assert_true(all.length >= 2);
}, 'selector list parts may be complex selectors with combinators');

test(() => {
  // querySelector returns the first matching element across all parts,
  // in document order.
  const first = document.querySelector('button, input');
  assert_equals(first.tagName, 'INPUT'); // input precedes button in fixture
}, 'querySelector returns first match across selector list');

test(() => {
  // matches() must accept comma lists and return true if any part matches.
  const btn = document.querySelector('button');
  assert_true(btn.matches('button'));
  assert_true(btn.matches('input, button, select'));
  assert_false(btn.matches('input, select, textarea'));
}, 'Element.matches honors selector lists');

test(() => {
  // Empty/whitespace parts are silently skipped (lenient parsing).
  const all = document.querySelectorAll('input ,, button');
  assert_equals(all.length, 2);
}, 'selector list tolerates empty parts');

test(() => {
  // Comma inside [attr="..."] is NOT a list separator — bracket-depth
  // tracking must keep `,` inside `[name="a,b"]` as part of the value.
  // Fixture has <p data-key="a,b"> we can match against.
  const all = document.querySelectorAll('p[data-key="a,b"]');
  assert_equals(all.length, 1);
}, 'comma inside attribute value is not a list separator');
