test(() => {
  const btn = document.getElementById('btn');
  let count = 0;
  function onClick() { count += 1; }

  btn.addEventListener('click', onClick);
  btn.dispatchEvent(new Event('click'));
  assert_equals(count, 1);

  btn.removeEventListener('click', onClick);
  btn.dispatchEvent(new Event('click'));
  assert_equals(count, 1);
}, 'addEventListener and removeEventListener work on elements');
