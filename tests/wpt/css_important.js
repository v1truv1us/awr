// WPT: !important precedence (spec/subspecs/cssom.md §4.4)

test(() => {
  // Stylesheet: #beats-inline { color: red !important }
  // Inline:     style="color: blue"
  // Author !important must beat a normal inline declaration.
  const el = document.getElementById('beats-inline');
  assert_equals(getComputedStyle(el).color, 'red',
    'author !important overrides a normal inline style');
}, 'author !important beats normal inline style');

test(() => {
  // Stylesheet: #normal-vs-inline-imp { color: red }  (no !important)
  // Inline:     style="color: blue !important"
  // Inline !important must beat a normal author rule.
  const el = document.getElementById('normal-vs-inline-imp');
  assert_equals(getComputedStyle(el).color, 'blue',
    'inline !important overrides a normal author rule');
}, 'inline !important beats normal author rule');

test(() => {
  // Stylesheet: #both-imp { color: red !important }
  // Inline:     style="color: blue !important"
  // When both are !important, inline wins (highest origin + importance).
  const el = document.getElementById('both-imp');
  assert_equals(getComputedStyle(el).color, 'blue',
    'inline !important overrides author !important');
}, 'inline !important beats author !important');

test(() => {
  // No stylesheets involved: verify that setProperty with 'important' priority
  // is reflected correctly in cssText and getComputedStyle.
  const el = document.getElementById('beats-inline');
  el.style.setProperty('font-weight', 'bold', 'important');
  assert_true(el.style.cssText.includes('!important'),
    'setProperty with important priority serialises to !important in cssText');
  assert_equals(getComputedStyle(el).fontWeight, 'bold',
    'setProperty important value is visible in getComputedStyle');
}, 'setProperty with important priority round-trips through getComputedStyle');
