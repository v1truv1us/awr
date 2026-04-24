test(() => {
  assert_equals(typeof globalThis.IntersectionObserver, 'undefined');
}, 'IntersectionObserver is not exposed until real render-backed semantics exist');
