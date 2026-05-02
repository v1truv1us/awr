test(() => {
  const wrapper = document.createElement('div');
  assert_equals(wrapper.tagName, 'DIV');
  assert_equals(wrapper.nodeType, 1);
  assert_equals(wrapper.children.length, 0);
}, 'createElement returns a fresh element with the requested tag');

test(() => {
  const host = document.getElementById('host');
  const a = document.createElement('span');
  a.textContent = 'one';
  const b = document.createElement('span');
  b.textContent = 'two';
  host.appendChild(a);
  host.appendChild(b);
  assert_equals(host.children.length, 2);
  assert_equals(host.children[0].textContent, 'one');
  assert_equals(host.children[1].textContent, 'two');
}, 'a chain of createElement + appendChild builds a real subtree');

test(() => {
  const host = document.getElementById('host2');
  const first = document.createElement('p');
  first.textContent = 'first';
  const second = document.createElement('p');
  second.textContent = 'second';
  const middle = document.createElement('p');
  middle.textContent = 'middle';
  host.appendChild(first);
  host.appendChild(second);
  host.insertBefore(middle, second);
  assert_equals(host.children.length, 3);
  assert_equals(host.children[0].textContent, 'first');
  assert_equals(host.children[1].textContent, 'middle');
  assert_equals(host.children[2].textContent, 'second');
}, 'insertBefore on an appended chain places the node at the right position');
