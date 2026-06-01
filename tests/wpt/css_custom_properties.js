// WPT: CSS custom properties (--foo) + var() substitution
// (spec/subspecs/cssom.md). Resolved at the getComputedStyle boundary.
// Custom properties inherit; var(--foo, fallback) substitutes the cascaded
// custom-property value, or the fallback when the property is not set.

test(() => {
  // --brand is declared on :root-equivalent (#root) and read directly.
  assert_equals(getComputedStyle(document.getElementById('root')).getPropertyValue('--brand'), 'blue',
    'a custom property is exposed via getPropertyValue');
}, 'custom property: direct read');

test(() => {
  // #child does not set --brand itself but inherits it from #root.
  assert_equals(getComputedStyle(document.getElementById('child')).getPropertyValue('--brand'), 'blue',
    'custom properties inherit to descendants');
}, 'custom property: inheritance');

test(() => {
  // color: var(--brand) resolves the inherited custom property to blue,
  // then computed-value serialization turns the keyword into rgb().
  assert_equals(getComputedStyle(document.getElementById('child')).color, 'rgb(0, 0, 255)',
    'var(--brand) substitutes the inherited custom-property value');
}, 'var(): substitution of an inherited custom property');

test(() => {
  // --missing is never declared, so var(--missing, green) uses the fallback.
  assert_equals(getComputedStyle(document.getElementById('fb')).color, 'rgb(0, 128, 0)',
    'var(--missing, green) falls back to the second argument');
}, 'var(): fallback when the custom property is unset');

test(() => {
  // A locally declared custom property overrides the inherited one.
  assert_equals(getComputedStyle(document.getElementById('override')).color, 'rgb(255, 0, 0)',
    'a locally set custom property overrides the inherited value');
}, 'custom property: local override');
