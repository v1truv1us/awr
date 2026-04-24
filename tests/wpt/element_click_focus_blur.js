test(() => {
  const node = document.getElementById('node');
  const calls = [];
  node.addEventListener('focus', () => calls.push('focus'));
  node.addEventListener('blur', () => calls.push('blur'));
  node.addEventListener('click', () => calls.push('click'));
  node.focus();
  node.click();
  node.blur();
  assert_array_equals(calls, ['focus', 'click', 'blur']);
}, 'focus, click, and blur dispatch corresponding events');
