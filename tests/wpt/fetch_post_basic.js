// Positive POST case for fetch(). Posts a string body to the in-process
// echo server set up by wpt_runner.zig. Asserts the round-trip body
// reflects the method and the bytes we sent — proves that:
//   * the polyfill drops the GET-only check and accepts POST
//   * raw_fetch threads method+body through to the host
//   * Page.fetchAdapter routes to Client.fetchRequest with the right shape
//   * Client.fetchOnceStd selects sendBodyComplete for POST
//   * the HTTP/1.1 over std.http.Client path frames Content-Type and
//     Content-Length correctly for the receiving end
//
// Server contract: the echo server returns "{METHOD}|{BODY}" verbatim with
// Content-Type: text/plain. See AwrPostEcho in tests/wpt_runner.zig.
promise_test(async () => {
  const url = 'http://127.0.0.1:18488/echo';
  const response = await fetch(url, { method: 'POST', body: 'hello=world' });
  assert_equals(response.status, 200, 'status should be 200');
  const text = await response.text();
  assert_equals(text, 'POST|hello=world', 'echo body should be METHOD|BODY');
}, 'fetch() POST with string body round-trips through echo server');
