test(() => {
  const source = document.getElementById('source');
  const clone = source.cloneNode(true);

  assert_not_equals(clone, source);
  assert_equals(clone.parentNode, null);
  assert_equals(clone.getAttribute('class'), 'shell');
  assert_not_equals(clone.querySelector('.copy'), null);
  assert_equals(clone.querySelector('.copy').textContent, 'hello');

  clone.setAttribute('class', 'duplicate');
  assert_equals(source.getAttribute('class'), 'shell');
}, 'cloneNode(true) creates a detached deep copy');

test(() => {
  const source = document.getElementById('source');
  const shallow = source.cloneNode(false);
  assert_equals(shallow.querySelector('.copy'), null);
}, 'cloneNode(false) omits descendants');
