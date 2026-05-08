// Window / navigator surface — feature-detection paths agents and
// fingerprinting libraries probe. Adds breadth on top of the existing
// navigator_basics.js + window_basics.js cases.

test(() => {
  // Viewport dimensions are numbers (default 80×24 — terminal-cell
  // grid; matches viewport_dimensions.js)
  assert_equals(typeof window.innerWidth, 'number');
  assert_equals(typeof window.innerHeight, 'number');
  assert_equals(typeof window.outerWidth, 'number');
  assert_equals(typeof window.outerHeight, 'number');
  assert_true(window.innerWidth > 0);
  assert_true(window.innerHeight > 0);
}, 'window.{inner,outer}{Width,Height} are positive numbers');

test(() => {
  // Scroll offsets always 0 — AWR has no scrolling. Feature detection
  // for sticky-headers / parallax often reads scrollY before deciding
  // to engage; returning 0 lets the script run without crashing.
  assert_equals(window.scrollX, 0);
  assert_equals(window.scrollY, 0);
  assert_equals(window.pageXOffset, 0);
  assert_equals(window.pageYOffset, 0);
}, 'window scroll offsets are 0');

test(() => {
  assert_equals(typeof window.scrollTo, 'function');
  assert_equals(typeof window.scrollBy, 'function');
  // No-ops — must not throw on any arg shape
  window.scrollTo(0, 100);
  window.scrollBy({ top: 50, behavior: 'smooth' });
}, 'window.scrollTo / scrollBy are no-op functions');

test(() => {
  assert_equals(typeof window.devicePixelRatio, 'number');
  assert_true(window.devicePixelRatio > 0);
}, 'window.devicePixelRatio is a positive number');

test(() => {
  // Cookie-jar is wired (Phase C.9 document.cookie) so cookieEnabled
  // must reflect that. Pre-fix it returned `false`.
  assert_equals(navigator.cookieEnabled, true);
}, 'navigator.cookieEnabled is true (cookie jar is wired)');

test(() => {
  assert_equals(typeof navigator.language, 'string');
  assert_true(navigator.language.length > 0);
  assert_true(Array.isArray(navigator.languages));
  assert_true(navigator.languages.length > 0);
  // language must be the first entry of languages (browser convention)
  assert_equals(navigator.languages[0], navigator.language);
}, 'navigator.language and navigator.languages are aligned');

test(() => {
  assert_equals(typeof navigator.userAgent, 'string');
  assert_true(navigator.userAgent.length > 0);
  // AWR ships a Chrome-fingerprint UA by default — agents that
  // sniff for "Chrome" should still match.
  assert_true(navigator.userAgent.indexOf('Chrome') >= 0);
}, 'navigator.userAgent contains "Chrome"');

test(() => {
  assert_equals(typeof navigator.platform, 'string');
  assert_equals(typeof navigator.vendor, 'string');
  assert_equals(typeof navigator.onLine, 'boolean');
  assert_true(navigator.onLine);
  assert_equals(typeof navigator.hardwareConcurrency, 'number');
  assert_true(navigator.hardwareConcurrency > 0);
  assert_equals(typeof navigator.maxTouchPoints, 'number');
}, 'navigator.{platform,vendor,onLine,hardwareConcurrency,maxTouchPoints} have stable types');
