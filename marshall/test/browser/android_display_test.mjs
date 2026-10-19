import test from "node:test";
import assert from "node:assert/strict";
import {createAndroidDisplay} from "../../assets/js/android_display_hook.js";

class FakeRFB {
  static instances = [];
  constructor(target, url, options) {
    this.target = target;
    this.url = url;
    this.options = options;
    this.listeners = new Map();
    FakeRFB.instances.push(this);
  }
  addEventListener(name, listener) { this.listeners.set(name, listener); }
  disconnect() { this.disconnected = true; }
}

test("Android display gives noVNC an empty target and replaces its canvas on reconnect", () => {
  const children = [{nodeName: "CANVAS"}];
  const target = {replaceChildren() { children.length = 0; }};
  const status = {setAttribute(name, value) { this[name] = value; }};
  const hook = createAndroidDisplay(FakeRFB);
  const el = {
    dataset: {displayWebsocketUrl: "/android-display", machineId: "machine-1"},
    querySelector(selector) {
      return selector === "[data-display-target]" ? target : status;
    },
  };
  const context = {el, handleEvent() {}, rfbTarget: target, status};
  hook.mounted.call(context);
  globalThis.window = {location: {origin: "https://example.test"}};
  hook.connect.call(context, "ticket-1", "viewer", 3, "machine-1");
  assert.equal(children.length, 0);
  assert.equal(FakeRFB.instances[0].target, target);
  assert.equal(FakeRFB.instances[0].viewOnly, true);
  hook.connect.call(context, "ticket-2", "controller", 4, "machine-1");
  assert.equal(FakeRFB.instances[0].disconnected, true);
  assert.equal(FakeRFB.instances[1].viewOnly, false);
  assert.match(FakeRFB.instances[1].url, /generation=4/);
});
