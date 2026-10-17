// @ts-check
import test from "node:test";
import assert from "node:assert/strict";
import { AdminElevation, verificationChallenge } from "../../assets/js/admin_elevation.js";

/** @returns {object} */
function challenge() {
  return {ok: true, challenge: {id: "11111111-1111-4111-8111-111111111111", publicKey: {
    challenge: "YWJj", rpId: "localhost", userVerification: "required",
    allowCredentials: [{type: "public-key", id: "a2V5"}],
  }}};
}

class ElementFixture extends EventTarget {
  disabled = false;
  textContent = "";
  /** @type {Map<string, string>} */ attributes = new Map();
  /** @type {Map<string, ElementFixture>} */ children = new Map();
  /** @returns {void} */ focus() { globalThis.document.activeElement = this; }
  /** @param {string} name @param {string} value @returns {void} */
  setAttribute(name, value) { this.attributes.set(name, value); }
  /** @param {string} name @returns {void} */ removeAttribute(name) { this.attributes.delete(name); }
  /** @param {string} selector @returns {ElementFixture | null} */
  querySelector(selector) { return this.children.get(selector) || null; }
  /** @param {string} _selector @returns {ElementFixture[]} */ querySelectorAll(_selector) { return []; }
  /** @param {string} _selector @returns {null} */ closest(_selector) { return null; }
}
class DialogFixture extends ElementFixture {
  open = false;
  /** @returns {void} */ showModal() { this.open = true; }
  /** @returns {void} */ close() { this.open = false; }
}
class AssertionFixture {
  authenticatorData = new Uint8Array([1]).buffer;
  signature = new Uint8Array([2]).buffer;
  clientDataJSON = new Uint8Array([3]).buffer;
}
class CredentialFixture {
  rawId = new Uint8Array([4]).buffer;
  response = new AssertionFixture();
}

/** @returns {Promise<void>} */
const flush = () => new Promise(resolve => setImmediate(resolve));

/**
 * @cc [owner:ghuntley,label:verification;security] admin-browser-race-evidence
 * The fixture MUST exercise the real hook's async replies and cancellation.
 * It proves browser state/transport behavior, not native authenticator or DOM
 * focus containment; those require the real browser acceptance scenario.
 * @returns {{hook: object, events: Map<string, (payload: unknown) => void>, dialog: DialogFixture,
 * button: ElementFixture, requests: Array<{event: string, payload: object, callback: (response: unknown) => void}>,
 * credentialCalls: Array<{signal: AbortSignal}>, resolveCredential: () => void, opener: ElementFixture}}
 */
function fixture() {
  const root = new ElementFixture(), dialog = new DialogFixture(), button = new ElementFixture(), status = new ElementFixture();
  const opener = new ElementFixture();
  root.children.set("#admin-elevation-modal", dialog);
  root.children.set("#admin-elevation-verify", button);
  root.children.set("#admin-elevation-status", status);
  /** @type {Map<string, (payload: unknown) => void>} */ const events = new Map();
  /** @type {Array<{event: string, payload: object, callback: (response: unknown) => void}>} */ const requests = [];
  /** @type {Array<{signal: AbortSignal}>} */ const credentialCalls = [];
  /** @type {(() => void) | null} */ let resolveCredential = null;
  Object.assign(globalThis, {HTMLElement: ElementFixture, Element: ElementFixture,
    HTMLDialogElement: DialogFixture, HTMLButtonElement: ElementFixture,
    PublicKeyCredential: CredentialFixture, AuthenticatorAssertionResponse: AssertionFixture,
    window: {PublicKeyCredential: CredentialFixture}, document: {activeElement: opener}});
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {credentials: {
    /** @param {{signal: AbortSignal}} options @returns {Promise<CredentialFixture>} */
    get(options) { credentialCalls.push(options); return new Promise(resolve => { resolveCredential = () => resolve(new CredentialFixture()); }); },
  }}});
  const hook = {el: root,
    /** @param {string} name @param {(payload: unknown) => void} callback @returns {void} */
    handleEvent(name, callback) { events.set(name, callback); },
    /** @param {string} event @param {object} payload @param {(response: unknown) => void} callback @returns {void} */
    pushEvent(event, payload, callback) {
      requests.push({event, payload, callback});
      if (event === "admin-step-up-cancel") callback({ok: true});
    },
  };
  AdminElevation.mounted.call(hook);
  return {hook, events, dialog, button, requests, credentialCalls, opener,
    resolveCredential() { assert.ok(resolveCredential); resolveCredential(); }};
}

