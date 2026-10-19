import RFB from "../vendor/novnc/core/rfb.js";

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
    this.handleEvent("android_display_ticket", ({ticket, mode, generation, machine_id}) => this.connect(ticket, mode, generation, machine_id));
  },
  /** @this {AndroidDisplayHook} */
  destroyed() { this.rfb?.disconnect(); },
  /** @this {AndroidDisplayHook} @param {string} ticket @param {string} mode @param {number} generation @param {string} machineId */
  connect(ticket, mode, generation, machineId) {
    if (!ticket || !this.canvas) return;
    this.mode = mode;
    const base = this.el.dataset.displayWebsocketUrl;
    if (!base) return this.setStatus("relay-unavailable");
    const url = new URL(base, window.location.origin);
    url.searchParams.set("ticket", ticket);
    url.searchParams.set("mode", mode);
    url.searchParams.set("generation", String(generation));
    url.searchParams.set("machine_id", machineId || this.el.dataset.machineId || "");
    this.rfb?.disconnect();
    this.rfb = new RFB(this.el, url.toString(), {credentials: {}});
    this.rfb.viewOnly = mode !== "controller";
    this.rfb.scaleViewport = true;
    this.rfb.resizeSession = false;
    this.rfb.addEventListener("connect", () => this.setStatus("connected"));
    this.rfb.addEventListener("disconnect", () => this.setStatus("closed"));
    this.rfb.addEventListener("securityfailure", () => this.setStatus("relay-unavailable"));
  },
  /** @this {AndroidDisplayHook} @param {string} status */
  setStatus(status) { this.status?.setAttribute("data-status", status); },
};
