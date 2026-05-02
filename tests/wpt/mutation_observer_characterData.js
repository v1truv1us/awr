promise_test(t => {
  const target = document.getElementById('target');
  const records = [];
  const obs = new MutationObserver(rs => records.push(...rs));
  obs.observe(target, { characterData: true, characterDataOldValue: true });

  target.textContent = 'updated';

  return Promise.resolve().then(() => Promise.resolve()).then(() => {
    assert_equals(records.length, 1);
    assert_equals(records[0].type, 'characterData');
    assert_equals(records[0].oldValue, 'initial');
  });
}, 'MutationObserver fires characterData records with oldValue when configured');
