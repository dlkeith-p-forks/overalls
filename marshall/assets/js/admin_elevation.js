// @ts-check
/**
 * @typedef {{id: string, publicKey: PublicKeyCredentialRequestOptions}} Challenge
 * @typedef {{el: HTMLElement, handleEvent: (event: string, callback: (payload: unknown) => void) => void,
 * pushEvent: (event: string, payload: object, callback: (response: unknown) => void) => void,
 * cleanup?: () => void, closeElevation?: () => void}} ElevationHook
 */

/** @param {unknown} value @returns {value is Record<string, unknown>} */
const record = (value) => typeof value === "object" && value !== null;
/** @param {string} value @returns {Uint8Array<ArrayBuffer>} */
const decode = (value) => {
  if (!/^[A-Za-z0-9_-]{1,4096}$/.test(value)) throw new Error("Invalid encoding");
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(normalized.padEnd(normalized.length + (4 - normalized.length % 4) % 4, "=")), (c) => c.charCodeAt(0));
};
/** @param {ArrayBuffer} value @returns {string} */
const encode = (value) => btoa(String.fromCharCode(...new Uint8Array(value)))
  .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/**
 * @cc [owner:ghuntley,label:security] admin-challenge-validated-boundary
 * Browser ceremonies MUST use only validated server challenges with required
 * user verification; malformed replies MUST never reach the authenticator.
 * @param {unknown} response
 * @returns {Challenge | null}
 */
export function verificationChallenge(response) {
  if (!record(response) || response.ok !== true || !record(response.challenge)) return null;
  const {id, publicKey} = response.challenge;
  if (typeof id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id) || !record(publicKey) ||
      typeof publicKey.challenge !== "string" || typeof publicKey.rpId !== "string" ||
      publicKey.userVerification !== "required" || !Array.isArray(publicKey.allowCredentials) ||
      publicKey.allowCredentials.length < 1 || publicKey.allowCredentials.length > 10) return null;
  try {
    /** @type {PublicKeyCredentialDescriptor[]} */
    const credentials = [];
    for (const credential of publicKey.allowCredentials) {
      if (!record(credential) || credential.type !== "public-key" || typeof credential.id !== "string") return null;
      credentials.push({type: "public-key", id: decode(credential.id)});
    }
    return {id, publicKey: {challenge: decode(publicKey.challenge), rpId: publicKey.rpId,
      userVerification: "required", timeout: 60_000, allowCredentials: credentials}};
  } catch { return null; }
}

/** @param {ElevationHook} hook @param {string} event @param {object} payload @returns {Promise<unknown>} */
const reply = (hook, event, payload) => new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("Step-up request timed out")), 65_000);
  hook.pushEvent(event, payload, (response) => { clearTimeout(timeout); resolve(response); });
});

/**
 * @cc [owner:ghuntley,label:security;accessibility] admin-elevation-modal
 * The browser MUST carry only the server-issued nonce and WebAuthn assertion,
 * never administrative parameters. Cancellation, navigation or disconnect MUST
 * invalidate pending browser replies and abort the active ceremony. The dialog
 * MUST contain keyboard focus and restore focus on dismissal.
 */
