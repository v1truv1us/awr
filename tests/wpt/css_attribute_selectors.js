// WPT: attribute selectors in the cascade (spec/subspecs/cssom.md).
// getComputedStyle must honor attribute selectors — presence `[attr]`, exact
// `[attr=val]`, and whitespace-list `[attr~=val]` — with correct semantics.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('text')).color, 'red',
    '[type=text] exact attribute selector applies via getComputedStyle');
  assert_equals(getComputedStyle(document.getElementById('pass')).color, '',
    '[type=text] does not match an input of a different type');
}, 'cascade: [attr=val] exact');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('req')).fontWeight, 'bold',
    '[required] presence attribute selector applies');
  assert_equals(getComputedStyle(document.getElementById('text')).fontWeight, 'normal',
    '[required] does not match an element lacking the attribute');
}, 'cascade: [attr] presence');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('flag')).color, 'green',
    '[data-tags~=urgent] matches a whitespace-separated word');
  assert_equals(getComputedStyle(document.getElementById('noflag')).color, '',
    '[data-tags~=urgent] does not match when the word is absent');
}, 'cascade: [attr~=val] includes');
