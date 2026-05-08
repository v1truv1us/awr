test(() => {
  assert_equals(typeof window.matchMedia, 'function');
}, 'window.matchMedia is a function');

test(() => {
  const q = window.matchMedia('(prefers-color-scheme: dark)');
  assert_equals(typeof q, 'object');
  assert_true(q !== null);
  assert_equals(q.matches, false);
  assert_equals(q.media, '(prefers-color-scheme: dark)');
}, 'matchMedia returns a MediaQueryList with matches=false and the original query');

test(() => {
  // Edge case: empty / coerced query strings.
  assert_equals(window.matchMedia('').media, '');
  assert_equals(window.matchMedia(undefined).media, '');
  assert_equals(window.matchMedia(null).media, '');
}, 'matchMedia coerces null/undefined to empty string for media field');

test(() => {
  const q = window.matchMedia('(min-width: 600px)');
  // Both legacy (addListener / removeListener) and modern
  // (addEventListener / removeEventListener) APIs must be callable
  // without throwing — feature detection patterns assume one or both.
  q.addListener(function () {});
  q.removeListener(function () {});
  q.addEventListener('change', function () {});
  q.removeEventListener('change', function () {});
  assert_equals(q.dispatchEvent({}), false);
  assert_equals(q.onchange, null);
}, 'MediaQueryList listener APIs are no-ops (legacy + modern)');
