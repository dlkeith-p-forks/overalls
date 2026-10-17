import test from "node:test";
import assert from "node:assert/strict";
import { deliverTicket } from "../../assets/js/terminals/tickets.js";
import {
  clipboardConsent,
  confirmedHttpUrl,
  decodeBase64Bytes,
  osc52Write,
  stripTrailingNewline,
  TerminalWorkspace,
  InputBatch,
  osc52Read,
  clipboardPayload,
  relativeActivity,
  BootLogPoller,
} from "../../assets/js/terminals.js";

test("LiveView recovery keeps attached sockets and retries tickets only for detached panes", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let requests = 0;
  let closures = 0;
  const pane = { connected: true, closed: false, wanted: true, closeSocket() { closures++; } };
  const workspace = {
    liveConnected: true,
    activeId: "session",
    panes: new Map([["session", pane]]),
    ticketTimers: new Map(),
    setStatus() {},
    push: TerminalWorkspace.push,
    pushEvent() { requests++; },
    requestTicket(id) { TerminalWorkspace.requestTicket.call(this, id); },
    retryOpening() {},
  };
  // A LiveView disconnect is not evidence the terminal ended (ADR-0140).
  TerminalWorkspace.disconnected.call(workspace);
  assert.equal(closures, 0);
  assert.equal(pane.connected, true);
  workspace.requestTicket("session");
  assert.equal(requests, 0);
  TerminalWorkspace.reconnected.call(workspace);
  assert.equal(requests, 0);

  // A pane that lost its own socket is re-ticketed until it attaches.
  pane.connected = false;
  TerminalWorkspace.disconnected.call(workspace);
  TerminalWorkspace.reconnected.call(workspace);
  assert.equal(requests, 1);
  t.mock.timers.tick(2500);
  assert.equal(requests, 2);
  pane.connected = true;
  t.mock.timers.tick(2500);
  assert.equal(requests, 2);
});

test("copy-on-select strips one trailing newline so paste does not auto-execute", () => {
  assert.equal(stripTrailingNewline("uptime\n"), "uptime");
  assert.equal(stripTrailingNewline("uptime\r\n"), "uptime");
  assert.equal(stripTrailingNewline("echo one\n\n"), "echo one\n");
  assert.equal(stripTrailingNewline("no newline"), "no newline");
  assert.equal(stripTrailingNewline(""), "");
});

test("OSC52 accepts the standard clipboard selector and decodes UTF-8", () => {
  const payload = Buffer.from("hello, 猫", "utf8").toString("base64");
  assert.deepEqual(osc52Write(`c;${payload}`), { bytes: 10, text: "hello, 猫" });
  assert.deepEqual(osc52Write(`;${payload}`), { bytes: 10, text: "hello, 猫" });
});

test("OSC52 denies reads, unsupported selectors, malformed data, and decoded payloads over 64 KiB", () => {
  assert.equal(osc52Write("c;?"), null);
  assert.equal(osc52Write("p;aGVsbG8="), null);
  assert.equal(osc52Write("c;%%%"), null);
  assert.equal(osc52Write(`c;${Buffer.from([255]).toString("base64")}`), null);
  assert.equal(osc52Write(`c;${Buffer.alloc(65537).toString("base64")}`), null);
  assert.equal(osc52Write(`c;${Buffer.alloc(65536).toString("base64")}`).bytes, 65536);
});

test("OSC52 consent exposes allow-once, session, and mute without treating other input as consent", () => {
  assert.equal(clipboardConsent("once"), "once");
  assert.equal(clipboardConsent(" SESSION "), "session");
  assert.equal(clipboardConsent("mute"), "mute");
  assert.equal(clipboardConsent("yes"), "deny");
  assert.equal(clipboardConsent(null), "deny");
});

