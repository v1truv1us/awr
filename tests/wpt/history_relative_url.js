test(() => {
  history.pushState({ ok: true }, '', 'next.html');
  assert_equals(location.pathname, '/next.html');
  assert_equals(history.state.ok, true);
}, 'history.pushState resolves relative URLs against the current location');

test(() => {
  let threw = false;
  try {
    history.pushState({ ok: false }, '', 'https://other.example/path');
  } catch (error) {
    threw = error instanceof TypeError;
  }
  assert_true(threw);
}, 'history.pushState rejects cross-origin absolute URLs');
