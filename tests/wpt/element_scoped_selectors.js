test(() => {
  const scope = document.getElementById('scope');
  const first = scope.querySelector('.item');
  assert_equals(first && first.textContent, 'two');
}, 'element.querySelector searches within the element subtree');

test(() => {
  const scope = document.getElementById('scope');
  const texts = scope.querySelectorAll('.item').map((el) => el.textContent);
  assert_array_equals(texts, ['two', 'three']);
}, 'element.querySelectorAll is scoped to descendants');
