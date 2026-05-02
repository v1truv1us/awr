test(() => {
  assert_equals(document.querySelectorAll('#root > p').length, 3);
  assert_equals(document.querySelectorAll('#root *').length, 3);
}, 'querySelectorAll supports child combinator and universal selector');

test(() => {
  assert_equals(document.querySelectorAll('p + p').length, 2);
  assert_equals(document.querySelectorAll('p ~ p').length, 2);
}, 'querySelectorAll supports adjacent (+) and general (~) sibling combinators');

test(() => {
  assert_equals(document.querySelectorAll('p[data-x]').length, 3);
  assert_equals(document.querySelectorAll('p[data-x="2"]').length, 1);
  assert_equals(document.querySelectorAll('p:not([data-x="2"])').length, 2);
}, 'querySelectorAll supports presence, equality, and :not() attribute selectors');
