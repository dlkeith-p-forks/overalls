// @ts-check
import test from "node:test";
import assert from "node:assert/strict";
import {initBrowserExtensionPresence} from "../../assets/js/browser_extension_presence.js";

class Target {
  hidden = false;
}

class DocumentFixture {
  /** @type {{getAttribute: (name: string) => string | null}} */
  documentElement;
  /** @type {Target[]} */
  targets;

  /** @param {string | null} marker */
  constructor(marker) {
    let value = marker;
    this.documentElement = {getAttribute: () => value};
    this.targets = [new Target()];
    this.setMarker = (next) => { value = next; };
  }

  /** @param {string} _selector @returns {Target[]} */
  querySelectorAll(_selector) {
    return this.targets;
  }

  /** @param {string | null} marker @returns {void} */
  setMarker;
}

/** @type {(() => void) | null} */
let notify = null;
class MutationObserverFixture {
  /** @param {() => void} callback */
  constructor(callback) {
    notify = callback;
  }

  /** @returns {void} */
  observe() {}
}

Object.assign(globalThis, {HTMLElement: Target, MutationObserver: MutationObserverFixture});

/**
 * @cc [owner:ghuntley,label:verification;security] browser-extension-presence-evidence
 * The presentation marker MUST hide setup targets only for the exact installed
 * value and MUST restore them when the marker is absent.
 */
test("presence marker controls setup visibility and follows marker changes", () => {
  const doc = new DocumentFixture(null);
  initBrowserExtensionPresence(doc);
  assert.equal(doc.targets[0].hidden, false);

  doc.setMarker("installed");
  assert.ok(notify);
  notify();
  assert.equal(doc.targets[0].hidden, true);

  doc.setMarker("other");
  notify();
  assert.equal(doc.targets[0].hidden, false);
});
