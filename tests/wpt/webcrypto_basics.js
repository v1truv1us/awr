// WebCrypto subset — crypto.getRandomValues + crypto.subtle.digest.
// T-93 / Tier 3 starter slice. Verifies the public surface AWR ships
// against BoringSSL: hash vectors (SHA-1/256/384/512), getRandomValues
// fills typed arrays in place, digest returns a Promise<ArrayBuffer>.

test(() => {
  assert_equals(typeof crypto, 'object', 'crypto global');
  assert_equals(typeof crypto.getRandomValues, 'function', 'getRandomValues fn');
  assert_equals(typeof crypto.subtle, 'object', 'subtle ns');
  assert_equals(typeof crypto.subtle.digest, 'function', 'subtle.digest fn');
}, 'WebCrypto public surface exists');

test(() => {
  const buf = new Uint8Array(32);
  const ret = crypto.getRandomValues(buf);
  // Spec: returns the same typed array.
  assert_equals(ret, buf, 'returns same typedArray');
  let nonzero = 0;
  for (const b of buf) if (b !== 0) nonzero++;
  assert_true(nonzero > 0, 'fills with non-trivial entropy');
}, 'getRandomValues fills typed array in place');

test(() => {
  // Two consecutive calls should yield different output (collision
  // probability 2^-256).
  const a = new Uint8Array(32);
  const b = new Uint8Array(32);
  crypto.getRandomValues(a);
  crypto.getRandomValues(b);
  let identical = true;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) { identical = false; break; }
  assert_false(identical, 'consecutive calls yield different bytes');
}, 'getRandomValues is non-deterministic');

// Helper: hex-encode a Uint8Array.
function hex(bytes) {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

promise_test(() => {
  // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  return crypto.subtle.digest('SHA-256', 'abc').then((buf) => {
    assert_true(buf instanceof ArrayBuffer, 'returns ArrayBuffer');
    const out = new Uint8Array(buf);
    assert_equals(out.length, 32, '32-byte SHA-256 output');
    assert_equals(hex(out), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
}, 'SHA-256("abc") matches the spec vector');

promise_test(() => {
  // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
  return crypto.subtle.digest('SHA-1', 'abc').then((buf) => {
    const out = new Uint8Array(buf);
    assert_equals(out.length, 20, '20-byte SHA-1 output');
    assert_equals(hex(out), 'a9993e364706816aba3e25717850c26c9cd0d89d');
  });
}, 'SHA-1("abc") matches the spec vector');

promise_test(() => {
  // SHA-256 of empty input.
  return crypto.subtle.digest('SHA-256', new Uint8Array(0)).then((buf) => {
    const out = new Uint8Array(buf);
    assert_equals(hex(out), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });
}, 'SHA-256 of empty input matches the spec vector');

promise_test(() => {
  // Algorithm as object: { name: 'SHA-256' }.
  return crypto.subtle.digest({ name: 'SHA-256' }, 'abc').then((buf) => {
    const out = new Uint8Array(buf);
    assert_equals(hex(out), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
}, 'digest accepts algorithm name as object');

promise_test(() => {
  // Reject unknown algorithm.
  return crypto.subtle.digest('SHA-3', 'abc').then(
    () => { throw new Error('SHA-3 should have rejected'); },
    (err) => {
      assert_true(err instanceof Error, 'rejects with Error');
      return undefined; // turn rejection into resolution for promise_test
    },
  );
}, 'digest rejects unsupported algorithm');
