test(() => {
  const host = document.getElementById('host');
  assert_not_equals(host, null);
  assert_equals(host.children.length, 2);
  assert_equals(host.childNodes.length, 2);
  assert_equals(host.firstChild.id, 'first');
  assert_equals(host.lastChild.id, 'last');
}, 'parsed-node child getters reflect the authoritative DOM tree');

test(() => {
  const host = document.getElementById('host');
  assert_equals(host.innerHTML, '<span id="first">hello</span><em id="last" data-kind="accent">world</em>');
  assert_equals(host.outerHTML, '<div id="host"><span id="first">hello</span><em id="last" data-kind="accent">world</em></div>');
}, 'parsed-node HTML getters serialize the authoritative DOM tree');
