// WPT: computed-value serialization (spec/subspecs/cssom.md §2.2). getComputedStyle
// returns resolved/serialized values like a browser — font-weight keywords as
// numbers, colors as rgb()/rgba() — independent of the authored token form.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('fwb')).fontWeight, '700',
    'font-weight:bold serializes to 700');
  assert_equals(getComputedStyle(document.getElementById('fwn')).fontWeight, '400',
    'font-weight:normal serializes to 400');
  assert_equals(getComputedStyle(document.getElementById('fw7')).fontWeight, '700',
    'numeric font-weight is preserved');
}, 'serialization: font-weight');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('cnamed')).color, 'rgb(0, 0, 255)',
    'named color serializes to rgb()');
  assert_equals(getComputedStyle(document.getElementById('chex')).color, 'rgb(0, 255, 0)',
    'hex color serializes to rgb()');
  assert_equals(getComputedStyle(document.getElementById('crgb')).color, 'rgb(1, 2, 3)',
    'rgb() color is normalized with spaces');
  assert_equals(getComputedStyle(document.getElementById('calpha')).color, 'rgba(10, 20, 30, 0.5)',
    'rgba() with alpha < 1 serializes to rgba()');
}, 'serialization: color');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('bg')).backgroundColor, 'rgb(255, 255, 255)',
    'background-color hex serializes to rgb()');
}, 'serialization: background-color');
