test(() => {
  const node = document.getElementById('node');
  let prevented = false;

  node.addEventListener('submit', (event) => {
    event.preventDefault();
    prevented = event.defaultPrevented;
  });

  const result = node.dispatchEvent(new Event('submit', { cancelable: true }));
  assert_true(prevented);
  assert_false(result);
}, 'preventDefault sets defaultPrevented and dispatchEvent returns false');
