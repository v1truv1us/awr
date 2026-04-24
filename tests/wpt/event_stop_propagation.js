test(() => {
  const outer = document.getElementById('outer');
  const inner = document.getElementById('inner');
  const calls = [];

  outer.addEventListener('ping', () => calls.push('outer'));
  inner.addEventListener('ping', (event) => {
    calls.push('inner');
    event.stopPropagation();
  });

  inner.dispatchEvent(new Event('ping', { bubbles: true }));
  assert_array_equals(calls, ['inner']);
}, 'stopPropagation prevents bubbling to ancestors');

test(() => {
  const node = document.getElementById('inner');
  const calls = [];

  node.addEventListener('pong', (event) => {
    calls.push('first');
    event.stopImmediatePropagation();
  });
  node.addEventListener('pong', () => calls.push('second'));

  node.dispatchEvent(new Event('pong'));
  assert_array_equals(calls, ['first']);
}, 'stopImmediatePropagation prevents later listeners on the same target');
