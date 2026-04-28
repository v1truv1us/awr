test(() => {
  const ta = document.getElementById('comment');
  assert_equals(ta.type, 'textarea', 'textarea type is "textarea"');
  assert_equals(ta.defaultValue, 'Hello world', 'textarea defaultValue is textContent');
  assert_equals(ta.value, 'Hello world', 'textarea value equals defaultValue initially');
}, 'textarea defaultValue and value from textContent');

test(() => {
  const ta = document.getElementById('comment');
  ta.value = 'Changed';
  assert_equals(ta.value, 'Changed', 'textarea value after set');
  assert_equals(ta.defaultValue, 'Hello world', 'defaultValue unchanged after value set');
  assert_equals(ta.textContent, 'Hello world', 'textContent unchanged after value set');
}, 'setting textarea.value does not affect defaultValue or textContent');

test(() => {
  const ta = document.getElementById('crlf');
  assert_equals(ta.defaultValue, 'a\nb\nc\n', 'defaultValue after parser normalization');
  assert_equals(ta.value, 'a\nb\nc\n', 'value equals normalized defaultValue');
}, 'textarea value and defaultValue after parser text normalization');

test(() => {
  const ta = document.getElementById('comment');
  ta.value = null;
  assert_equals(ta.value, '', 'setting value to null yields empty string');
}, 'textarea value null becomes empty string');

test(() => {
  const ta = document.getElementById('comment');
  assert_equals(ta.name, 'comment', 'textarea name attribute');
  assert_equals(ta.placeholder, 'Write here', 'textarea placeholder attribute');
}, 'textarea name and placeholder attributes');
