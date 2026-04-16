test(() => {
  const leaf = document.getElementById('leaf');
  assert_true(leaf.matches('p.copy'));
}, 'element.matches supports simple compound selectors');

test(() => {
  const leaf = document.getElementById('leaf');
  const section = leaf.closest('section.shell');
  assert_equals(section && section.tagName, 'SECTION');
}, 'element.closest walks ancestors');
