// WPT: structural pseudo-classes in the cascade (spec/subspecs/cssom.md).
// getComputedStyle must honor :first-child / :last-child / :only-child /
// :nth-child(n) / :nth-of-type(n) with correct positional semantics.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('l1')).color, 'rgb(255, 0, 0)',
    ':first-child matches the first list item');
  assert_equals(getComputedStyle(document.getElementById('l3')).color, 'rgb(0, 0, 255)',
    ':last-child matches the last list item');
  assert_equals(getComputedStyle(document.getElementById('l2')).color, '',
    'a middle item matches neither :first-child nor :last-child');
}, 'cascade: :first-child / :last-child');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('l2')).fontWeight, '700',
    ':nth-child(2) matches the second item');
  assert_equals(getComputedStyle(document.getElementById('l1')).fontWeight, '400',
    ':nth-child(2) does not match the first item');
}, 'cascade: :nth-child(n)');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('solo')).fontStyle, 'italic',
    ':only-child matches a sole child');
}, 'cascade: :only-child');

test(() => {
  // <b> sits between the spans but :nth-of-type counts only spans, so the
  // three spans are type-indices 1, 2, 3 — odd ones are underlined.
  assert_equals(getComputedStyle(document.getElementById('s1')).textDecoration, 'underline',
    ':nth-of-type(odd) matches the 1st span');
  assert_equals(getComputedStyle(document.getElementById('s2')).textDecoration, 'none',
    ':nth-of-type(odd) does not match the 2nd span');
  assert_equals(getComputedStyle(document.getElementById('s3')).textDecoration, 'underline',
    ':nth-of-type(odd) matches the 3rd span');
}, 'cascade: :nth-of-type(odd)');
