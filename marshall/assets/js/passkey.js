/**
 * @cc [owner:ghuntley,label:security] passkey-server-ceremony
 * The hook transports browser WebAuthn results only. The server decides identity,
 * single use and expiry. Cancellation never submits or retries a mutation.
 */
const decode = (value) => Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
const encode = (value) => btoa(String.fromCharCode(...new Uint8Array(value))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export const PasskeyCeremony = {
  mounted() {
    this.busy = false;
    this.controller = null;
    this.click = async (event) => {
      const button = event.target.closest("button[data-kind]");
      if (!button || this.busy) return;
      this.busy = true;
      const buttons = this.el.querySelectorAll("button");
      buttons.forEach(b => b.disabled = true);
      const kind = button.dataset.kind;
      try {
        if (!window.PublicKeyCredential) throw new Error("Unavailable");
        const response = await new Promise(resolve => this.pushEvent("begin", {kind}, resolve));
        if (!response.ok) return;
        const {id, publicKey} = response.challenge;
        publicKey.challenge = decode(publicKey.challenge);
        for (const field of ["allowCredentials", "excludeCredentials"]) {
          if (publicKey[field]) publicKey[field] = publicKey[field].map(c => ({...c, id: decode(c.id)}));
        }
        if (publicKey.user) publicKey.user.id = decode(publicKey.user.id);
        this.controller = new AbortController();
        const credential = await navigator.credentials[kind === "register" ? "create" : "get"]({publicKey, signal: this.controller.signal});
        const payload = {id, client_data_json: encode(credential.response.clientDataJSON)};
        if (kind === "register") {
          payload.attestation_object = encode(credential.response.attestationObject);
          payload.label = "Passkey";
        } else {
          payload.raw_id = encode(credential.rawId);
          payload.authenticator_data = encode(credential.response.authenticatorData);
          payload.signature = encode(credential.response.signature);
        }
        this.pushEvent("finish", {kind, payload});
      } catch (_) {
        this.pushEvent("cancelled", {});
      } finally {
        this.busy = false;
        buttons.forEach(b => b.disabled = false);
      }
    };
    this.el.addEventListener("click", this.click);
  },
  destroyed() {
    this.controller?.abort();
    this.el.removeEventListener("click", this.click);
  }
};
