test(() => {
  const node = document.getElementById('node');
  let seen = null;

  node.addEventListener('ready', (event) => {
    seen = event.detail.ok;
  });

  node.dispatchEvent(new CustomEvent('ready', { detail: { ok: true } }));
  assert_true(seen);
}, 'CustomEvent exposes detail to listeners');
