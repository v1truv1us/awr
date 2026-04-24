test(() => {
  const target = document.getElementById('target');
  const observer = new MutationObserver(() => {});
  observer.observe(target, { attributes: true, attributeOldValue: true });
  target.setAttribute('data-state', 'ready');
  const records = observer.takeRecords();
  assert_equals(records.length, 1);
  assert_equals(records[0].attributeName, 'data-state');
  assert_equals(records[0].oldValue, null);
}, 'MutationObserver.takeRecords synchronously drains pending records');
