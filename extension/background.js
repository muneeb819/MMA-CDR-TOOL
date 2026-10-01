const API_WS = "wss://YOUR-API-HOST/ws/v2/vici";
let socket;
let latest = null;

function connect() {
  socket = new WebSocket(API_WS);
  socket.onopen = () => console.log("[CDR] WSS connected");
  socket.onmessage = e => {
    try {
      latest = JSON.parse(e.data);
      chrome.storage.local.set({ latest });
    } catch {}
  };
  socket.onclose = () => setTimeout(connect, 3000);
}

connect();

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === "TELEMETRY") {
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg.payload));
    sendResponse({ok: true});
  }
  if (msg.type === "STATE") {
    sendResponse(latest);
  }
  return true;
});
