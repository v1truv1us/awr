test(() => {
  const params = new URLSearchParams();
  params.append('name', 'Alice');
  params.append('id', '42');
  assert_equals(params.get('name'), 'Alice');
  assert_equals(params.get('id'), '42');
  assert_equals(params.get('missing'), null);
}, 'URLSearchParams append/get round-trip');

test(() => {
  const params = new URLSearchParams();
  params.append('a', '1');
  params.append('b', 'with space');
  params.append('c', 'two&three');
  const s = params.toString();
  assert_true(s.indexOf('a=1') >= 0);
  assert_true(s.indexOf('b=with+space') >= 0 || s.indexOf('b=with%20space') >= 0);
  assert_true(s.indexOf('c=two%26three') >= 0);
}, 'URLSearchParams toString URL-encodes values');

test(() => {
  const params = new URLSearchParams('x=1&y=2&y=3');
  assert_equals(params.get('x'), '1');
  assert_equals(params.get('y'), '2');
  const all = params.getAll('y');
  assert_equals(all.length, 2);
  assert_equals(all[0], '2');
  assert_equals(all[1], '3');
}, 'URLSearchParams parses query strings with repeated keys');
