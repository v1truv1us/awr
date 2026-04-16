test(() => {
  const el = document.querySelector('section#hero');
  assert_not_equals(el, null);
  assert_equals(el.getAttribute('class'), 'banner');
}, 'document.querySelector supports tag#id selectors');

test(() => {
  const el = document.querySelector('.copy');
  assert_not_equals(el, null);
  assert_equals(el.textContent, 'Hello');
}, 'document.querySelector supports class selectors');
