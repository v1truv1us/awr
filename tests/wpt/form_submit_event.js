// form.requestSubmit() / form submit event — the JS-level surface
// that mirrors the TUI's Enter-in-text implicit-submission path.
// T-87 / Tier 1 §4.2 closure gate.

test(() => {
  const f = document.getElementById('f');
  let fired = false;
  let observed_target = null;
  f.addEventListener('submit', (e) => {
    fired = true;
    observed_target = e.target;
  });
  f.requestSubmit();
  assert_true(fired, 'submit listener fires from requestSubmit');
  assert_equals(observed_target, f, 'submit event target is the form');
}, 'form.requestSubmit() dispatches a submit event on the form');

test(() => {
  const f = document.getElementById('f');
  let cancelled_observed = false;
  f.addEventListener('submit', (e) => {
    // Spec: submit events are cancelable so a handler can call
    // preventDefault() to stop navigation.
    assert_equals(e.cancelable, true);
    e.preventDefault();
    cancelled_observed = true;
  });
  f.requestSubmit();
  assert_true(cancelled_observed);
}, 'submit event is cancelable; preventDefault() runs');

test(() => {
  // Spec: form.submit() does NOT dispatch a submit event (per HTML5,
  // it goes straight to the submission algorithm). AWR's environment
  // doesn't navigate, but the *no-event* contract still matters for
  // code that relies on `submit()` to bypass listeners (e.g. legacy
  // forms that want to avoid recursion). The method must exist and
  // calling it must not throw or fire the listener.
  const f = document.getElementById('f');
  let fired = false;
  f.addEventListener('submit', () => { fired = true; });
  f.submit();
  assert_equals(fired, false, 'form.submit() does NOT dispatch submit event');
  assert_equals(typeof f.requestSubmit, 'function', 'requestSubmit is a function');
  assert_equals(typeof f.submit, 'function', 'submit is a function');
}, 'form.submit() exists but does not dispatch the submit event');

test(() => {
  // Submit bubbles up through the DOM.
  const f = document.getElementById('f');
  const root = document.body;
  let parent_fired = false;
  root.addEventListener('submit', () => { parent_fired = true; });
  f.requestSubmit();
  assert_true(parent_fired, 'submit event bubbles to body');
}, 'submit event bubbles through the DOM');

test(() => {
  // The TUI's implicit-submission path on Enter in a text input is
  // documented to act *as if* requestSubmit() ran. JS code can lean
  // on a single `submit` listener to catch both real-user Enter and
  // programmatic submit calls.
  const f = document.getElementById('f');
  const inp = document.getElementById('user');
  let saw = null;
  f.addEventListener('submit', (e) => {
    e.preventDefault();
    saw = inp.value;
  });
  inp.value = 'alice';
  f.requestSubmit();
  assert_equals(saw, 'alice');
}, 'submit listener observes input.value at submission time');
