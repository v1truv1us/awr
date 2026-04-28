test(() => {
  const input = document.getElementById('name');
  assert_equals(input.type, 'text', 'input type defaults to text');
  assert_equals(input.value, 'Alice', 'input.value reflects value attribute');
  assert_equals(input.defaultValue, 'Alice', 'input.defaultValue is value attribute');
  assert_equals(input.name, 'username', 'input.name reflects name attribute');
}, 'input element value, defaultValue, type, and name reflect attributes');

test(() => {
  const input = document.getElementById('name');
  input.value = 'Bob';
  assert_equals(input.value, 'Bob', 'input.value after set');
  assert_equals(input.defaultValue, 'Alice', 'defaultValue unchanged after value set');
}, 'setting input.value does not change defaultValue');

test(() => {
  const input = document.getElementById('pw');
  assert_equals(input.type, 'password', 'password input type');
  assert_equals(input.value, '', 'password value from empty attribute');
  input.value = 'secret';
  assert_equals(input.value, 'secret', 'password value after set');
}, 'password input type and value behavior');

test(() => {
  const input = document.getElementById('cb');
  assert_equals(input.type, 'checkbox', 'checkbox input type');
  assert_equals(input.value, 'on', 'checkbox default value is "on"');
}, 'checkbox input type returns "on" as value');

test(() => {
  const input = document.getElementById('hidden');
  assert_equals(input.type, 'hidden', 'hidden input type');
  assert_equals(input.value, 'tok123', 'hidden input value');
}, 'hidden input type and value');

test(() => {
  const input = document.getElementById('name');
  assert_equals(input.placeholder, 'Enter name', 'placeholder attribute');
  assert_equals(input.required, true, 'required attribute');
  assert_equals(input.readOnly, false, 'readOnly absent');
}, 'input placeholder, required, readOnly attributes');