test("challenge boundary rejects malformed and optional-user-verification replies", () => {
  assert.ok(verificationChallenge(challenge()));
  for (const malformed of [null, {}, {ok: false}, {ok: true, challenge: {id: "bad", publicKey: {}}},
    {ok: true, challenge: {id: "11111111-1111-4111-8111-111111111111", publicKey: {
      challenge: "YWJj", rpId: "localhost", userVerification: "preferred", allowCredentials: []}}}]) {
    assert.equal(verificationChallenge(malformed), null);
  }
});

test("verification keeps intent nonce distinct from challenge ID and sends no action parameters", async () => {
  const f = fixture();
  try {
    f.events.get("admin-step-up-open")({nonce: "server-intent"});
    f.button.dispatchEvent(new Event("click"));
    f.button.dispatchEvent(new Event("click"));
    assert.equal(f.requests.length, 1);
    assert.deepEqual(f.requests[0].payload, {nonce: "server-intent"});
    f.requests[0].callback(challenge());
    await flush();
    f.resolveCredential();
    await flush();
    assert.equal(f.requests[1].event, "admin-step-up-finish");
    assert.deepEqual(Object.keys(f.requests[1].payload).sort(), ["nonce", "payload"]);
    assert.equal(f.requests[1].payload.nonce, "server-intent");
    assert.equal(f.requests[1].payload.payload.id, "11111111-1111-4111-8111-111111111111");
    // Once submitted, Escape cannot suggest the in-flight server action was cancelled.
    f.dialog.dispatchEvent(new Event("cancel", {cancelable: true}));
    assert.equal(f.dialog.open, true);
    assert.equal(f.requests.length, 2);
    f.requests[1].callback({ok: true, completed: true});
    await flush();
    assert.equal(f.dialog.open, false);
    assert.equal(globalThis.document.activeElement, f.opener);
    assert.equal(f.button.attributes.has("aria-busy"), false);
  } finally { AdminElevation.destroyed.call(f.hook); }
});

test("cancel before begin reply prevents ceremony and stale reply cannot change a new attempt", async () => {
  const f = fixture();
  try {
    f.events.get("admin-step-up-open")({nonce: "old"});
    f.button.dispatchEvent(new Event("click"));
    f.dialog.dispatchEvent(new Event("cancel", {cancelable: true}));
    f.events.get("admin-step-up-open")({nonce: "new"});
    f.button.dispatchEvent(new Event("click"));
    f.requests[0].callback(challenge());
    await flush();
    assert.equal(f.credentialCalls.length, 0);
    assert.equal(f.button.disabled, true);
    f.requests[2].callback(challenge());
    await flush();
    assert.equal(f.credentialCalls.length, 1);
    f.resolveCredential();
    await flush();
    assert.equal(f.requests.at(-1).payload.nonce, "new");
    f.requests.at(-1).callback({ok: true});
    await flush();
  } finally { AdminElevation.destroyed.call(f.hook); }
});

test("disconnect aborts ceremony and late authenticator result cannot finish action", async () => {
  const f = fixture();
  try {
    f.events.get("admin-step-up-open")({nonce: "server-intent"});
    f.button.dispatchEvent(new Event("click"));
    f.requests[0].callback(challenge());
    await flush();
    AdminElevation.disconnected.call(f.hook);
    assert.equal(f.credentialCalls[0].signal.aborted, true);
    f.resolveCredential();
    await flush();
    assert.equal(f.requests.some(request => request.event === "admin-step-up-finish"), false);
    AdminElevation.reconnected.call(f.hook);
    assert.equal(f.requests.at(-1).event, "admin-step-up-cancel");
  } finally { AdminElevation.destroyed.call(f.hook); }
});
