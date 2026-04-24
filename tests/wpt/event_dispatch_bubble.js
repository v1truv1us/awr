test(() => {
  const parent = document.getElementById('parent');
  const child = document.getElementById('child');
  const calls = [];

  parent.addEventListener('click', () => calls.push('parent-capture'), true);
  child.addEventListener('click', () => calls.push('child'));
  parent.addEventListener('click', () => calls.push('parent-bubble'));

  child.dispatchEvent(new Event('click', { bubbles: true }));
  assert_array_equals(calls, ['parent-capture', 'child', 'parent-bubble']);
}, 'dispatchEvent uses capture and bubble phases');