test("OSC8 link activation accepts only absolute HTTP and HTTPS URLs", () => {
  assert.equal(confirmedHttpUrl("https://example.com/path"), "https://example.com/path");
  assert.equal(confirmedHttpUrl("HTTP://example.com"), "http://example.com/");
  assert.equal(confirmedHttpUrl("javascript:alert(1)"), null);
  assert.equal(confirmedHttpUrl("/relative"), null);
});

test("boot logs preserve terminal control and UTF-8 bytes", () => {
  const bytes = Buffer.from("\x1b[0;32mbooted 猫\x1b[0m\r\n", "utf8");
  assert.deepEqual(decodeBase64Bytes(bytes.toString("base64")), new Uint8Array(bytes));
});

test("boot-log cursor rewind resets xterm before the next correlated request", () => {
  const completions = [];
  const boot = { dataset: { next: "4096" }, classList: { contains: () => false } };
  const pane = { cursor: 4096, reset() { this.cursor = 0; } };
  const originalDocument = globalThis.document;
  globalThis.document = { getElementById: () => boot };
  try {
    TerminalWorkspace.renderBootLog.call({
      liveConnected: true,
      ensureBootPane: () => pane,
    }, "", 1024, (more) => completions.push(more));
  } finally {
    globalThis.document = originalDocument;
  }
  assert.equal(pane.cursor, 0);
  assert.equal(boot.dataset.next, "0");
  assert.deepEqual(completions, [true]);
});

test("boot-log chunks are written to xterm as bytes before requesting the next chunk", () => {
  const completions = [];
  const writes = [];
  const boot = { dataset: { next: "0" }, classList: { contains: () => false } };
  const pane = {
    cursor: 0,
    write(bytes, follow, finished) {
      writes.push({ bytes, follow });
      finished();
    },
  };
  const originalDocument = globalThis.document;
  globalThis.document = { getElementById: () => boot };
  const bytes = Buffer.from("\x1b[32mOK\x1b[0m", "binary");
  try {
    TerminalWorkspace.renderBootLog.call({
      liveConnected: true,
      el: { querySelector: () => ({ checked: true }) },
      ensureBootPane: () => pane,
    }, bytes.toString("base64"), bytes.length, (more) => completions.push(more));
  } finally {
    globalThis.document = originalDocument;
  }
  assert.deepEqual(writes, [{ bytes: new Uint8Array(bytes), follow: true }]);
  assert.deepEqual(completions, [true]);
});

test("boot-log EOF and refusal keep polling at a bounded rate without DOM updates", (t) => {
  t.mock.timers.enable({apis: ["setTimeout"]});
  const requests = [];
  const poller = new BootLogPoller(
    () => true,
    () => 0,
    (cursor, receive) => { requests.push({cursor, receive}); return true; },
    (_reply, finished) => finished(false),
  );
  poller.start();
  poller.start();
  assert.equal(requests.length, 1);
  requests[0].receive({ok: true, next: 0, text: ""});
  poller.start();
  t.mock.timers.tick(1999);
  assert.equal(requests.length, 1);
  t.mock.timers.tick(1);
  assert.equal(requests.length, 2);
  requests[1].receive({ok: false});
  t.mock.timers.tick(2000);
  assert.equal(requests.length, 3);
  poller.destroy();
  t.mock.timers.tick(20_000);
  assert.equal(requests.length, 3);
});

test("boot-log pause discards late replies and never overlaps an emulator write", (t) => {
  t.mock.timers.enable({apis: ["setTimeout"]});
  let active = true;
  const requests = [];
  const consumed = [];
  const writes = [];
  const poller = new BootLogPoller(
    () => active,
    () => 7,
    (cursor, receive) => { requests.push({cursor, receive}); return true; },
    (reply, finished) => { consumed.push(reply); writes.push(finished); },
  );
  poller.start();
  active = false;
  poller.pause(true);
  t.mock.timers.tick(20_000);
  assert.equal(requests.length, 1);
  active = true;
  poller.start();
  requests[0].receive("stale");
  assert.deepEqual(consumed, []);
  requests[1].receive("current");
  assert.deepEqual(consumed, ["current"]);
  poller.pause();
  poller.start();
  assert.equal(requests.length, 2);
  writes[0](true);
  t.mock.timers.tick(0);
  assert.equal(requests.length, 3);
  poller.destroy();
  requests[2].receive("destroyed");
  assert.deepEqual(consumed, ["current"]);
});

