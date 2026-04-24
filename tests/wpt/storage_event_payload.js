test(() => {
  localStorage.clear();
  let payload = null;
  function onStorage(event) { payload = event; }
  window.addEventListener('storage', onStorage);
  localStorage.setItem('alpha', '1');
  localStorage.setItem('alpha', '2');
  localStorage.removeItem('alpha');
  localStorage.clear();
  window.removeEventListener('storage', onStorage);

  assert_equals(payload, null);
}, 'storage does not dispatch same-window storage events');
