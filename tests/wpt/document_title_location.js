test(() => {
  assert_equals(document.title, 'Harness Title');
  document.title = 'Updated Title';
  assert_equals(document.title, 'Updated Title');
}, 'document.title getter and setter round-trip');

test(() => {
  assert_equals(location.href, 'http://example.com/');
  assert_equals(location.origin, 'http://example.com');
  assert_equals(location.protocol, 'http:');
  assert_equals(location.hostname, 'example.com');
  assert_equals(location.host, 'example.com');
  assert_equals(location.port, '');
  assert_equals(location.pathname, '/');
  assert_equals(location.search, '');
  assert_equals(location.hash, '');
}, 'location exposes basic parsed URL fields');