export const AdminElevation = {
  /** @this {ElevationHook} @returns {void} */
  mounted() {
    const dialog = this.el.querySelector("#admin-elevation-modal");
    const verifyButton = this.el.querySelector("#admin-elevation-verify");
    const status = this.el.querySelector("#admin-elevation-status");
    if (!(dialog instanceof HTMLDialogElement) || !(verifyButton instanceof HTMLButtonElement) ||
        !(status instanceof HTMLElement)) return;
    /** @type {string | null} */
    let nonce = null;
    /** @type {HTMLElement | null} */
    let previousFocus = null;
    /** @type {AbortController | null} */
    let controller = null;
    let attempt = 0;
    let busy = false;
    let submitted = false;
    const cancelButtons = this.el.querySelectorAll("button[data-admin-elevation-cancel]");
    const resetButton = () => {
      busy = false;
      submitted = false;
      verifyButton.disabled = false;
      verifyButton.removeAttribute("aria-busy");
      cancelButtons.forEach(button => { if (button instanceof HTMLButtonElement) button.disabled = false; });
    };
    const close = () => {
      attempt += 1;
      nonce = null;
      controller?.abort();
      controller = null;
      resetButton();
      if (dialog.open) dialog.close();
      previousFocus?.focus();
      previousFocus = null;
    };
    /** @param {string} message */
    const showError = (message) => { resetButton(); status.textContent = message; verifyButton.focus(); };
    const cancel = () => {
      if (submitted) return;
      close();
      void reply(this, "admin-step-up-cancel", {}).catch(() => {});
    };
    this.handleEvent("admin-step-up-open", (payload) => {
      if (dialog.open || !record(payload) || typeof payload.nonce !== "string") return;
      nonce = payload.nonce;
      previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      const action = typeof payload.action === "string" ? payload.action : "complete this administrative change";
      status.textContent = `Verify with your passkey to ${action}. This runs once after verification.`;
      resetButton();
      dialog.showModal();
      verifyButton.focus();
    });
    this.handleEvent("admin-step-up-close", close);
    this.handleEvent("admin-step-up-error", (payload) => {
      if (dialog.open && record(payload) && typeof payload.message === "string") showError(payload.message);
    });
    const verify = async () => {
      if (busy || !dialog.open || nonce === null) return;
      busy = true;
      const currentAttempt = ++attempt;
      const intentNonce = nonce;
      const current = () => dialog.open && nonce === intentNonce && attempt === currentAttempt;
      verifyButton.disabled = true;
      verifyButton.setAttribute("aria-busy", "true");
      status.textContent = "Waiting for your passkey…";
      try {
        if (!window.PublicKeyCredential) throw new Error("Unavailable");
        const started = await reply(this, "admin-step-up-begin", {nonce: intentNonce});
        if (!current()) return;
        const challenge = verificationChallenge(started);
        if (!challenge) throw new Error("Invalid challenge");
        controller = new AbortController();
        const credential = await navigator.credentials.get({publicKey: challenge.publicKey, signal: controller.signal});
        if (!current()) return;
        if (!(credential instanceof PublicKeyCredential) || !(credential.response instanceof AuthenticatorAssertionResponse)) throw new Error("Invalid assertion");
        const payload = {id: challenge.id, raw_id: encode(credential.rawId),
          authenticator_data: encode(credential.response.authenticatorData), signature: encode(credential.response.signature),
          client_data_json: encode(credential.response.clientDataJSON)};
        submitted = true;
        status.textContent = "Applying administrative change…";
        cancelButtons.forEach(button => { if (button instanceof HTMLButtonElement) button.disabled = true; });
        const finished = await reply(this, "admin-step-up-finish", {nonce: intentNonce, payload});
        if (!current()) return;
        if (record(finished) && finished.ok === true) close();
        else showError("Verification could not be completed. Try again.");
      } catch (error) {
        if (current()) {
          const cancelled = error instanceof Error && ["NotAllowedError", "AbortError"].includes(error.name);
          showError(submitted ? "The result could not be confirmed. Reload the page and check the result before retrying." :
            cancelled ? "Passkey request cancelled. You can try again." : "Passkey verification failed or unavailable. Try again.");
        }
      } finally {
        if (current()) { controller = null; resetButton(); }
      }
    };
    /** @param {Event} event */
    const click = (event) => {
      if (event.target instanceof Element && event.target.closest("[data-admin-elevation-cancel]")) cancel();
      else if (event.target === dialog && event instanceof MouseEvent) {
        const bounds = dialog.getBoundingClientRect();
        if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) cancel();
      }
    };
    /** @param {Event} event */
    const escape = (event) => { event.preventDefault(); cancel(); };
    verifyButton.addEventListener("click", verify);
    dialog.addEventListener("click", click);
    dialog.addEventListener("cancel", escape);
    this.closeElevation = close;
    this.cleanup = () => {
      close();
      verifyButton.removeEventListener("click", verify);
      dialog.removeEventListener("click", click);
      dialog.removeEventListener("cancel", escape);
    };
  },
  /** @this {ElevationHook} @returns {void} */
  disconnected() { this.closeElevation?.(); },
  /** @this {ElevationHook} @returns {void} */
  reconnected() { void reply(this, "admin-step-up-cancel", {}).catch(() => {}); },
  /** @this {ElevationHook} @returns {void} */
  destroyed() { this.cleanup?.(); },
};
