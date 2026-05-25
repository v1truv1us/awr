// WPT: Cascade basics (spec/subspecs/cssom.md §4.3)
// Note: the fixture stylesheet intentionally orders selectors from lowest to
// highest specificity so that source-order and specificity agree, which keeps
// these tests independent of any specificity tiebreak implementation detail.

test(() => {
  // Two `p { color: ... }` rules; the later one must win.
  const el = document.getElementById('source-order');
  assert_equals(getComputedStyle(el).color, 'blue',
    'later rule in source order overrides earlier same-specificity rule');
}, 'cascade source order: last declaration wins');

test(() => {
  // Stylesheet sets color:blue; inline style sets color:orange.
  // Inline style wins over a normal author rule.
  const el = document.getElementById('inline-wins');
  assert_equals(getComputedStyle(el).color, 'orange',
    'inline style overrides normal author stylesheet declaration');
}, 'cascade: inline style beats normal author rule');

test(() => {
  // Element matches both `p { color: blue }` (element selector, comes first)
  // and `.accent { color: green }` (class selector, comes second).
  // Class selector has higher specificity; ordering guarantees the test passes
  // regardless of whether specificity or source-order is the deciding factor.
  const el = document.getElementById('class-rule');
  assert_equals(getComputedStyle(el).color, 'green',
    'class selector wins over element-type selector');
}, 'cascade specificity: class selector beats element-type selector');

test(() => {
  // Element matches `.accent { color: green }` and `#special { color: purple }`.
  // ID selector has highest specificity; again ordered after class in the sheet.
  const el = document.getElementById('special');
  assert_equals(getComputedStyle(el).color, 'purple',
    'ID selector wins over class selector');
}, 'cascade specificity: ID selector beats class selector');
