// DOM Level-0 event handler properties (target.onfoo = fn)
// Verifies the smoke-test gap surfaced as B5 in the smoke report.

test(() => {
  const btn = document.getElementById('btn');
  let fired = false;
  btn.onclick = function () { fired = true; };
  btn.click();
  assert_true(fired, 'btn.onclick should run when btn.click() dispatches click');
}, 'element.onclick property is invoked on dispatch');

test(() => {
  const btn = document.getElementById('btn');
  let count = 0;
  btn.onclick = function () { count += 1; };
  // Replacing the property must replace the slot, not stack new listeners.
  btn.onclick = function () { count += 100; };
  btn.click();
  assert_equals(count, 100, 'replacing on-property should replace, not append');
}, 'element.on-property replaces previous handler');

test(() => {
  const btn = document.getElementById('btn');
  let count = 0;
  btn.onclick = function () { count += 1; };
  btn.onclick = null;
  btn.click();
  assert_equals(count, 0, 'setting on-property to null clears the handler');
}, 'element.on-property = null clears the handler');

test(() => {
  const btn = document.getElementById('btn');
  let order = [];
  btn.addEventListener('click', function () { order.push('addEventListener'); });
  btn.onclick = function () { order.push('on-property'); };
  btn.click();
  // Both must run; addEventListener-registered listeners run first
  // (matches Chrome at-target ordering).
  assert_equals(order.length, 2);
  assert_equals(order[0], 'addEventListener');
  assert_equals(order[1], 'on-property');
}, 'addEventListener listener and on-property both run on dispatch');

promise_test(() => {
  return new Promise((resolve) => {
    const xhr = new XMLHttpRequest();
    xhr.onload = function () {
      assert_equals(xhr.readyState, 4);
      assert_equals(xhr.status, 200);
      resolve();
    };
    xhr.onerror = function () { assert_unreached('xhr.onerror should not fire on success'); };
    xhr.open('GET', 'http://127.0.0.1:18488/');
    xhr.send();
  });
}, 'xhr.onload property fires on successful response');

promise_test(() => {
  return new Promise((resolve) => {
    const xhr = new XMLHttpRequest();
    const states = [];
    xhr.onreadystatechange = function () { states.push(xhr.readyState); };
    xhr.open('GET', 'http://127.0.0.1:18488/');
    xhr.send();
    xhr.onload = function () {
      // After completion, must have seen both state 1 (OPENED) and 4 (DONE).
      assert_true(states.indexOf(1) >= 0, 'should fire for readyState=1');
      assert_true(states.indexOf(4) >= 0, 'should fire for readyState=4');
      resolve();
    };
  });
}, 'xhr.onreadystatechange property fires for readyState transitions');
