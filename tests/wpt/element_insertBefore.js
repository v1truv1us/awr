test(() => {
  const host = document.getElementById('host');
  const ref = host.querySelector('#second');
  const node = document.createElement('span');
  node.textContent = 'inserted';
  host.insertBefore(node, ref);
  const ids = host.children.map(c => c.id || '');
  assert_equals(ids[0], 'first');
  assert_equals(ids[1], '');
  assert_equals(host.children[1].textContent, 'inserted');
  assert_equals(ids[2], 'second');
}, 'insertBefore inserts the new node before the reference child');
