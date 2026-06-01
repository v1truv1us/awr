// WPT: @media rules in the cascade (spec/subspecs/cssom.md). Rules nested in
// an @media block apply via getComputedStyle only when the condition matches
// the viewport. The WPT runner is 80 columns -> 640 CSS px wide, and the
// terminal color scheme is dark.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('wide')).color, 'rgb(255, 0, 0)',
    '@media (min-width: 600px) applies at a 640px viewport');
  assert_equals(getComputedStyle(document.getElementById('narrow')).color, '',
    '@media (min-width: 700px) does not apply at a 640px viewport');
}, '@media min-width matching');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('small')).color, '',
    '@media (max-width: 100px) does not apply at a 640px viewport');
  assert_equals(getComputedStyle(document.getElementById('base')).color, 'rgb(255, 165, 0)',
    'an unconditional rule still applies');
}, '@media max-width non-matching + unconditional');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('dark')).fontWeight, '700',
    '@media (prefers-color-scheme: dark) applies (terminal default is dark)');
}, '@media prefers-color-scheme');
