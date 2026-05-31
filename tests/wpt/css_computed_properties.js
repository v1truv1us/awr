// WPT: Starter computed-style property set (spec/subspecs/cssom.md §4.5 / §2)
// Covers all eight properties in the starter set:
//   display, visibility, white-space, text-transform,
//   font-weight, font-style, color, background-color

test(() => {
  assert_equals(getComputedStyle(document.getElementById('display-none')).display, 'none',
    'inline style display:none is reflected in getComputedStyle');
  // span is an inline element by UA default
  assert_equals(getComputedStyle(document.getElementById('display-inline')).display, 'inline',
    'inline UA default applies when no rule overrides display');
  // p is a block element by UA default
  assert_equals(getComputedStyle(document.getElementById('display-block')).display, 'block',
    'block UA default applies for block-level elements');
}, 'computed property: display');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('vis-hidden')).visibility, 'hidden',
    'inline style visibility:hidden is reflected');
  assert_equals(getComputedStyle(document.getElementById('display-none')).visibility, 'visible',
    'UA default visibility:visible applies when not overridden');
}, 'computed property: visibility');

test(() => {
  assert_equals(
    getComputedStyle(document.getElementById('ws')).getPropertyValue('white-space'),
    'pre',
    'stylesheet white-space:pre applies via getComputedStyle'
  );
}, 'computed property: white-space');

test(() => {
  assert_equals(
    getComputedStyle(document.getElementById('tt')).getPropertyValue('text-transform'),
    'uppercase',
    'stylesheet text-transform:uppercase applies via getComputedStyle'
  );
}, 'computed property: text-transform');

test(() => {
  assert_equals(
    getComputedStyle(document.getElementById('fw')).getPropertyValue('font-weight'),
    '700',
    'stylesheet font-weight:bold applies via getComputedStyle'
  );
}, 'computed property: font-weight');

test(() => {
  assert_equals(
    getComputedStyle(document.getElementById('fs')).getPropertyValue('font-style'),
    'italic',
    'stylesheet font-style:italic applies via getComputedStyle'
  );
}, 'computed property: font-style');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('col')).color, 'rgb(255, 0, 0)',
    'stylesheet color:red applies via getComputedStyle');
  // camelCase alias
  assert_equals(getComputedStyle(document.getElementById('col')).getPropertyValue('color'), 'rgb(255, 0, 0)',
    'getPropertyValue(\'color\') returns the same value');
}, 'computed property: color');

test(() => {
  assert_equals(
    getComputedStyle(document.getElementById('bg')).getPropertyValue('background-color'),
    'rgb(0, 0, 255)',
    'stylesheet background-color:blue applies via getComputedStyle'
  );
  assert_equals(
    getComputedStyle(document.getElementById('bg')).backgroundColor,
    'rgb(0, 0, 255)',
    'camelCase backgroundColor alias returns the same value'
  );
}, 'computed property: background-color');