test("boot-log visibility toggles retain the outstanding request fence until its cancelled reply", (t) => {
  t.mock.timers.enable({apis: ["setTimeout"]});
  let active = true;
  const requests = [];
  const poller = new BootLogPoller(
    () => active,
    () => 0,
    (_cursor, receive) => { requests.push(receive); return true; },
    () => assert.fail("cancelled hidden reply reached the emulator"),
  );
  poller.start();
  for (let count = 0; count < 10; count++) {
    active = false;
    poller.pause();
    active = true;
    poller.start();
  }
  assert.equal(requests.length, 1);
  requests[0]({ok: true, next: 7, text: "cHJpdmF0ZQ=="});
  t.mock.timers.tick(1999);
  assert.equal(requests.length, 1);
  t.mock.timers.tick(1);
  assert.equal(requests.length, 2);
  poller.destroy();
});

test("malformed boot-log chunks cannot move the cursor or write bytes", () => {
  const originalDocument = globalThis.document;
  const boot = {dataset: {next: "0"}};
  const pane = {cursor: 0, write() { assert.fail("invalid bytes reached xterm"); }};
  globalThis.document = {getElementById: () => boot};
  try {
    for (const [text, next] of [["%%%", 3], ["YQ==", 2], ["", 1], [Buffer.alloc(16_385).toString("base64"), 16_385]]) {
      let more = null;
      TerminalWorkspace.renderBootLog.call({ensureBootPane: () => pane}, text, next, (value) => { more = value; });
      assert.equal(more, false);
      assert.equal(pane.cursor, 0);
      assert.equal(boot.dataset.next, "0");
    }
  } finally {
    globalThis.document = originalDocument;
  }
});

test("fullscreen state updates its accessible control and refits the visible terminal", () => {
  const attributes = new Map();
  const display = {};
  const button = {
    setAttribute(name, value) { attributes.set(name, value); },
    title: "",
  };
  let fits = 0;
  const originalDocument = globalThis.document;
  globalThis.document = { fullscreenElement: display };
  try {
    TerminalWorkspace.syncFullscreen.call({
      activeId: "active",
      bootPane: { fitToView() { fits += 1; } },
      el: { querySelector: (selector) => selector === "#terminal-display" ? display : button },
      panes: new Map([["active", { fitToView() { fits += 1; } }]]),
    });
  } finally {
    globalThis.document = originalDocument;
  }
  assert.equal(attributes.get("aria-label"), "Exit full screen");
  assert.equal(attributes.get("aria-pressed"), "true");
  assert.equal(button.title, "Exit full screen");
  assert.equal(fits, 2);
});

test("fullscreen control enters and exits only its terminal display", () => {
  let requested = 0;
  let exited = 0;
  const display = { requestFullscreen() { requested += 1; return Promise.resolve(); } };
  const originalDocument = globalThis.document;
  globalThis.document = {
    fullscreenElement: null,
    exitFullscreen() { exited += 1; return Promise.resolve(); },
  };
  try {
    const workspace = { el: { querySelector: () => display } };
    TerminalWorkspace.toggleFullscreen.call(workspace);
    globalThis.document.fullscreenElement = display;
    TerminalWorkspace.toggleFullscreen.call(workspace);
  } finally {
    globalThis.document = originalDocument;
  }
  assert.equal(requested, 1);
  assert.equal(exited, 1);
});

test("clipboard queries are exact and read responses are bounded UTF-8", () => {
  assert.equal(osc52Read("c;?"), "c");
  assert.equal(osc52Read(";?"), "");
  assert.equal(osc52Read("p;?"), null);
  assert.equal(osc52Read("c;?extra"), null);
  assert.equal(clipboardPayload("猫"), Buffer.from("猫").toString("base64"));
  assert.equal(clipboardPayload("x".repeat(65537)), null);
});

