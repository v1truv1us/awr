test(() => {
  const btn = document.getElementById('btn');
  assert_equals(btn.tagName, 'BUTTON', 'button tagName');
  assert_equals(btn.type, 'submit', 'button type defaults to submit');
  assert_equals(btn.textContent, 'Go', 'button textContent');
  assert_equals(btn.value, 'go_val', 'button value attribute');
}, 'button element type and value (WPT the-button-element pattern)');

test(() => {
  const reset = document.getElementById('reset');
  assert_equals(reset.type, 'reset', 'reset button type');
}, 'button type=reset');

test(() => {
  const sel = document.getElementById('choice');
  assert_equals(sel.tagName, 'SELECT', 'select tagName');
  assert_equals(sel.name, 'color', 'select name attribute');
  assert_equals(sel.value, '', 'select initial value');
}, 'select element basic properties');

test(() => {
  const sub = document.getElementById('sub');
  assert_equals(sub.type, 'submit', 'submit input type');
  assert_equals(sub.value, 'Send', 'submit input value');
}, 'input type=submit value');
