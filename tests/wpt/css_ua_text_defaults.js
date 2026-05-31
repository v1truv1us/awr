// WPT: user-agent default computed styles for emphasis / decoration / align
// (spec/subspecs/cssom.md §2). getComputedStyle should reflect the same UA
// stylesheet defaults a real browser exposes to scripts — independent of
// AWR's terminal presentation choices — and author rules must still win.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('strong')).fontWeight, 'bold',
    '<strong> defaults to font-weight:bold');
  assert_equals(getComputedStyle(document.getElementById('h2')).fontWeight, 'bold',
    'headings default to font-weight:bold');
  assert_equals(getComputedStyle(document.getElementById('plain')).fontWeight, 'normal',
    'non-emphasis elements default to font-weight:normal');
}, 'UA default: font-weight');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('em')).fontStyle, 'italic',
    '<em> defaults to font-style:italic');
  assert_equals(getComputedStyle(document.getElementById('plain')).fontStyle, 'normal',
    'non-italic elements default to font-style:normal');
}, 'UA default: font-style');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('link')).textDecoration, 'underline',
    '<a> defaults to text-decoration:underline');
  assert_equals(getComputedStyle(document.getElementById('del')).getPropertyValue('text-decoration-line'), 'line-through',
    '<del> defaults to text-decoration-line:line-through');
  assert_equals(getComputedStyle(document.getElementById('plain')).textDecoration, 'none',
    'plain elements default to text-decoration:none');
}, 'UA default: text-decoration');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('plain')).textAlign, 'start',
    'default text-align is start');
  assert_equals(getComputedStyle(document.getElementById('th')).textAlign, 'center',
    '<th> defaults to text-align:center');
  assert_equals(getComputedStyle(document.getElementById('plain')).textTransform, 'none',
    'default text-transform is none');
}, 'UA default: text-align / text-transform');

test(() => {
  // Author CSS and inline styles override the UA default.
  assert_equals(getComputedStyle(document.getElementById('strong')).fontStyle, 'italic',
    'author stylesheet font-style overrides UA default on <strong>');
  assert_equals(getComputedStyle(document.getElementById('unbold')).fontWeight, 'normal',
    'inline font-weight:normal overrides the <strong> UA bold default');
}, 'author / inline styles override UA defaults');
