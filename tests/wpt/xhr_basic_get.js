promise_test(async () => {
  const xhr = new XMLHttpRequest();
  const states = [];
  let loaded = false;
  const finished = new Promise((resolve, reject) => {
    xhr.addEventListener('loadend', resolve);
    xhr.addEventListener('error', reject);
  });

  xhr.addEventListener('readystatechange', () => {
    states.push(xhr.readyState);
  });
  xhr.addEventListener('load', () => {
    loaded = true;
  });

  xhr.open('GET', './xhr_basic.txt');
  xhr.send();

  await finished;

  assert_true(loaded);
  assert_equals(xhr.status, 200);
  assert_equals(xhr.responseText, 'hello xhr\n');
  assert_true(states.includes(1));
  assert_true(states.includes(4));
}, 'XMLHttpRequest performs a basic async GET');
