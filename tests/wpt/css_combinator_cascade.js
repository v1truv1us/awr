// WPT: combinator + compound selectors in the cascade (spec/subspecs/cssom.md).
// getComputedStyle must apply descendant / child selectors and compound
// (AND) selectors with correct semantics — a compound `div.special` must NOT
// match a plain <div>, and a descendant `.box p` must NOT match a <p> outside
// the box.

test(() => {
  assert_equals(getComputedStyle(document.getElementById('desc')).color, 'red',
    'descendant selector ".box p" matches a <p> inside .box');
  assert_equals(getComputedStyle(document.getElementById('outside')).color, '',
    'descendant selector ".box p" does NOT match a <p> outside .box');
}, 'cascade: descendant combinator');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('special')).color, 'green',
    'compound selector "div.special" matches a <div class="special">');
  assert_equals(getComputedStyle(document.getElementById('plain')).color, '',
    'compound selector "div.special" does NOT match a plain <div> (AND semantics)');
}, 'cascade: compound selector AND semantics');

test(() => {
  assert_equals(getComputedStyle(document.getElementById('kid')).fontWeight, 'bold',
    'child selector "ul > li" matches a direct <li> child of <ul>');
}, 'cascade: child combinator');
