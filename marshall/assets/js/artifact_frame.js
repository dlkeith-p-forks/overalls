// @ts-check

/**
 * Bridges page storage requests from the sandboxed artifact frame to the
 * LiveView. The frame has an opaque origin, so the message source window (not
 * the origin string) identifies it.
 *
 * @typedef {"personal" | "shared"} Namespace
 * @typedef {{type: "marshall-artifact-storage", id: number, op: "get" | "set" | "delete" | "list", namespace: Namespace, key?: string, value?: string, prefix?: string}} StorageRequest
 * @typedef {{el: HTMLElement, pushEvent: (event: string, payload: Record<string, unknown>, reply?: (reply: Record<string, unknown>) => void) => void, listener?: (event: MessageEvent) => void, inflight: number}} FrameHook
 */

export const MAX_KEY_BYTES = 256;
export const MAX_VALUE_BYTES = 5 * 1024 * 1024;
export const MAX_INFLIGHT = 16;

/**
 * @cc [owner:ghuntley,label:security] artifact-frame-message-schema
 * Only messages from the artifact frame's own window with the closed request
 * shape, a bounded UTF-8 key and value, and a known namespace reach the server.
 * Everything else is dropped without a reply.
 * @param {unknown} data
 * @returns {StorageRequest | null}
 */
export function parseRequest(data) {
  if (typeof data !== "object" || data === null) return null;
  const message = /** @type {Record<string, unknown>} */ (data);
  if (message.type !== "marshall-artifact-storage") return null;
  const {id, op, namespace, key, value, prefix} = message;
  if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 0) return null;
  if (op !== "get" && op !== "set" && op !== "delete" && op !== "list") return null;
  if (namespace !== "personal" && namespace !== "shared") return null;
  const encoder = new TextEncoder();
  if (op !== "list") {
    if (typeof key !== "string" || key.length === 0 || encoder.encode(key).length > MAX_KEY_BYTES) return null;
  }
  if (op === "set" && (typeof value !== "string" || encoder.encode(value).length > MAX_VALUE_BYTES)) return null;
  if (prefix !== undefined && (typeof prefix !== "string" || encoder.encode(prefix).length > MAX_KEY_BYTES)) return null;
  return /** @type {StorageRequest} */ ({type: "marshall-artifact-storage", id, op, namespace, key, value, prefix});
}

/** @param {FrameHook} hook @returns {HTMLIFrameElement | null} */
function frame(hook) {
  const element = hook.el.querySelector("iframe[data-artifact-frame]");
  return element instanceof HTMLIFrameElement ? element : null;
}

/** @type {Record<string, unknown>} */
export const ArtifactFrame = {
  /** @this {FrameHook} */
  mounted() {
    this.inflight = 0;
    this.listener = (event) => {
      const target = frame(this);
      if (!target || event.source !== target.contentWindow) return;
      const request = parseRequest(event.data);
      if (!request || this.inflight >= MAX_INFLIGHT) return;
      this.inflight += 1;
      const source = target.contentWindow;
      this.pushEvent("storage", {...request}, (reply) => {
        this.inflight -= 1;
        // The frame's origin is opaque ("null"), so "*" is the only target that
        // reaches it; the reply goes only to the frame window that asked.
        source?.postMessage({type: "marshall-artifact-storage-result", id: request.id, ...reply}, "*");
      });
    };
    window.addEventListener("message", this.listener);
  },
  /** @this {FrameHook} */
  destroyed() {
    if (this.listener) window.removeEventListener("message", this.listener);
  },
};
