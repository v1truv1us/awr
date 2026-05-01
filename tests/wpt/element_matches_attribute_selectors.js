test(() => {
  const node = document.getElementById('node');
  assert_true(node.matches('[id]'));
  assert_true(node.matches('[id="node"]'));
  assert_true(node.matches('[data-kind="primary"]'));
  assert_false(node.matches('[data-kind="other"]'));
}, 'matches supports presence and equality attribute selectors');

test(() => {
  const node = document.getElementById('node');
  assert_true(node.matches(':not(span)'));
  assert_false(node.matches(':not(div)'));
}, 'matches supports :not()');
