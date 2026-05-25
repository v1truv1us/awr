// WPT: CSSStyleDeclaration inline declaration API (spec/subspecs/cssom.md §4.1)

test(() => {
  const el = document.getElementById('target');
  assert_equals(el.style.cssText, 'color: red; font-weight: bold;',
    'cssText getter serialises initial inline style');
}, 'cssText getter reflects inline style attribute');

test(() => {
  const el = document.getElementById('target');
  assert_equals(el.style.getPropertyValue('color'), 'red',
    'getPropertyValue returns the property value');
  assert_equals(el.style.getPropertyValue('font-weight'), 'bold');
  assert_equals(el.style.getPropertyValue('display'), '',
    'getPropertyValue returns empty string for unset property');
}, 'getPropertyValue reads individual declarations');

test(() => {
  const el = document.getElementById('empty');
  el.style.setProperty('color', 'green');
  assert_equals(el.style.getPropertyValue('color'), 'green');
  assert_equals(el.getAttribute('style'), 'color: green;',
    'setProperty syncs the style attribute');
}, 'setProperty adds a declaration and syncs the attribute');

test(() => {
  const el = document.getElementById('empty');
  el.style.setProperty('color', 'red');
  el.style.setProperty('color', 'blue', 'important');
  assert_equals(el.style.getPropertyValue('color'), 'blue',
    'setProperty with important priority stores the value');
  assert_true(el.getAttribute('style').includes('!important'),
    'style attribute serialises !important');
}, 'setProperty with important priority');

test(() => {
  const el = document.getElementById('target');
  const old = el.style.removeProperty('color');
  assert_equals(old, 'red', 'removeProperty returns the old value');
  assert_equals(el.style.getPropertyValue('color'), '',
    'property is absent after removeProperty');
  assert_false(el.getAttribute('style').includes('color:'),
    'style attribute no longer contains the removed property');
}, 'removeProperty removes a declaration and returns old value');

test(() => {
  const el = document.getElementById('empty');
  el.style.cssText = 'color: purple; display: none;';
  assert_equals(el.style.getPropertyValue('color'), 'purple');
  assert_equals(el.style.getPropertyValue('display'), 'none');
  assert_equals(el.getAttribute('style'), 'color: purple; display: none;',
    'cssText setter replaces all declarations');
  el.style.cssText = '';
  assert_equals(el.style.cssText, '', 'cssText setter with empty string clears all');
}, 'cssText setter replaces all inline declarations');

test(() => {
  const el = document.getElementById('empty');
  el.style.color = 'teal';
  assert_equals(el.style.color, 'teal', 'camelCase property getter works');
  assert_equals(el.style.getPropertyValue('color'), 'teal');
}, 'camelCase property shorthand get and set');

test(() => {
  const el = document.getElementById('empty');
  el.style.backgroundColor = 'yellow';
  assert_equals(el.style.backgroundColor, 'yellow',
    'multi-word camelCase (backgroundColor) maps to background-color');
  assert_equals(el.style.getPropertyValue('background-color'), 'yellow');
}, 'camelCase maps compound property names to kebab-case');