test("activity age handles future clocks and minute/hour/day transitions", () => {
  assert.equal(relativeActivity(1001, 1000), "just now");
  assert.equal(relativeActivity(0, 60000), "1m ago");
  assert.equal(relativeActivity(0, 3600000), "1h ago");
  assert.equal(relativeActivity(0, 86400000), "1d ago");
});

test("input batching preserves binary bytes and bounds network frames", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  /** @type {Uint8Array[]} */
  const sent = [];
  const batch = new InputBatch({ readyState: 1, send(bytes) { sent.push(bytes); } });
  const bytes = Uint8Array.from({ length: 40000 }, (_, index) => index % 256);
  batch.write(bytes.subarray(0, 1));
  batch.write(bytes.subarray(1));
  t.mock.timers.tick(16);
  assert.equal(sent.length, 3);
  assert(sent.every((frame) => frame.length <= 16384));
  assert.deepEqual(Buffer.concat(sent), Buffer.from(bytes));
});

test("disconnect discards buffered input instead of replaying it on a replacement", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  /** @type {Uint8Array[]} */
  const sent = [];
  const socket = { readyState: 1, send(bytes) { sent.push(bytes); } };
  const old = new InputBatch(socket);
  old.write(new Uint8Array([1, 255]));
  old.close();
  const replacement = new InputBatch(socket);
  replacement.write(new Uint8Array([2]));
  t.mock.timers.tick(16);
  assert.deepEqual(sent, [new Uint8Array([2])]);
});

test("input waits for cumulative credit and duplicate receipts cannot inflate its window", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  /** @type {Uint8Array[]} */
  const sent = [];
  const batch = new InputBatch({ readyState: 1, send(bytes) { sent.push(bytes); } });
  assert.equal(batch.write(new Uint8Array(262144)), true);
  assert.equal(sent.length, 16);
  assert.equal(batch.write(new Uint8Array([42])), true);
  t.mock.timers.tick(16);
  assert.equal(sent.length, 16);
  assert.equal(batch.acknowledge(1, 16384), true);
  assert.equal(sent.length, 17);
  assert.deepEqual(sent[16], new Uint8Array([42]));
  assert.equal(batch.acknowledge(1, 16384), true);
  assert.equal(batch.window.frames, 0);
  assert.equal(batch.acknowledge(18, 999999), false);
});

test("lost create replies and LiveView reconnect retain the original request identity and parameters", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  /** @type {{request_id: string, user: string}[]} */
  const requests = [];
  const opening = { request_id: "d3035ea4-5b36-44bd-934d-9cabca39ff89", user: "guest" };
  const workspace = {
    liveConnected: true,
    opening,
    openingTimer: 0,
    panes: new Map(),
    ticketTimers: new Map(),
    setStatus() {},
    push: TerminalWorkspace.push,
    pushEvent(_event, request) { requests.push({ ...request }); },
    retryOpening() { TerminalWorkspace.retryOpening.call(this); },
  };
  workspace.retryOpening();
  t.mock.timers.tick(7500);
  assert.deepEqual(requests, [opening, opening]);
  TerminalWorkspace.disconnected.call(workspace);
  t.mock.timers.tick(15000);
  assert.equal(requests.length, 2);
  TerminalWorkspace.reconnected.call(workspace);
  assert.deepEqual(requests, [opening, opening, opening]);
});

