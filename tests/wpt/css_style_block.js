// WPT: <style> block loading (spec/subspecs/cssom.md §4.2)
// HTML fixture has an inline <style> block with rules targeting element type,
// ID, class, and a comma-separated selector list.

test(() => {
  const el = document.getElementById('para');
  assert_equals(getComputedStyle(el).color, 'green',
    'element-type rule from <style> block applies via getComputedStyle');
}, '<style> block element-type rule applies');

test(() => {
  const el = document.getElementById('hero');
  assert_equals(getComputedStyle(el).display, 'none',
    'ID rule from <style> block applies via getComputedStyle');
}, '<style> block ID rule applies');

test(() => {
  const el = document.getElementById('banner');
  assert_equals(getComputedStyle(el).visibility, 'hidden',
    'class rule from <style> block applies via getComputedStyle');
}, '<style> block class rule applies');

test(() => {
  const span = document.getElementById('span1');
  const em   = document.getElementById('em1');
  assert_equals(getComputedStyle(span).getPropertyValue('font-weight'), 'bold',
    'comma-listed selector applies to first element type');
  assert_equals(getComputedStyle(em).getPropertyValue('font-weight'), 'bold',
    'comma-listed selector applies to second element type');
}, '<style> block comma-separated selector list matches all listed types');

test(() => {
  const other = document.getElementById('unaffected');
  assert_equals(getComputedStyle(other).color, '',
    'element not matched by any rule has no stylesheet color');
}, 'unmatched element receives no value from <style> rules');
