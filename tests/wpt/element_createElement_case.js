test(() => {
  assert_equals(document.createElement('div').tagName, 'DIV');
  assert_equals(document.createElement('DIV').tagName, 'DIV');
  assert_equals(document.createElement('Span').tagName, 'SPAN');
  assert_equals(document.createElement('p').tagName, 'P');
}, 'createElement normalizes the input tag to uppercase');

test(() => {
  const el = document.createElement('div');
  el.setAttribute('count', 42);
  assert_equals(el.getAttribute('count'), '42');
  el.setAttribute('flag', true);
  assert_equals(el.getAttribute('flag'), 'true');
}, 'setAttribute coerces non-string values to strings');

test(() => {
  const el = document.createElement('div');
  el.removeAttribute('missing');
  assert_false(el.hasAttribute('missing'));
}, 'removeAttribute on a missing attribute is a no-op');