for (const listedBeforeReply of [true, false]) {
  test(`create selects once when the listing arrives ${listedBeforeReply ? "before" : "after"} its reply`, (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    /** @typedef {{id: string, last_ms: number}} Session */
    /** @type {Session[]} */
    const sessions = [{ id: "old", last_ms: 0 }, { id: "new", last_ms: 0 }];
    /** @type {string[]} */
    const selections = [];
    /** @type {Map<string, {mode: string, session: Session}>} */
    const panes = new Map(
      sessions.filter((session) => listedBeforeReply || session.id === "old")
        .map((session) => [session.id, { mode: "rw", session }])
    );
    const workspace = {
      liveConnected: true,
      opening: { request_id: "create" },
      openingTimer: 0,
      activeId: "old",
      /** @type {string | null} */
      selectAfterRefresh: null,
      panes,
      el: {
        /** @param {string} selector */
        querySelector: (selector) => selector === "#terminal-sidebar-list" ? {} : null,
      },
      /** @param {Session} session */
      ensurePane(session) {
        if (!this.panes.has(session.id)) this.panes.set(session.id, { mode: "rw", session });
      },
      /** @param {string} id */
      select(id) { this.activeId = id; selections.push(id); },
      setStatus() {},
      /**
       * @param {string} _event
       * @param {{request_id: string}} request
       * @param {(reply: {request_id: string, status: string, session_id: string}) => void} reply
       */
      push: TerminalWorkspace.push,
      pushEvent(_event, request, reply) {
        reply({ request_id: request.request_id, status: "ready", session_id: "new" });
      },
      retryOpening() { TerminalWorkspace.retryOpening.call(this); },
    };
    workspace.retryOpening();
    if (!listedBeforeReply) TerminalWorkspace.renderSessions.call(workspace, sessions);
    assert.equal(workspace.activeId, "new");

    workspace.select("old");
    TerminalWorkspace.renderSessions.call(workspace, sessions);
    TerminalWorkspace.renderSessions.call(workspace, sessions);
    assert.equal(workspace.activeId, "old");
    assert.deepEqual(selections, ["new", "old"]);
  });
}

/** @type {Array<[string | null, boolean]>} */
const ticketDeliveryCases = [["requested", true], ["other", true], [null, true], ["requested", false]];
for (const [activeAtDelivery, connected] of ticketDeliveryCases) {
  test(`ticket delivery respects current selection and connection (${activeAtDelivery}, ${connected})`, () => {
    /** @type {Map<string, (reply: unknown) => void>} */
    const events = new Map();
    /** @type {string[]} */
    const attachments = [];
    const originalDocument = globalThis.document;
    const originalResizeObserver = globalThis.ResizeObserver;
    const originalMutationObserver = globalThis.MutationObserver;
    class Observer {
      /** @param {() => void} _callback */
      constructor(_callback) {}
      /** @param {object} _element @param {object} [_options] */
      observe(_element, _options) {}
    }
    globalThis.document = {
      title: "Fixture",
      documentElement: {},
      getElementById() { return {}; },
      addEventListener() {},
    };
    globalThis.ResizeObserver = Observer;
    globalThis.MutationObserver = Observer;
    const workspace = {
      el: {
        dataset: { vmId: "vm" },
        querySelector() { return null; },
        addEventListener() {},
      },
      /** @param {string} name @param {(reply: unknown) => void} callback */
      handleEvent(name, callback) { events.set(name, callback); },
      renderSessions() {},
    };
    try {
      TerminalWorkspace.mounted.call(workspace);
      workspace.panes.set("requested", {
        /** @param {string} ticket */
        attach(ticket) { attachments.push(ticket); },
      });
      workspace.activeId = activeAtDelivery;
      workspace.liveConnected = connected;
      workspace.ticketTimers.set("requested", 42);
      const deliver = events.get("terminal_ticket");
      assert(deliver);
      deliver({ session_id: "requested", ticket: "synthetic-single-use-ticket" });
      assert.deepEqual(attachments, activeAtDelivery === "requested" && connected ? ["synthetic-single-use-ticket"] : []);
      assert.equal(workspace.ticketTimers.has("requested"), false);
    } finally {
      globalThis.document = originalDocument;
      globalThis.ResizeObserver = originalResizeObserver;
      globalThis.MutationObserver = originalMutationObserver;
    }
  });
}

