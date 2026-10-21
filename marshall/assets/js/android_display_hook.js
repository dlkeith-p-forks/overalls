/**
 * Build the hook with an injectable RFB constructor for browser probes.
 * @param {typeof RFBClient} RFBClient
 * @returns {Record<string, Function>}
 */
export function createAndroidDisplay(RFBClient) {
  return {
  /** @this {AndroidDisplayHook} */
  mounted() {
    this.rfbTarget = /** @type {HTMLElement} */ (this.el.querySelector("[data-display-target]"));
    this.status = /** @type {HTMLElement} */ (this.el.querySelector("[data-display-status]"));
    this.handleEvent("android_display_ticket", ({ticket, mode, generation, machine_id}) => this.connect(ticket, mode, generation, machine_id));
  },
  /** @this {AndroidDisplayHook} */
  destroyed() { this.rfb?.disconnect(); },
  /** @this {AndroidDisplayHook} @param {string} ticket @param {string} mode @param {number} generation @param {string} machineId */
  connect(ticket, mode, generation, machineId) {
    if (!ticket || !this.rfbTarget) return;
    this.mode = mode;
    const base = this.el.dataset.displayWebsocketUrl;
    if (!base) return this.setStatus("relay-unavailable");
    const url = new URL(base, window.location.origin);
    url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    url.searchParams.set("ticket", ticket);
    url.searchParams.set("mode", mode);
    url.searchParams.set("generation", String(generation));
    url.searchParams.set("machine_id", machineId || this.el.dataset.machineId || "");
    this.rfb?.disconnect();
    // noVNC creates and owns its canvas. Clear the target before each connection
    // so LiveView reconnects cannot accumulate duplicate canvases.
    this.rfbTarget.replaceChildren();
    this.rfb = new RFBClient(this.rfbTarget, url.toString(), {credentials: {}});
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
}
