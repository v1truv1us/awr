test(() => {
  const host = document.getElementById('host');
  const first = host.firstChild;
  assert_not_equals(first, null);
  const before = host.children.length;
  host.removeChild(first);
  assert_equals(host.children.length, before - 1);
  assert_equals(host.querySelector('#a'), null);
}, 'removeChild detaches a child from the host');
