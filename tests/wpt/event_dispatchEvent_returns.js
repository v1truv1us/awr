test(() => {
  const node = document.getElementById('node');
  node.addEventListener('foo', () => {});
  const result = node.dispatchEvent(new Event('foo', { cancelable: true }));
  assert_equals(result, true);
}, 'dispatchEvent returns true when no listener calls preventDefault');

test(() => {
  const node = document.getElementById('node');
  node.addEventListener('bar', (event) => event.preventDefault());
  const result = node.dispatchEvent(new Event('bar', { cancelable: true }));
  assert_equals(result, false);
}, 'dispatchEvent returns false when a listener calls preventDefault on a cancelable event');
