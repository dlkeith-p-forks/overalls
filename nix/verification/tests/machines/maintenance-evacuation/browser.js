/**
 * @cc [owner:ghuntley,label:verification] evacuation-ordinary-event-refusal
 * Refusal probes MUST send real LiveView mutation events through the mounted
 * browser transport, without changing server authority or suppressing guards.
 */
/** @param {{name: string, payload: Record<string, string>}} request @returns {void} */
function pushEvent(request) {
  /** @param {unknown} value @returns {value is Record<string, unknown>} */
  function record(value) {
    return typeof value === "object" && value !== null;
  }
  /** @type {unknown} */
  const socket = Reflect.get(window, "liveSocket");
  if (!record(socket) || !record(socket.main)) throw new Error("Missing LiveView transport");
  const main = socket.main;
  const element = document.querySelector("[data-phx-main].phx-connected");
  if (!element || typeof main.pushHookEvent !== "function") throw new Error("Missing mounted view");
  main.pushHookEvent(element, null, request.name, request.payload);
}
