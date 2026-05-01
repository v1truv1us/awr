test(() => {
  const host = document.getElementById('host');
  const span = document.createElement('span');
  span.textContent = 'inserted';
  host.appendChild(span);
  assert_equals(host.children.length, 1);
  assert_equals(host.firstChild.tagName, 'SPAN');
  assert_equals(host.firstChild.textContent, 'inserted');
}, 'createElement + appendChild attaches a real child to the host');

test(() => {
  const host = document.getElementById('host2');
  const a = document.createElement('p');
  a.textContent = 'a';
  const b = document.createElement('p');
  b.textContent = 'b';
  host.appendChild(a);
  host.appendChild(b);
  assert_equals(host.children.length, 2);
  assert_equals(host.firstChild.textContent, 'a');
  assert_equals(host.lastChild.textContent, 'b');
}, 'appendChild appends in insertion order');
