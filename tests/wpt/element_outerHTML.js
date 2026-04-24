test(() => {
  const node = document.getElementById('node');
  assert_equals(node.outerHTML, '<div id="node" data-kind="primary">hello<span>world</span></div>');
}, 'outerHTML returns authoritative serialization including attributes and descendants');
