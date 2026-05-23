test(() => {
  const el = document.getElementById('inline-css');
  assert_equals(getComputedStyle(el).display, 'none');
  assert_equals(getComputedStyle(el).getPropertyValue('visibility'), 'hidden');
}, 'getComputedStyle reflects inline style declarations');

test(() => {
  const el = document.getElementById('mutable-css');
  el.style.display = 'none';
  el.style.setProperty('visibility', 'hidden');
  assert_equals(el.getAttribute('style'), 'display: none; visibility: hidden;');
  assert_equals(getComputedStyle(el).display, 'none');
  assert_equals(getComputedStyle(el).visibility, 'hidden');
}, 'element.style supports basic property mutation');
