test(() => {
  const el = document.getElementById('node');
  el.setAttribute('data-fresh', 'one');
  assert_equals(el.getAttribute('data-fresh'), 'one');
  assert_true(el.hasAttribute('data-fresh'));
  el.setAttribute('data-fresh', 'two');
  assert_equals(el.getAttribute('data-fresh'), 'two');
  el.removeAttribute('data-fresh');
  assert_false(el.hasAttribute('data-fresh'));
  assert_equals(el.getAttribute('data-fresh'), null);
}, 'setAttribute / removeAttribute round-trip on a fresh attribute');

test(() => {
  const el = document.getElementById('node');
  assert_equals(el.getAttribute('missing'), null);
}, 'getAttribute returns null for absent attributes');
