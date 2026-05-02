test(() => {
  const host = document.getElementById('host');
  host.textContent = 'plain text';
  assert_equals(host.textContent, 'plain text');
  assert_equals(host.children.length, 0);
  assert_equals(host.querySelector('span'), null);
}, 'setting textContent replaces children with a single text run');

test(() => {
  const host = document.getElementById('host');
  host.textContent = '';
  assert_equals(host.textContent, '');
  assert_equals(host.innerHTML, '');
}, 'clearing textContent leaves the element empty');
