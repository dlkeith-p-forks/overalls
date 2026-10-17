/**
 * @cc [owner:ghuntley,label:verification;security] private-web-original-transports
 * This browser MUST retain the original fetch and WebSocket and never retry or
 * reconnect them. Closed counters MUST remain final after team re-addition.
 */
const privateWebState = { chunks: 0, echoes: 0, httpClosed: false, wsClosed: false };
const privateWebSocket = new WebSocket(`wss://${location.host}/ws`);
const privateWebTimer = setInterval(() => {
  if (privateWebSocket.readyState === WebSocket.OPEN) privateWebSocket.send("private-web-echo");
}, 100);
/** @param {MessageEvent<unknown>} event */
privateWebSocket.onmessage = event => {
  if (event.data === "private-web-echo") privateWebState.echoes += 1;
};
privateWebSocket.onclose = () => {
  clearInterval(privateWebTimer);
  privateWebState.wsClosed = true;
};
void (async () => {
  try {
    const response = await fetch("/stream");
    if (response.status !== 200 || !response.body) throw new Error("refused");
    const reader = response.body.getReader();
    for (;;) {
      const result = await reader.read();
      if (result.done) break;
      privateWebState.chunks += 1;
    }
  } finally {
    privateWebState.httpClosed = true;
  }
})().catch(() => {});

/** @returns {Promise<number>} */
async function privateWebFreshStatus() {
  return (await fetch("/", {redirect: "manual"})).status;
}
