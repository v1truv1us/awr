// WPT: selector functions :not() / :is() / :where() in the cascade
// (spec/subspecs/cssom.md). The DOM selector engine evaluates these forms
// and the cascade routes :-bearing rules through it. Specificity rules:
//   :where()      contributes 0 specificity
//   :is() / :not() take the specificity of their most-specific argument

test(() => {
  // p:not(.skip) matches every <p> without class "skip".
  assert_equals(getComputedStyle(document.getElementById('p1')).color, 'rgb(255, 0, 0)',
    ':not(.skip) matches a paragraph without the class');
  assert_equals(getComputedStyle(document.getElementById('p2')).color, '',
    ':not(.skip) does not match a paragraph with the class');
}, 'cascade: :not(selector)');

test(() => {
  // :not(.a, .b) is a selector list — matches when NONE of the args match.
  assert_equals(getComputedStyle(document.getElementById('q1')).fontWeight, '700',
    ':not(.a, .b) matches an element with neither class');
  assert_equals(getComputedStyle(document.getElementById('q2')).fontWeight, '400',
    ':not(.a, .b) excludes an element matching one listed arg');
}, 'cascade: :not(selector list)');

test(() => {
  // :is(h1, h2, .title) matches if ANY arg matches.
  assert_equals(getComputedStyle(document.getElementById('h')).fontStyle, 'italic',
    ':is(h1, h2, .title) matches via tag arg');
  assert_equals(getComputedStyle(document.getElementById('t')).fontStyle, 'italic',
    ':is(h1, h2, .title) matches via class arg');
  assert_equals(getComputedStyle(document.getElementById('n')).fontStyle, 'normal',
    ':is(...) does not match an element matching none of its args');
}, 'cascade: :is(selector list)');

test(() => {
  // Specificity battle: `:where(#box) .item` (0,1,0 — :where adds 0) sets
  // green and comes last in source order; `:is(#box) .item` (0,2,0 — :is
  // takes the #box id specificity) is declared earlier yet wins on
  // specificity, proving :where contributes 0 and :is takes its argument.
  assert_equals(getComputedStyle(document.getElementById('w')).color, 'rgb(0, 0, 255)',
    ':where() contributes 0 specificity, so the higher-specificity rule wins');
}, 'specificity: :where() is zero, :is()/:not() take their argument');
