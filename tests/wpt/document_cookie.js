// document.cookie getter/setter wired to the page's cookie jar.
// Uses the EchoServer origin (http://127.0.0.1:18488) so cookies have a
// real domain to match against.

test(() => {
  // Initial state: jar is empty for this origin.
  assert_equals(typeof document.cookie, 'string');
  assert_equals(document.cookie, '');
}, 'document.cookie returns empty string for a fresh origin');

test(() => {
  document.cookie = 'session=abc; Path=/';
  // Get must reflect the just-set cookie.
  assert_true(document.cookie.indexOf('session=abc') >= 0);
}, 'document.cookie setter stores a cookie that the getter returns');

test(() => {
  document.cookie = 'one=1; Path=/';
  document.cookie = 'two=2; Path=/';
  const ck = document.cookie;
  assert_true(ck.indexOf('one=1') >= 0);
  assert_true(ck.indexOf('two=2') >= 0);
}, 'multiple document.cookie assignments stack into the jar');

test(() => {
  document.cookie = 'rep=first; Path=/';
  document.cookie = 'rep=second; Path=/';
  const ck = document.cookie;
  // Same name+domain+path → replacement, not duplicate
  const matches = ck.match(/rep=/g) || [];
  assert_equals(matches.length, 1);
  assert_true(ck.indexOf('rep=second') >= 0);
}, 'setting same-name cookie replaces, does not duplicate');

test(() => {
  // Malformed input is a silent no-op (matches browser semantics).
  // Set a baseline first so we can assert nothing changes.
  document.cookie = 'sentinel=ok; Path=/';
  const before = document.cookie;
  document.cookie = '';
  document.cookie = '=onlyvalue';
  const after = document.cookie;
  assert_equals(before, after);
}, 'malformed document.cookie input is a silent no-op');

promise_test(() => {
  document.cookie = 'roundtrip=carry; Path=/';
  // Subsequent fetch must carry the cookie back to the server.
  return fetch('http://127.0.0.1:18488/echo').then((r) => r.text()).then((t) => {
    // /echo (default route) returns "GET|" with no body. The Cookie header
    // is sent on the wire. We can't see it directly without a Cookie-echoing
    // route. Instead, verify the cookie is still gettable.
    assert_true(document.cookie.indexOf('roundtrip=carry') >= 0,
      'cookie must persist in the jar after a fetch');
  });
}, 'cookie persists in jar across a fetch round-trip');
