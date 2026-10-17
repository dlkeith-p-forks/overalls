/**
 * @cc [owner:ghuntley,label:verification;security] sharing-web-original-transports
 * This browser MUST retain the original fetch and WebSocket and never retry or
 * reconnect them; closure flags MUST become final after revocation. Provenance:
 * mirrors the private-web original-transports discipline for the combined
 * sharing journey.
 */
const sharingWebState = { chunks: 0, echoes: 0, httpClosed: false, wsClosed: false };
const sharingWebSocket = new WebSocket(`wss://${location.host}/ws`);
const sharingWebTimer = setInterval(() => {
  if (sharingWebSocket.readyState === WebSocket.OPEN) sharingWebSocket.send("private-web-echo");
}, 100);
/** @param {MessageEvent<unknown>} event */
sharingWebSocket.onmessage = event => {
  if (event.data === "private-web-echo") sharingWebState.echoes += 1;
};
sharingWebSocket.onclose = () => {
  clearInterval(sharingWebTimer);
  sharingWebState.wsClosed = true;
};
void (async () => {
  try {
    const response = await fetch("/stream");
    if (response.status !== 200 || !response.body) throw new Error("refused");
    const reader = response.body.getReader();
    for (;;) {
      const result = await reader.read();
      if (result.done) break;
      sharingWebState.chunks += 1;
    }
  } finally {
    sharingWebState.httpClosed = true;
  }
})().catch(() => {});

/** @returns {Promise<number>} */
async function sharingWebFreshStatus() {
  return (await fetch("/", { redirect: "manual" })).status;
}
