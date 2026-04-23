(function(global) {
  'use strict';

  const results = [];
  let pending = 0;

  function formatValue(value) {
    if (typeof value === 'string') return JSON.stringify(value);
    try {
      return JSON.stringify(value);
    } catch (_) {
      return String(value);
    }
  }

  function record(status, name, message) {
    results.push({ status, name, message: message || '' });
  }

  function fail(message) {
    throw new Error(message || 'assertion failed');
  }

  global.__wpt_results__ = results;

  global.test = function test(fn, name) {
    try {
      fn();
      record('PASS', name, '');
    } catch (err) {
      record('FAIL', name, err && err.message ? err.message : String(err));
    }
  };

  global.promise_test = function promise_test(fn, name) {
    pending += 1;
    Promise.resolve()
      .then(fn)
      .then(function() {
        record('PASS', name, '');
      }, function(err) {
        record('FAIL', name, err && err.message ? err.message : String(err));
      })
      .finally(function() {
        pending -= 1;
      });
  };

  global.assert_true = function assert_true(actual, message) {
    if (actual !== true) {
      fail(message || ('expected true but got ' + formatValue(actual)));
    }
  };

  global.assert_false = function assert_false(actual, message) {
    if (actual !== false) {
      fail(message || ('expected false but got ' + formatValue(actual)));
    }
  };

  global.assert_equals = function assert_equals(actual, expected, message) {
    if (actual !== expected) {
      fail(message || ('expected ' + formatValue(expected) + ' but got ' + formatValue(actual)));
    }
  };

  global.assert_not_equals = function assert_not_equals(actual, expected, message) {
    if (actual === expected) {
      fail(message || ('did not expect ' + formatValue(actual)));
    }
  };

  global.assert_array_equals = function assert_array_equals(actual, expected, message) {
    if (!Array.isArray(actual) || !Array.isArray(expected)) {
      fail(message || 'expected arrays');
    }
    if (actual.length !== expected.length) {
      fail(message || ('expected array length ' + expected.length + ' but got ' + actual.length));
    }
    for (let i = 0; i < actual.length; i += 1) {
      if (actual[i] !== expected[i]) {
        fail(message || ('expected ' + formatValue(expected) + ' but got ' + formatValue(actual)));
      }
    }
  };

  global.assert_unreached = function assert_unreached(message) {
    fail(message || 'assert_unreached');
  };

  global.__wpt_pending__ = function __wpt_pending__() {
    return pending;
  };

  global.done = function done() {};
})(globalThis);
