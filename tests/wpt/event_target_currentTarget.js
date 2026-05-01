test(() => {
  const node = document.getElementById('node');
  let seenTarget = null;
  let seenCurrent = null;
  node.addEventListener('probe', (event) => {
    seenTarget = event.target;
    seenCurrent = event.currentTarget;
  });
  node.dispatchEvent(new Event('probe'));
  assert_equals(seenTarget, node);
  assert_equals(seenCurrent, node);
}, 'event.target and event.currentTarget point at the dispatch target during a leaf dispatch');

test(() => {
  const parent = document.getElementById('parent');
  const child = document.getElementById('child');
  let parentTarget = null;
  let parentCurrent = null;
  parent.addEventListener('hop', (event) => {
    parentTarget = event.target;
    parentCurrent = event.currentTarget;
  });
  child.dispatchEvent(new Event('hop', { bubbles: true }));
  assert_equals(parentTarget, child);
  assert_equals(parentCurrent, parent);
}, 'event.target stays as the original target while currentTarget tracks the bubble walk');
