test(() => {
  assert_equals(typeof window.matchMedia, 'function');
}, 'window.matchMedia is a function');

test(() => {
  // T3.C: AWR's terminal default is dark — `prefers-color-scheme: dark`
  // evaluates to true. `light` evaluates to false. The original media
  // string is preserved verbatim.
  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  assert_equals(typeof dark, 'object');
  assert_true(dark !== null);
  assert_equals(dark.matches, true);
  assert_equals(dark.media, '(prefers-color-scheme: dark)');

  const light = window.matchMedia('(prefers-color-scheme: light)');
  assert_equals(light.matches, false);
}, 'matchMedia evaluates prefers-color-scheme (terminal default is dark)');

test(() => {
  // T3.C: width queries evaluate against (innerWidth * 8) CSS pixels.
  // The WPT runner uses an 80-col viewport → 640 CSS px wide.
  assert_equals(window.matchMedia('(min-width: 320px)').matches, true);
  assert_equals(window.matchMedia('(min-width: 640px)').matches, true);
  assert_equals(window.matchMedia('(min-width: 641px)').matches, false);
  assert_equals(window.matchMedia('(max-width: 640px)').matches, true);
  assert_equals(window.matchMedia('(max-width: 320px)').matches, false);
}, 'matchMedia evaluates (min|max)-width against viewport columns');

test(() => {
  // Edge case: empty / coerced query strings.
  assert_equals(window.matchMedia('').media, '');
  assert_equals(window.matchMedia(undefined).media, '');
  assert_equals(window.matchMedia(null).media, '');
  assert_equals(window.matchMedia('').matches, false);
  // Unknown queries default to false (no real CSS engine in AWR).
  assert_equals(window.matchMedia('(orientation: portrait)').matches, false);
}, 'matchMedia coerces null/undefined and defaults unknown queries to false');

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
