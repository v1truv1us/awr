// WPT: color serialization completeness (spec/subspecs/cssom.md). getComputedStyle
// serializes hsl()/hsla(), transparent, currentColor, and the extended CSS
// named-color set to rgb()/rgba().

test(() => {
  assert_equals(getComputedStyle(document.getElementById('hsl')).color, 'rgb(0, 255, 0)',
    'hsl() serializes to rgb()');
  assert_equals(getComputedStyle(document.getElementById('hsla')).color, 'rgba(255, 0, 0, 0.5)',
    'hsla() with alpha < 1 serializes to rgba()');
}, 'serialization: hsl / hsla');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('named')).color, 'rgb(102, 51, 153)',
    'extended named color rebeccapurple serializes to rgb()');
  assert_equals(getComputedStyle(document.getElementById('named2')).color, 'rgb(32, 178, 170)',
    'extended named color lightseagreen serializes to rgb()');
}, 'serialization: extended named colors');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('trans')).backgroundColor, 'rgba(0, 0, 0, 0)',
    'transparent serializes to rgba(0, 0, 0, 0)');
}, 'serialization: transparent');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('cc')).backgroundColor, 'rgb(0, 0, 255)',
    'currentColor on background-color resolves to the element color');
}, 'serialization: currentColor');