test("malformed ticket replies preserve pending requests and cannot attach a pane", () => {
  /** @type {unknown[]} */
  const malformed = [null, false, 1, "ticket", [], {}, {session_id: "requested"},
    {session_id: null, ticket: "fixture"}, {session_id: "requested", ticket: 42}];
  for (const reply of malformed) {
    let attachments = 0;
    const workspace = {
      activeId: "requested",
      liveConnected: true,
      ticketTimers: new Map([["requested", 42]]),
      panes: new Map([["requested", {attach() { attachments++; }}]]),
    };
    deliverTicket(workspace, reply);
    assert.equal(attachments, 0);
    assert.equal(workspace.ticketTimers.get("requested"), 42);
  }
});

test("pushes are dropped, never thrown, while LiveView is not connected", () => {
  let pushed = 0;
  const workspace = { liveConnected: false, pushEvent() { pushed++; } };
  assert.equal(TerminalWorkspace.push.call(workspace, "terminal_ticket", {}), false);
  assert.equal(pushed, 0);
  workspace.liveConnected = true;
  assert.equal(TerminalWorkspace.push.call(workspace, "terminal_ticket", {}), true);
  assert.equal(pushed, 1);
  workspace.pushEvent = () => { throw new Error("unable to push hook event. LiveView not connected"); };
  assert.equal(TerminalWorkspace.push.call(workspace, "terminal_ticket", {}), false);
  assert.equal(workspace.liveConnected, false);
});

test("a hidden boot view finishes its current byte write without directly pulling another chunk", () => {
  const requests = [];
  const boot = { dataset: { next: "0" }, classList: { contains: (name) => name === "hidden" } };
  const pane = { cursor: 0, write(_bytes, _follow, finished) { finished(); } };
  const originalDocument = globalThis.document;
  globalThis.document = { getElementById: () => boot };
  const bytes = Buffer.from("booting", "binary");
  try {
    TerminalWorkspace.renderBootLog.call({
      liveConnected: true,
      el: { querySelector: () => ({ checked: true }) },
      ensureBootPane: () => pane,
      push: TerminalWorkspace.push,
      pushEvent(event, payload) { requests.push({ event, payload }); },
    }, bytes.toString("base64"), bytes.length, () => {});
  } finally {
    globalThis.document = originalDocument;
  }
  assert.deepEqual(requests, []);
});

test("only the selected and most recently selected panes keep live emulators", () => {
  const hibernated = [];
  const panes = new Map();
  for (const id of ["a", "b", "c", "d", "e", "f"]) {
    panes.set(id, { hibernate() { hibernated.push(id); return true; } });
  }
  const workspace = { panes, activeId: "f", recent: ["f", "e", "d", "c", "b", "a"] };
  TerminalWorkspace.hibernateIdle.call(workspace);
  assert.deepEqual(hibernated.sort(), ["a", "b"]);

  hibernated.length = 0;
  TerminalWorkspace.hibernateIdle.call({ panes, activeId: null, recent: [] });
  assert.deepEqual(hibernated.sort(), ["a", "b", "c", "d", "e", "f"]);
});

test("a selected pane deferred by draining writes keeps retrying until it can attach", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let pushes = 0;
  const pane = { connected: false, closed: false, pendingWrites: 3, socket: null };
  const workspace = {
    liveConnected: true,
    activeId: "session",
    panes: new Map([["session", pane]]),
    ticketTimers: new Map(),
    push: TerminalWorkspace.push,
    pushEvent() { pushes++; },
    requestTicket(id) { TerminalWorkspace.requestTicket.call(this, id); },
  };

  // Deferred, not dropped: a retry is pending even though nothing was pushed.
  workspace.requestTicket("session");
  assert.equal(pushes, 0);
  assert.equal(workspace.ticketTimers.has("session"), true);
  t.mock.timers.tick(500);
  assert.equal(pushes, 0);

  // Once the writes drain, the pending retry requests a ticket by itself.
  pane.pendingWrites = 0;
  t.mock.timers.tick(500);
  assert.equal(pushes, 1);
});
