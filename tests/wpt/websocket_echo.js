promise_test(() => {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket("ws://127.0.0.1:18488/ws");
    ws.send("Hello WebSocket!");
    
    let opened = false;
    let received_message = false;
    
    ws.onopen = () => {
      opened = true;
    };
    
    ws.onmessage = (event) => {
      received_message = true;
      assert_equals(event.data, "Hello WebSocket!");
      ws.close();
    };
    
    ws.onerror = (err) => {
      reject(new Error("WebSocket error: " + (err && err.message ? err.message : String(err))));
    };
    
    ws.onclose = () => {
      assert_true(opened, "WebSocket should have opened");
      assert_true(received_message, "WebSocket should have received message");
      resolve();
    };
  });
}, "WebSocket connects, echoes messages, and closes cleanly");
