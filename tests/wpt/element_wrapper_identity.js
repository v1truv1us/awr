test(() => {
  const a = document.getElementById('node');
  const b = document.getElementById('node');
  assert_equals(a, b);
}, 'two getElementById calls return the same wrapper for the same node');

test(() => {
  const host = document.getElementById('host');
  const direct = document.getElementById('child');
  const viaParent = host.firstChild;
  assert_equals(direct, viaParent);
}, 'wrapper identity holds across getElementById and tree traversal');

test(() => {
  const host = document.getElementById('host');
  const viaQuery = host.querySelector('#child');
  const viaTraversal = host.firstChild;
  assert_equals(viaQuery, viaTraversal);
}, 'wrapper identity holds across querySelector and traversal');
