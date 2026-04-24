test(() => {
  const host = document.getElementById('host');
  assert_not_equals(host, null);

  host.innerHTML = '<span class="copy">hello</span><em id="marker">world</em>';

  assert_equals(host.querySelector('#old'), null);
  const span = host.querySelector('.copy');
  assert_not_equals(span, null);
  assert_equals(span.textContent, 'hello');
  assert_not_equals(host.querySelector('#marker'), null);
  assert_equals(host.children.length, 2);
  assert_equals(host.firstChild.tagName, 'SPAN');
  assert_equals(host.lastChild.tagName, 'EM');
  assert_equals(host.innerHTML, '<span class="copy">hello</span><em id="marker">world</em>');
}, 'innerHTML setter replaces children with real queryable nodes');
