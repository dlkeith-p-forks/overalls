/**
 * Same-origin Android display client. The server supplies the ticket and
 * endpoint; this hook never constructs a foreign origin or embeds an iframe.
 * @typedef {{el: HTMLElement, socket?: WebSocket, canvas?: HTMLCanvasElement, mode?: string}} AndroidDisplayHook
 */
export const AndroidDisplay = {
  /** @this {AndroidDisplayHook} */
  mounted() {
    this.canvas = /** @type {HTMLCanvasElement} */ (this.el.querySelector("canvas"));
    this.status = this.el.querySelector("[data-display-status]");
    this.handleEvent("android_display_ticket", ({ticket, mode}) => this.connect(ticket, mode));
    this.el.addEventListener("keydown", (event) => this.key(event));
    this.el.addEventListener("pointerdown", (event) => this.pointer(event, 1));
    this.el.addEventListener("pointerup", (event) => this.pointer(event, 0));
    this.el.addEventListener("pointermove", (event) => this.pointer(event, 0));
  },
  /** @this {AndroidDisplayHook} */
  destroyed() { this.socket?.close(); },
  /** @this {AndroidDisplayHook} @param {string} ticket @param {string} mode */
  connect(ticket, mode) {
    if (!ticket || !this.canvas) return;
    this.mode = mode;
    const base = this.el.dataset.displayWebsocketUrl;
    if (!base) return this.setStatus("relay-unavailable");
    const url = new URL(base, window.location.origin);
    url.searchParams.set("ticket", ticket);
    url.searchParams.set("mode", mode);
    this.socket?.close();
    this.socket = new WebSocket(url, "android-display-v1");
    this.socket.binaryType = "arraybuffer";
    this.socket.onopen = () => this.setStatus("connected");
    this.socket.onclose = () => this.setStatus("closed");
    this.socket.onerror = () => this.setStatus("relay-unavailable");
    this.socket.onmessage = (event) => this.frame(event.data);
  },
  /** @this {AndroidDisplayHook} @param {string} status */
  setStatus(status) { this.status?.setAttribute("data-status", status); },
  /** @this {AndroidDisplayHook} @param {ArrayBuffer} bytes */
  frame(bytes) {
    if (!(bytes instanceof ArrayBuffer) || bytes.byteLength < 25 || !this.canvas) return;
    const view = new DataView(bytes);
    if (view.getUint8(0) !== 1) return;
    const length = view.getUint32(17);
    if (length !== bytes.byteLength - 21 || length > 262144) return;
    // The stream adapter delivers decoded raw rectangles as RGBA payloads.
    const width = this.canvas.width;
    const height = this.canvas.height;
    const pixels = new Uint8ClampedArray(bytes, 21, length);
    if (pixels.length !== width * height * 4) return;
    this.canvas.getContext("2d")?.putImageData(new ImageData(pixels, width, height), 0, 0);
  },
  /** @this {AndroidDisplayHook} @param {KeyboardEvent} event */
  key(event) {
    if (this.mode !== "controller" && this.mode !== "rw") return;
    const payload = new TextEncoder().encode(JSON.stringify({op: "key", down: event.type === "keydown", key: event.key}));
    this.sendInput(payload);
  },
  /** @this {AndroidDisplayHook} @param {Uint8Array} payload */
  sendInput(payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    const frame = new Uint8Array(14 + payload.length);
    const view = new DataView(frame.buffer);
    view.setUint8(0, 2);
    view.setBigUint64(1, BigInt(0));
    view.setUint32(10, payload.length);
    frame.set(payload, 14);
    this.socket.send(frame);
  },
  /** @this {AndroidDisplayHook} @param {PointerEvent} event @param {number} buttons */
  pointer(event, buttons) {
    if (this.mode !== "controller" && this.mode !== "rw") return;
    const payload = new TextEncoder().encode(JSON.stringify({op: "pointer", x: event.offsetX, y: event.offsetY, buttons}));
    this.sendInput(payload);
  },
};
