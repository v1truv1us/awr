test(() => {
  const btn = document.getElementById('btn');
  let clicks = 0;
  btn.addEventListener('click', () => clicks += 1);
  btn.click();
  assert_equals(clicks, 1);
  btn.click();
  assert_equals(clicks, 2);
}, 'Element.click() fires a click listener');

test(() => {
  const btn = document.getElementById('btn');
  let bubbledTo = null;
  document.body.addEventListener('click', () => bubbledTo = 'body');
  btn.click();
  assert_equals(bubbledTo, 'body');
}, 'Element.click() bubbles to ancestor listeners');
