test(() => {
  localStorage.clear();
  let threw = false;
  let name = null;
  let preserved = null;

  localStorage.setItem('safe', 'ok');
  try {
    localStorage.setItem('huge', 'x'.repeat(5 * 1024 * 1024 + 1));
  } catch (e) {
    threw = true;
    name = e.name;
  }
  preserved = localStorage.getItem('safe');

  assert_true(threw, 'expected setItem to throw when over quota');
  assert_equals(name, 'QuotaExceededError');
  // Atomic semantics: the prior value must still be readable.
  assert_equals(preserved, 'ok');
}, 'localStorage throws QuotaExceededError and preserves prior state');
