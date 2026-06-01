// WPT: shorthand expansion + CSS-wide keywords (spec/subspecs/cssom.md).
// getComputedStyle resolves longhands from shorthands (text-decoration, font)
// and the inherit / initial / unset keywords.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('td')).getPropertyValue('text-decoration-line'), 'underline',
    'text-decoration shorthand exposes the text-decoration-line longhand');
}, 'shorthand: text-decoration -> text-decoration-line');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('fn')).fontStyle, 'italic',
    'font shorthand exposes font-style');
  assert_equals(getComputedStyle(document.getElementById('fn')).fontWeight, '700',
    'font shorthand exposes font-weight (bold -> 700)');
}, 'shorthand: font -> font-style / font-weight');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('inh')).color, 'rgb(255, 0, 0)',
    'color: inherit takes the parent computed color');
  assert_equals(getComputedStyle(document.getElementById('fwinh')).fontWeight, '700',
    'font-weight: inherit takes the parent computed weight');
}, 'css-wide: inherit');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('ini')).color, 'rgb(0, 0, 0)',
    'color: initial resolves to the initial color');
}, 'css-wide: initial');

test(() => {
  // color inherits, so `unset` behaves like `inherit` (parent red).
  assert_equals(getComputedStyle(document.getElementById('unsc')).color, 'rgb(255, 0, 0)',
    'color: unset behaves as inherit for an inherited property');
  // text-decoration does not inherit, so `unset` behaves like `initial` (none).
  assert_equals(getComputedStyle(document.getElementById('unsd')).getPropertyValue('text-decoration-line'), 'none',
    'text-decoration: unset behaves as initial for a non-inherited property');
}, 'css-wide: unset');
