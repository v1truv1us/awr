test(() => {
  const forms = document.forms;
  assert_equals(forms.length, 2, 'document.forms.length');
  assert_equals(forms[0].id, 'form1', 'forms[0] by index');
  assert_equals(forms[1].id, 'form2', 'forms[1] by index');
}, 'document.forms collection access (WPT document.forms pattern)');

test(() => {
  const forms = document.forms;
  assert_not_equals(forms, null, 'document.forms exists');
  assert_true(Array.isArray(forms) || typeof forms.length === 'number', 'forms is array-like');
}, 'document.forms is a collection');

test(() => {
  const form = document.getElementById('form1');
  assert_not_equals(form, null, 'form element exists');
  assert_equals(form.tagName, 'FORM', 'form tagName');
  assert_equals(form.getAttribute('action'), '/submit', 'form action attribute');
  assert_equals(form.getAttribute('method'), 'post', 'form method attribute');
}, 'form element basic attributes');
