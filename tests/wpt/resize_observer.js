test(() => {
  assert_equals(typeof globalThis.ResizeObserver, 'undefined');
}, 'ResizeObserver is not exposed until real render-backed semantics exist');
