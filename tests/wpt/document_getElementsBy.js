test(() => {
  assert_equals(document.getElementsByClassName('item').length, 2);
  assert_equals(document.getElementsByTagName('p').length, 2);
}, 'document.getElementsByClassName and getElementsByTagName return matches');
