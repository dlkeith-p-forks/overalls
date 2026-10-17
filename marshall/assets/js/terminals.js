import {readPalette} from "./palette.js";
import { Terminal } from "../vendor/xterm/xterm.mjs";
import { FitAddon } from "../vendor/xterm/addons/addon-fit.mjs";
import { Unicode11Addon } from "../vendor/xterm/addons/addon-unicode11.mjs";
import { SearchAddon } from "../vendor/xterm/addons/addon-search.mjs";
import { ImageAddon } from "../vendor/xterm/addons/addon-image.mjs";
import { CreditWindow } from "./terminals/window.js";
import { deliverTicket } from "./terminals/tickets.js";

const MAX_OSC52_BYTES = 64 * 1024;
// Live emulators a workspace keeps; less recently selected panes hibernate.
const LIVE_PANES = 4;

/** @typedef {{request_id: string}} OpeningRequest */

export function pref(key, fallback) {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? fallback : value === "1";
  } catch {
    return fallback;
  }
}

function setPref(key, value) {
  try {
    window.localStorage.setItem(key, value ? "1" : "0");
  } catch {
    /* storage unavailable */
  }
}

async function writeClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      /* fall through */
    }
  }
  const helper = document.createElement("textarea");
  helper.value = text;
  helper.style.position = "fixed";
  helper.style.opacity = "0";
  document.body.appendChild(helper);
  helper.select();
  const ok = document.execCommand("copy");
  helper.remove();
  return ok;
}

export function stripTrailingNewline(text) {
  return text.replace(/\r?\n$/, "");
}

export function osc52Write(data) {
  const separator = data.indexOf(";");
  if (separator === -1) return null;

  const selector = data.slice(0, separator);
  const payload = data.slice(separator + 1);
  if ((selector !== "" && selector !== "c") || payload === "?") return null;
  if (payload.length > Math.ceil(MAX_OSC52_BYTES / 3) * 4) return null;

  try {
    const binary = atob(payload);
    if (binary.length > MAX_OSC52_BYTES) return null;
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return { bytes: bytes.length, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  } catch {
    return null;
  }
}

/** @param {string} data @returns {string | null} */
export function osc52Read(data) {
  return data === "c;?" ? "c" : data === ";?" ? "" : null;
}

/** @param {string} text @returns {string | null} */
/**
 * The label shown for a session: the browser-local name the user chose,
 * otherwise the server's generated name, otherwise the guest user.
 * @param {{display_name?: string, guest_user: string}} session
 * @param {{localName?: string} | undefined} pane
 * @returns {string}
 */
export function displayName(session, pane) {
  return pane?.localName || session.display_name || session.guest_user;
}

export function clipboardPayload(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length > MAX_OSC52_BYTES) return null;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(binary);
}

export function confirmedHttpUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

export function decodeBase64Bytes(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function clipboardConsent(choice) {
  const normalized = choice && choice.trim().toLowerCase();
  return ["once", "session", "mute"].includes(normalized) ? normalized : "deny";
}

/** @param {number} milliseconds @param {number} now @returns {string} */
export function relativeActivity(milliseconds, now = Date.now()) {
  const seconds = Math.max(0, Math.floor((now - milliseconds) / 1000));
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

function openConfirmedLink(event, uri) {
  event.preventDefault();
  const url = confirmedHttpUrl(uri);
  if (url && window.confirm(`Open this link?\n\n${url}`)) {
    window.open(url, "_blank", "noopener,noreferrer");
  }
}

/**
 * @cc [owner:ghuntley,label:protocol;recovery] terminal-input-batches-never-replay
 * Input batches MUST preserve byte order, hold at most 16 KiB and schedule a
 * flush after 16 ms on their original socket. Closing a batch MUST discard unsent input;
 * it MUST NOT transfer input to a replacement connection.
 */
export class InputBatch {
  /** @param {{readyState: number, send: (bytes: Uint8Array) => void}} socket */
  constructor(socket) {
    this.socket = socket;
    /** @type {Uint8Array[]} */
    this.chunks = [];
    this.size = 0;
    this.timer = 0;
    this.closed = false;
    this.window = new CreditWindow();
  }

  /** @param {Uint8Array} bytes */
  write(bytes) {
    if (this.closed || this.socket.readyState !== 1) return false;
    const sendable = Math.min(this.window.bytes, this.window.frames * 16384);
    if (this.size + bytes.length > sendable + 16384) return false;
    for (let offset = 0; offset < bytes.length;) {
      const count = Math.min(16384 - this.size, bytes.length - offset);
      this.chunks.push(bytes.slice(offset, offset + count));
      this.size += count;
      offset += count;
      if (this.size === 16384) this.flush();
    }
    if (this.size && !this.timer) this.timer = setTimeout(() => this.flush(), 16);
    return true;
  }

  flush() {
    clearTimeout(this.timer);
    this.timer = 0;
    while (!this.closed && this.socket.readyState === 1 && this.size && this.window.frames && this.window.bytes) {
      const size = Math.min(this.size, this.window.bytes, 16384);
      const bytes = new Uint8Array(size);
      let offset = 0;
      while (offset < size) {
        const chunk = this.chunks[0];
        const count = Math.min(chunk.length, size - offset);
        bytes.set(chunk.subarray(0, count), offset);
        offset += count;
        if (count === chunk.length) this.chunks.shift();
        else this.chunks[0] = chunk.subarray(count);
      }
      this.size -= size;
      if (!this.window.take(size)) { this.close(); return; }
      this.socket.send(bytes);
    }
  }

  /** @param {number} frames @param {number} bytes @returns {boolean} */
  acknowledge(frames, bytes) {
    if (!this.window.acknowledge(frames, bytes)) return false;
    this.flush();
    return true;
  }

  close() {
    this.closed = true;
    clearTimeout(this.timer);
    this.timer = 0;
    this.chunks = [];
    this.size = 0;
  }
}

class BootLogPane {
  constructor(workspace, container) {
    this.container = container;
    this.cursor = 0;
    this.terminal = new Terminal({
      allowProposedApi: true,
      convertEol: false,
      cursorBlink: false,
      disableStdin: true,
      fontFamily: '"JetBrains Mono", ui-monospace, monospace',
      fontWeight: "500",
      fontWeightBold: "800",
      fontSize: 13,
      linkHandler: {
        activate: (event, uri) => openConfirmedLink(event, uri),
      },
      screenReaderMode: true,
      scrollback: 10000,
      theme: workspace.theme(),
    });
    this.fit = new FitAddon();
    this.terminal.loadAddon(this.fit);
    this.terminal.loadAddon(new Unicode11Addon());
    this.terminal.unicode.activeVersion = "11";
    // Boot output is an untrusted, read-only diagnostic. Consume clipboard
    // sequences without granting them a browser capability.
    this.terminal.parser.registerOscHandler(52, () => true);
    this.terminal.open(container);
    this.fitToView();
  }

  fitToView() {
    if (!this.container.closest("#terminal-boot-view")?.classList.contains("hidden")) this.fit.fit();
  }

  reset() {
    this.cursor = 0;
    this.terminal.reset();
  }

  /** @param {Uint8Array} bytes @param {boolean} follow @param {() => void} finished */
  write(bytes, follow, finished) {
    this.terminal.write(bytes, () => {
      if (follow) this.terminal.scrollToBottom();
      finished();
    });
  }

  dispose() {
    this.terminal.dispose();
  }
}

class Pane {
  constructor(workspace, session, container) {
    this.workspace = workspace;
    this.session = session;
    this.socket = null;
    this.cursor = 0;
    this.pendingWrites = 0;
    this.replayRemaining = 0;
    this.replayToParse = 0;
    this.replaying = false;
    this.connected = false;
    this.mode = "ro";
    this.wanted = false;
    this.status = "connecting";
    this.reconnectDelay = 500;
    this.closed = false;

    this.terminal = null;
    this.fontSize = 13;
    this.container = container;
    this.releaseSelection = () => queueMicrotask(() => { if (!this.closed) this.copySelection(); });
    container.addEventListener("pointerup", this.releaseSelection);
    container.addEventListener("keyup", this.releaseSelection);
    // The emulator is built when the pane is first selected or attached.
  }

  /**
   * @cc [owner:ghuntley,label:capacity;recovery] browser-bounded-live-emulators
   * A workspace MUST keep at most LIVE_PANES emulators, always including the
   * selected pane. Only a pane without a socket or pending writes may
   * hibernate; hibernation disposes its emulator and restarts its replay
   * cursor at zero, so waking replays the retained window from the stream.
   */
  wake() {
    if (this.terminal || this.closed) return;
    this.terminal = new Terminal({
      convertEol: false,
      cursorBlink: true,
      screenReaderMode: true,
      fontFamily: '"JetBrains Mono", ui-monospace, monospace',
      fontWeight: "500",
      fontWeightBold: "800",
      fontSize: this.fontSize,
      allowProposedApi: true,
      linkHandler: {
        activate: (event, uri) => this.openLink(event, uri),
      },
      scrollback: 5000,
      theme: this.workspace.theme(),
    });

    this.fit = new FitAddon();
    this.terminal.loadAddon(this.fit);
    this.terminal.loadAddon(new Unicode11Addon());
    this.search = new SearchAddon();
    this.terminal.loadAddon(this.search);
    this.terminal.loadAddon(new ImageAddon());
    this.terminal.unicode.activeVersion = "11";
    // The DOM renderer needs no GPU context: a page never exhausts the
    // browser's WebGL context limit, and no renderer canvas can paint above
    // the share or new-terminal dialogs.
    this.terminal.open(this.container);
    this.fit.fit();

    this.terminal.onData((data) => this.sendInput(data));
    this.terminal.onBinary((data) => this.sendBytes(Uint8Array.from(data, (character) => character.charCodeAt(0))));
    this.terminal.onResize(({ cols, rows }) => this.sendResize(cols, rows));
    this.terminal.onTitleChange((title) => this.workspace.updateTitle(this.session.id, title));
    this.installOscHandlers();
  }

  /** @returns {boolean} whether the emulator was released */
  hibernate() {
    if (!this.terminal || this.socket || this.pendingWrites > 0) return false;
    this.terminal.dispose();
    this.terminal = null;
    this.fit = null;
    this.search = null;
    this.container.replaceChildren();
    this.cursor = 0;
    this.replaying = false;
    this.replayRemaining = 0;
    this.replayToParse = 0;
    return true;
  }

  installOscHandlers() {
    const parser = this.terminal.parser;

    parser.registerOscHandler(52, (data) => this.handleOsc52(data));
  }

  handleOsc52(data) {
    if (this.replaying) return true;
    const read = osc52Read(data);
    if (read !== null) return this.readClipboard(read);
    const write = osc52Write(data);
    if (!write || this.workspace.clipboard.write === "mute") return true;

    let consent = this.workspace.clipboard.write;
    if (consent === "ask") {
      const choice = window.prompt(
        `This machine asks to write ${write.bytes} bytes to your clipboard. Type once, session, or mute.`,
        "once"
      );
      consent = clipboardConsent(choice);
      if (consent === "session") this.workspace.clipboard.write = "session";
      if (consent === "mute") this.workspace.clipboard.write = "mute";
    }
    if (consent === "once" || consent === "session") void writeClipboard(write.text);
    return true;
  }

  /**
   * Guest clipboard reads are always refused: the browser clipboard never
   * reaches a guest. The OSC 52 query is consumed and nothing is sent back.
   * @param {string} selector @returns {Promise<boolean>}
   */
  async readClipboard(selector) {
    const socket = this.socket;
    if (!this.workspace.clipboard.read || this.mode !== "rw" || !this.connected || !navigator.clipboard) return true;
    try {
      const text = await navigator.clipboard.readText();
      const payload = clipboardPayload(text);
      if (payload !== null && this.workspace.clipboard.read && this.socket === socket && this.connected && !this.replaying) {
        this.sendInput(`\x1b]52;${selector};${payload}\x1b\\`);
      }
    } catch { /* Browser permission refusal remains a denial. */ }
    return true;
  }

  openLink(event, uri) {
    openConfirmedLink(event, uri);
  }

  /** Selections copy to the clipboard as soon as they are made. */
  copySelection() {
    if (!this.terminal) return;
    const selection = this.terminal.getSelection();
    if (selection && selection.length > 0) {
      writeClipboard(stripTrailingNewline(selection));
    }
  }

  focus() {
    this.wake();
    this.terminal.focus();
    this.fitToView();
  }

  fitToView() {
    if (!this.terminal) return;
    if (this.connected && this.mode === "ro") {
      this.terminal.resize(this.session.cols, this.session.rows);
      this.container.style.overflow = "auto";
    } else {
      this.fit.fit();
      this.container.style.overflow = "hidden";
    }
  }

  /** @param {number} delta */
  zoom(delta) {
    if (!this.terminal) return;
    this.fontSize = Math.max(8, Math.min(28, this.fontSize + delta));
    this.terminal.options.fontSize = this.fontSize;
    this.fitToView();
  }

  attach(ticket) {
    if (this.closed || this.connected) return;
    // The ticket's retry timer was cleared on delivery: a deferred attach must
    // re-request (which retries) instead of stranding the pane unattached.
    if (this.pendingWrites > 0 || (this.socket && this.socket.readyState <= 1)) {
      this.workspace.requestTicket(this.session.id);
      return;
    }
    this.closeSocket();
    this.wake();
    const protocol = window.location.protocol === "https:" ? "wss://" : "ws://";
    const cursor = this.cursor;
    const url = `${protocol}${window.location.host}/machines/${this.workspace.vmId}/terminals/${this.session.id}/socket?ticket=${encodeURIComponent(ticket)}&cursor=${cursor}&cols=${this.terminal.cols}&rows=${this.terminal.rows}`;
    this.setStatus("connecting");
    const socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    this.socket = socket;
    this.inputBatch = new InputBatch(socket);
    const consumed = { frames: 0, bytes: 0 };
    // Bounds only the WebSocket handshake. Once open, the server ends an
    // attachment that cannot attach (its own five-second limit), so a slow
    // page that has not yet handled the attached frame keeps its socket
    // (ADR-0140: slowness is never evidence).
    this.attachTimer = setTimeout(() => {
      if (this.socket === socket && socket.readyState === WebSocket.CONNECTING) socket.close();
    }, 10000);

    socket.onopen = () => {
      if (this.socket !== socket) return;
      clearTimeout(this.attachTimer);
      this.setStatus("connecting");
    };

    // The viewer sends a heartbeat every five seconds once attached. Fifteen
    // seconds of silence on an attached socket means its Marshall is gone
    // behind a half-open proxy connection: close it, so the ordinary
    // reconnect path fetches a ticket from a surviving node.
    let lastFrame = Date.now();
    const liveness = setInterval(() => {
      if (this.socket !== socket || socket.readyState > WebSocket.OPEN) {
        clearInterval(liveness);
      } else if (this.connected && Date.now() - lastFrame > 15000) {
        // A half-open socket may never finish a closing handshake: reconnect
        // now instead of waiting for its close event.
        clearInterval(liveness);
        socket.onclose = null;
        socket.close();
        lost();
      }
    }, 5000);

    socket.onmessage = (event) => {
      if (this.socket !== socket) return;
      lastFrame = Date.now();
      if (typeof event.data === "string") {
        this.handleControl(JSON.parse(event.data));
      } else {
        const bytes = new Uint8Array(event.data);
        this.cursor += bytes.length;
        this.writeOutput(socket, bytes, consumed);
        this.workspace.activity(this.session.id);
      }
    };

    const lost = () => {
      if (this.socket !== socket) return;
      this.inputBatch.close();
      clearTimeout(this.attachTimer);
      this.connected = false;
      this.socket = null;
      if (this.closed) return;
      this.setStatus("reconnecting");
      setTimeout(() => this.workspace.requestTicket(this.session.id), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 10000);
    };
    socket.onclose = lost;

    socket.onerror = () => {
      if (this.socket !== socket) return;
      socket.close();
    };
  }

  handleControl(message) {
    if (message.op === "heartbeat") return;
    if (message.op === "input_ack") {
      if (!this.inputBatch.acknowledge(message.frames, message.bytes)) this.socket?.close();
      else if (this.status === "input-paused") this.setStatus(this.mode === "rw" ? "live" : "readonly");
      return;
    }
    if (message.op === "attached") {
      if (!Number.isSafeInteger(message.replay_bytes) || message.replay_bytes < 0 || message.replay_bytes > 8388608) {
        this.socket?.close();
        return;
      }
      this.replayRemaining = message.replay_bytes;
      this.replayToParse = message.replay_bytes;
      this.replaying = message.replay_bytes > 0;
      clearTimeout(this.attachTimer);
      this.mode = message.mode;
      this.connected = true;
      this.fitToView();
      this.reconnectDelay = 500;
      if (message.from > this.cursor) {
        this.cursor = message.from;
        this.terminal.write("\r\n\x1b[90m— output before this view is not in the scrollback window —\x1b[0m\r\n");
      }
      if (this.replaying) {
        this.setStatus("restoring");
      } else if (message.mode === "ro") {
        this.setStatus("readonly");
      } else {
        this.setStatus("live");
        this.sendResize(this.terminal.cols, this.terminal.rows);
      }
    }
  }

  /** @param {WebSocket} socket @param {Uint8Array} bytes @param {{frames: number, bytes: number}} consumed */
  writeOutput(socket, bytes, consumed) {
    const replay = Math.min(this.replayRemaining, bytes.length);
    this.replayRemaining -= replay;
    this.pendingWrites++;
    const finished = () => {
      this.pendingWrites--;
      if (this.socket === socket && socket.readyState === WebSocket.OPEN) {
        consumed.frames++;
        consumed.bytes += bytes.length;
        socket.send(JSON.stringify({ op: "output_ack", frames: consumed.frames, bytes: consumed.bytes }));
      } else if (this.pendingWrites === 0 && !this.closed) {
        this.workspace.requestTicket(this.session.id);
      }
    };
    if (replay) {
      this.terminal.write(bytes.subarray(0, replay), () => {
        if (this.socket === socket) {
          this.replayToParse -= replay;
          if (this.replayToParse === 0) {
            this.replaying = false;
            this.setStatus(this.mode === "ro" ? "readonly" : "live");
            this.sendResize(this.terminal.cols, this.terminal.rows);
          }
        }
        if (replay === bytes.length) finished();
      });
      if (replay < bytes.length) this.terminal.write(bytes.subarray(replay), finished);
    } else {
      this.terminal.write(bytes, finished);
    }
  }

  /** @param {string} data */
  sendInput(data) {
    this.sendBytes(new TextEncoder().encode(data));
  }

  /** @param {Uint8Array} bytes */
  sendBytes(bytes) {
    if (this.mode === "rw" && this.connected && !this.replaying && this.socket && this.socket.readyState === WebSocket.OPEN) {
      if (!this.inputBatch.write(bytes)) this.setStatus("input-paused");
      else if (this.status === "input-paused") this.setStatus("live");
    }
  }

  /** @param {string} status */
  setStatus(status) {
    this.status = status;
    if (this.workspace.activeId === this.session.id) this.workspace.setStatus(status);
  }

  sendResize(cols, rows) {
    if (this.mode === "rw" && this.connected && this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ op: "resize", cols: cols, rows: rows }));
    }
  }

  closeSocket() {
    this.connected = false;
    // A pane without an open attachment is never reported live: a later
    // selection shows "connecting" until a fresh attachment confirms.
    if (this.status !== "connecting") this.status = "connecting";
    clearTimeout(this.attachTimer);
    this.inputBatch?.close();
    if (this.socket) {
      this.socket.onclose = null;
      this.socket.onmessage = null;
      this.socket.onopen = null;
      this.socket.onerror = null;
      this.socket.close();
      this.socket = null;
    }
  }

  destroy() {
    this.closed = true;
    this.closeSocket();
    this.container.removeEventListener("pointerup", this.releaseSelection);
    this.container.removeEventListener("keyup", this.releaseSelection);
    this.terminal?.dispose();
    this.terminal = null;
    // A remounted workspace builds fresh panes in the preserved holder; a
    // stale container left behind would duplicate their element ids.
    this.container.remove();
  }
}

export const TerminalWorkspace = {
  mounted() {
    this.vmId = this.el.dataset.vmId;
    this.panes = new Map();
    this.activeId = null;
    this.ticketTimers = new Map();
    this.liveConnected = true;
    this.clipboard = { write: "ask", read: false };
    /** @type {OpeningRequest | null} */
    this.opening = null;
    this.openingTimer = 0;
    this.originalTitle = document.title;
    this.bootPane = null;
    this.sessionSnapshot = [];

    this.handleEvent("terminal_ticket", (reply) => deliverTicket(this, reply));

    this.handleEvent("terminal_sessions", ({ sessions }) => {
      this.liveConnected = true;
      this.sessionSnapshot = sessions;
      this.renderSessions(sessions);
      if (this.activeId) this.requestTicket(this.activeId);
    });

    this.handleEvent("terminal_boot_log", ({ next, text }) => {
      this.renderBootLog(text, next);
    });

    this.observer = new ResizeObserver(() => {
      const pane = this.panes.get(this.activeId);
      if (pane) pane.fitToView();
      this.bootPane?.fitToView();
    });
    this.observer.observe(document.getElementById("terminal-pane-holder"));
    this.themeObserver = new MutationObserver(() => {
      for (const pane of this.panes.values()) if (pane.terminal) pane.terminal.options.theme = this.theme();
      if (this.bootPane) this.bootPane.terminal.options.theme = this.theme();
    });
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    this.fullscreenChanged = () => this.syncFullscreen();
    document.addEventListener("fullscreenchange", this.fullscreenChanged);
    // Native top-layer dialogs are not clipped by their containing panels.
    for (const id of ["terminal-share-dialog"]) {
      const dialog = this.el.querySelector(`#${id}`);
      if (dialog) {
        dialog.style.maxHeight = "calc(100dvh - 2rem)";
        dialog.style.overflowY = "auto";
      }
    }

    this.el.addEventListener("click", (event) => {
      const action = event.target.closest("[data-terminal-tool]")?.dataset.terminalTool;
      if (action) {
        const pane = this.panes.get(this.activeId);
        if (action === "search") this.openSearch();
        if (action === "search-close") this.closeSearch();
        if (action === "search-next") this.find(false);
        if (action === "search-previous") this.find(true);
        if (action === "zoom-in") pane?.zoom(1);
        if (action === "zoom-out") pane?.zoom(-1);
        if (action === "fullscreen") this.toggleFullscreen();
        if (action === "rename" && pane) {
          const name = window.prompt("Terminal name (this browser only; empty restores the generated name)", pane.localName || "");
          if (name !== null) {
            pane.localName = name.trim().slice(0, 80);
            this.updateTitle(pane.session.id, pane.title || "");
          }
        }
        if (action === "share-close") this.el.querySelector("#terminal-share-dialog").close();
        if (action === "share-submit" || action === "share-revoke") {
          const dialog = this.el.querySelector("#terminal-share-dialog");
          const email = this.el.querySelector("#terminal-share-email");
          if (!this.liveConnected || !email.reportValidity() || !email.value) return;
          this.el.querySelector("#terminal-share-result").textContent = "Updating viewing access…";
          this.push("terminal_share", { session_id: dialog.dataset.session, email: email.value, action: action === "share-submit" ? "share" : "revoke" }, (reply) => {
            this.el.querySelector("#terminal-share-result").textContent = reply.ok ? "Viewing access updated." : "Could not update access. Check the account's machine access.";
          });
        }
        return;
      }
      const share = event.target.closest("[data-terminal-share]");
      if (share) {
        const dialog = this.el.querySelector("#terminal-share-dialog");
        dialog.dataset.session = share.dataset.terminalShare;
        this.el.querySelector("#terminal-share-email").value = "";
        this.el.querySelector("#terminal-share-result").textContent = "";
        dialog.showModal();
        return;
      }
      const kill = event.target.closest("[data-terminal-kill]");
      if (kill) {
        if (window.confirm("Close this terminal session?")) {
          this.push("terminal_kill", { session_id: kill.dataset.terminalKill });
        }
        return;
      }
      const select = event.target.closest("[data-terminal-select]");
      if (select) {
        this.select(select.dataset.terminalSelect);
        return;
      }
      const create = event.target.closest("#terminal-create");
      if (create) {
        // Open immediately; the session receives its generated name and can be
        // renamed in this browser afterwards.
        if (!this.opening && this.liveConnected) {
          this.pendingName = "";
          this.opening = { request_id: crypto.randomUUID() };
          create.disabled = true;
          create.textContent = "Opening…";
          create.setAttribute("aria-busy", "true");
          this.retryOpening();
        }
        return;
      }
      const boot = event.target.closest("#terminal-boot-log");
      if (boot) {
        this.showBootLog();
        return;
      }
    });

    this.el.addEventListener("keydown", (event) => {
      const key = event.key.toLowerCase();
      if (event.target.id === "terminal-search-query") {
        if (key === "enter") { event.preventDefault(); this.find(event.shiftKey); }
        if (key === "escape") { event.preventDefault(); this.closeSearch(); }
        event.stopPropagation();
        return;
      }
      const sidebarItem = event.target.closest("[data-terminal-select]");
      if (sidebarItem && ["arrowdown", "arrowup", "home", "end"].includes(key)) {
        const entries = [...this.el.querySelectorAll("[data-terminal-select]")];
        const current = entries.indexOf(sidebarItem);
        const next = key === "home"
          ? 0
          : key === "end"
            ? entries.length - 1
            : Math.max(0, Math.min(entries.length - 1, current + (key === "arrowdown" ? 1 : -1)));
        const entry = entries[next];
        if (entry) {
          event.preventDefault();
          event.stopPropagation();
          entry.focus();
          this.select(entry.dataset.terminalSelect);
        }
        return;
      }
      if (event.ctrlKey && key === "f") {
        event.preventDefault(); event.stopPropagation(); this.openSearch(); return;
      }
      if (event.ctrlKey && event.shiftKey && ["t", "w", "c", "v"].includes(key)) {
        event.preventDefault(); event.stopPropagation();
        const pane = this.panes.get(this.activeId);
        if (key === "t") this.el.querySelector("#terminal-create")?.click();
        if (key === "w" && pane?.session.can_kill && window.confirm("Close this terminal session?")) {
          this.push("terminal_kill", { session_id: pane.session.id });
        }
        if (key === "c") pane?.copySelection();
        if (key === "v" && pane?.mode === "rw" && pane.connected) {
          navigator.clipboard?.readText().then((text) => { if (!pane.closed && pane.connected) pane.terminal.paste(text); }).catch(() => {});
        }
        return;
      }
      if (!event.altKey) return;
      const digit = parseInt(event.key, 10);
      if (!Number.isNaN(digit) && digit >= 1 && digit <= 9) {
        const entries = [...this.panes.keys()];
        if (entries[digit - 1]) this.select(entries[digit - 1]);
        event.preventDefault(); event.stopPropagation();
      }
    }, true);
    this.el.addEventListener("wheel", (event) => {
      if (event.ctrlKey) {
        event.preventDefault();
        this.panes.get(this.activeId)?.zoom(event.deltaY < 0 ? 1 : -1);
      }
    }, { passive: false });
    this.el.querySelector("#terminal-search-query")?.addEventListener("input", () => this.find(false));

    this.renderSessions([]);
  },

  updated() {
    this.renderSessions(this.sessionSnapshot);
  },

  destroyed() {
    this.liveConnected = false;
    clearTimeout(this.openingTimer);
    clearTimeout(this.activityTimer);
    this.opening = null;
    document.title = this.originalTitle;
    for (const timer of this.ticketTimers.values()) clearTimeout(timer);
    this.ticketTimers.clear();
    if (this.observer) this.observer.disconnect();
    this.themeObserver?.disconnect();
    document.removeEventListener("fullscreenchange", this.fullscreenChanged);
    this.bootPane?.dispose();
    this.bootPane = null;
    for (const pane of this.panes.values()) pane.destroy();
    this.panes.clear();
  },

  /**
   * @cc [owner:ghuntley,label:recovery;security] terminal-sockets-outlive-live-view
   * A LiveView disconnect MUST only pause ticket requests and creation
   * retries. Attached terminal sockets are authorized and rechecked by the
   * server on their own, so they MUST stay open (ADR-0140: a slow or
   * reconnecting page is not evidence the terminal ended).
   */
  disconnected() {
    this.liveConnected = false;
    clearTimeout(this.openingTimer);
    for (const timer of this.ticketTimers.values()) clearTimeout(timer);
    this.ticketTimers.clear();
  },

  reconnected() {
    this.liveConnected = true;
    this.retryOpening();
    if (this.activeId) this.requestTicket(this.activeId);
  },

  /**
   * @cc [owner:ghuntley,label:recovery] browser-create-retry-identity
   * Retries MUST keep one request ID and its original parameters until a
   * definitive response. Disconnects MUST NOT manufacture another create.
   * Request parameters remain in memory and MUST NOT enter browser storage.
   */
  /**
   * @cc [owner:ghuntley,label:product] browser-create-select-once
   * A successful create MUST select its pane once, whether its listing arrives
   * before or after the reply. Later refreshes MUST preserve a subsequent user
   * selection instead of selecting that newly created pane again.
   */
  retryOpening() {
    clearTimeout(this.openingTimer);
    const opening = this.opening;
    if (!this.liveConnected || !opening) return;
    this.openingTimer = setTimeout(() => this.retryOpening(), 7500);
    this.push("terminal_new", opening, (reply) => {
      if (!reply || reply.request_id !== this.opening?.request_id) return;
      if (reply.status !== "ready" && reply.status !== "failed") return;
      clearTimeout(this.openingTimer);
      this.opening = null;
      const button = this.el.querySelector("#terminal-create");
      if (button) {
        button.disabled = false;
        button.textContent = "+ New";
        button.setAttribute("aria-busy", "false");
      }
      if (reply.status === "ready" && typeof reply.session_id === "string") {
        if (this.pendingName) {
          const pane = this.panes.get(reply.session_id);
          if (pane) pane.localName = this.pendingName;
          else this.pendingNamedSession = { id: reply.session_id, name: this.pendingName };
        }
        if (this.panes.has(reply.session_id)) {
          this.selectAfterRefresh = null;
          this.select(reply.session_id);
        } else {
          this.selectAfterRefresh = reply.session_id;
        }
      }
    });
  },

  /** @returns {{background: string, foreground: string, cursor: string}} */
  theme() {
    const palette = readPalette();
    return {
      background: palette.background, foreground: palette.text,
      cursor: palette.text, cursorAccent: palette.background,
      selectionBackground: palette.textAlt, selectionForeground: palette.background,
      selectionInactiveBackground: palette.backgroundAlt,
    };
  },

  /**
   * @cc [owner:ghuntley,label:product] browser-terminal-fullscreen-fit
   * The fullscreen control MUST target only the terminal display, reflect the
   * browser's actual fullscreen state accessibly and refit the visible xterm
   * after entering or leaving fullscreen.
   */
  toggleFullscreen() {
    const display = this.el.querySelector("#terminal-display");
    if (!display) return;
    if (document.fullscreenElement === display) {
      void document.exitFullscreen?.().catch(() => {});
    } else if (!document.fullscreenElement) {
      void display.requestFullscreen?.().catch(() => {});
    }
  },

  syncFullscreen() {
    const display = this.el.querySelector("#terminal-display");
    const button = this.el.querySelector("#terminal-fullscreen");
    const active = document.fullscreenElement === display;
    if (button) {
      const label = active ? "Exit full screen" : "Enter full screen";
      button.setAttribute("aria-label", label);
      button.setAttribute("aria-pressed", String(active));
      button.title = label;
    }
    const pane = this.panes.get(this.activeId);
    pane?.fitToView();
    this.bootPane?.fitToView();
  },

  renderSessions(sessions) {
    const list = this.el.querySelector("#terminal-sidebar-list");
    if (!list) return;
    const current = new Set(sessions.map((session) => session.id));
    for (const [id, pane] of this.panes) {
      if (current.has(id)) continue;
      pane.destroy();
      pane.container.remove();
      this.panes.delete(id);
      clearTimeout(this.ticketTimers.get(id));
      this.ticketTimers.delete(id);
      if (this.activeId === id) this.activeId = null;
    }

    for (const session of sessions) {
      this.ensurePane(session);
      const pane = this.panes.get(session.id);
      const item = this.el.querySelector(`#terminal-item-${session.id}`);
      if (!item) continue;
      item.setAttribute("aria-selected", String(session.id === this.activeId));
      const label = item.querySelector(".terminal-label");
      if (label) label.textContent = displayName(session, pane);
      const meta = item.querySelector(".terminal-meta");
      if (meta) meta.textContent = `${pane?.title || session.guest_user} · ${session.viewers} viewing · ${relativeActivity(session.last_ms)}`;
      item.querySelector(".terminal-unread-dot")?.classList.toggle("unread", !!pane?.unread);
    }

    if (this.selectAfterRefresh && this.panes.has(this.selectAfterRefresh)) {
      this.select(this.selectAfterRefresh);
      this.selectAfterRefresh = null;
    } else if (this.activeId === null && this.panes.size) {
      this.select(this.panes.keys().next().value);
    }
    if (this.panes.size === 0) this.setStatus("No terminals");

  },

  ensurePane(session) {
    if (this.panes.has(session.id)) {
      const pane = this.panes.get(session.id);
      if (session.id !== this.activeId && session.last_ms > pane.session.last_ms) pane.unread = true;
      pane.session = session;
      if (pane.mode === "ro") pane.fitToView();
      return;
    }
    const holder = document.getElementById("terminal-pane-holder");
    if (!holder) return;
    const container = document.createElement("div");
    container.id = `terminal-pane-${session.id}`;
    container.className = "terminal-pane hidden";
    holder.appendChild(container);
    const pane = new Pane(this, session, container);
    if (this.pendingNamedSession?.id === session.id) {
      pane.localName = this.pendingNamedSession.name;
      this.pendingNamedSession = null;
    }
    this.panes.set(session.id, pane);

    if (this.activeId === null) this.select(session.id);
  },

  /**
   * @cc [owner:ghuntley,label:recovery] browser-single-active-attachment
   * The browser MUST keep a transport attachment only for the selected pane.
   * Selecting another pane MUST close the previous socket before requesting a
   * fresh single-use ticket, while preserving each awake pane's replay cursor
   * (a hibernated pane replays from zero; see browser-bounded-live-emulators).
   */
  select(sessionId) {
    if (!this.panes.has(sessionId)) return;
    this.activeId = sessionId;
    this.recent = [sessionId, ...(this.recent || []).filter((id) => id !== sessionId && this.panes.has(id))];
    this.panes.get(sessionId).unread = false;
    document.getElementById(`terminal-item-${sessionId}`)?.querySelector(".terminal-unread-dot")?.classList.remove("unread");
    const boot = document.getElementById("terminal-boot-view");
    if (boot) boot.classList.add("hidden");
    const holder = document.getElementById("terminal-pane-holder");
    if (holder) holder.classList.remove("hidden");
    for (const [id, pane] of this.panes) {
      if (id !== sessionId) pane.closeSocket();
      // Toggle the pane's own container, never an id lookup that a stale
      // duplicate could satisfy first.
      pane.container.classList.toggle("hidden", id !== sessionId);
      const item = document.getElementById(`terminal-item-${id}`);
      if (item) {
        item.setAttribute("aria-selected", String(id === sessionId));
      }
    }
    this.hibernateIdle();
    const pane = this.panes.get(sessionId);
    if (pane) {
      pane.wanted = true;
      pane.focus();
      document.title = pane.localName || pane.title ? `${pane.localName || pane.title} · Terminals` : this.originalTitle;
      this.setStatus(pane.status);
      if (!pane.connected) this.requestTicket(sessionId);
    }
  },

  hibernateIdle() {
    const keep = new Set((this.recent || []).slice(0, LIVE_PANES));
    if (this.activeId) keep.add(this.activeId);
    for (const [id, pane] of this.panes) if (!keep.has(id)) pane.hibernate();
  },

  /**
   * @cc [owner:ghuntley,label:recovery] terminal-push-never-throws
   * Pushes MUST go through push/3. While the LiveView is not connected (also
   * between losing and rejoining its channel) a push is dropped instead of
   * throwing; ticket requests and openings retry on their own timers.
   * @param {string} event @param {object} payload @param {Function} [reply]
   * @returns {boolean} whether the push was handed to LiveView
   */
  push(event, payload, reply) {
    if (!this.liveConnected) return false;
    try {
      if (reply) this.pushEvent(event, payload, reply);
      else this.pushEvent(event, payload);
      return true;
    } catch (_error) {
      this.liveConnected = false;
      return false;
    }
  },

  /**
   * @cc [owner:ghuntley,label:recovery] terminal-selected-pane-reattaches
   * The selected, detached pane MUST keep trying to attach while LiveView is
   * connected: a request deferred by draining writes or a still-closing socket
   * MUST schedule a retry rather than return silently, so no selection can
   * strand a pane without an attachment.
   */
  requestTicket(sessionId) {
    if (sessionId !== this.activeId) return;
    const pane = this.panes.get(sessionId);
    if (!this.liveConnected || !pane || pane.closed || pane.connected || this.ticketTimers.has(sessionId)) return;
    if (pane.pendingWrites > 0 || (pane.socket && pane.socket.readyState <= 1)) {
      this.ticketTimers.set(sessionId, setTimeout(() => {
        this.ticketTimers.delete(sessionId);
        this.requestTicket(sessionId);
      }, 500));
      return;
    }
    this.ticketTimers.set(sessionId, setTimeout(() => {
      this.ticketTimers.delete(sessionId);
      this.requestTicket(sessionId);
    }, 2500));
    this.push("terminal_ticket", { session_id: sessionId });
  },

  activity(sessionId) {
    const item = document.getElementById(`terminal-item-${sessionId}`);
    const pane = this.panes.get(sessionId);
    if (!item || !pane || pane.replaying) return;
    const dot = item.querySelector(".terminal-unread-dot");
    if (dot) {
      dot.classList.add("unread");
      if (sessionId !== this.activeId) { pane.unread = true; return; }
      dot.classList.add("terminal-recent-activity");
      clearTimeout(this.activityTimer);
      this.activityTimer = setTimeout(() => { dot.classList.remove("terminal-recent-activity"); if (!pane.unread) dot.classList.remove("unread"); }, 400);
    }
  },

  openSearch() {
    this.el.querySelector("#terminal-search-bar")?.classList.remove("hidden");
    this.el.querySelector("#terminal-search-query")?.focus();
  },

  closeSearch() {
    this.el.querySelector("#terminal-search-bar")?.classList.add("hidden");
    this.panes.get(this.activeId)?.search.clearDecorations();
    this.panes.get(this.activeId)?.focus();
  },

  /** @param {boolean} previous */
  find(previous) {
    const pane = this.panes.get(this.activeId);
    const query = this.el.querySelector("#terminal-search-query")?.value || "";
    const result = this.el.querySelector("#terminal-search-result");
    if (!pane || !query) { pane?.search.clearDecorations(); if (result) result.textContent = ""; return; }
    const palette = readPalette();
    const options = { decorations: { matchBackground: palette.backgroundAlt, matchBorder: palette.textAlt, activeMatchBackground: palette.backgroundAlt, activeMatchBorder: palette.text, matchOverviewRuler: palette.textAlt, activeMatchColorOverviewRuler: palette.text } };
    const found = previous ? pane.search.findPrevious(query, options) : pane.search.findNext(query, options);
    if (result) result.textContent = found ? "Match found" : "No matches";
  },

  updateTitle(sessionId, title) {
    const pane = this.panes.get(sessionId);
    if (!pane) return;
    if (title) pane.title = title;
    const item = document.getElementById(`terminal-item-${sessionId}`);
    const label = item && item.querySelector(".terminal-label");
    if (label) label.textContent = displayName(pane.session, pane);
    const meta = item && item.querySelector(".terminal-meta");
    if (meta && pane.title) meta.textContent = `${pane.title} · ${pane.session.viewers} viewing`;
    if (sessionId === this.activeId) document.title = `${displayName(pane.session, pane)} · Terminals`;
  },

  setStatus(status) {
    const element = document.getElementById("terminal-status");
    if (!element) return;
    const labels = { live: "● live", reconnecting: "⟳ reconnecting…", restoring: "⟳ restoring scrollback…", readonly: "● read-only", "boot-log": "Boot log · read-only", "input-paused": "Input buffer full — that input was not sent" };
    element.textContent = labels[status] || status;
    element.dataset.status = status;
    const input = document.getElementById("terminal-input-hint");
    if (input) input.textContent = ["readonly", "boot-log"].includes(status) ? "View only" : "Type to interact";
  },

  showBootLog() {
    const holder = document.getElementById("terminal-pane-holder");
    const boot = document.getElementById("terminal-boot-view");
    if (holder && boot) {
      holder.classList.add("hidden");
      boot.classList.remove("hidden");
      const pane = this.ensureBootPane();
      pane?.fitToView();
      this.setStatus("boot-log");
      this.push("terminal_boot_log", { cursor: String(pane?.cursor || 0) });
    }
  },

  /**
   * @cc [owner:ghuntley,label:security;recovery] browser-boot-log-byte-fidelity
   * Boot-log chunks MUST reach a read-only xterm as their decoded bytes in cursor
   * order, never as HTML or decoded text. A cursor rewind MUST reset the emulator
   * and refetch from zero. Boot output MUST NOT receive an input, clipboard or
   * unrestricted-link capability.
   */
  renderBootLog(text, next) {
    const boot = document.getElementById("terminal-boot-view");
    if (!boot) return;
    const pane = this.ensureBootPane();
    if (!pane || !Number.isSafeInteger(next) || next < 0) return;
    const previous = pane.cursor;
    // Pull further chunks only while the boot view is visible: a hidden,
    // screen-reader-mode emulator replaying a whole boot log (for example after
    // a LiveView remount on another node) can starve the page's main thread.
    // showBootLog() resumes from the pane's cursor.
    const visible = !boot.classList.contains("hidden");
    if (next < previous) {
      pane.reset();
      boot.dataset.next = "0";
      if (this.liveConnected && visible) this.push("terminal_boot_log", { cursor: "0" });
      return;
    }
    const bytes = decodeBase64Bytes(text || "");
    pane.cursor = next;
    boot.dataset.next = String(next);
    if (!bytes.length || next <= previous) return;
    const follow = this.el.querySelector("#terminal-boot-autoscroll")?.checked === true;
    pane.write(bytes, follow, () => {
      if (this.liveConnected && !boot.classList.contains("hidden")) {
        this.push("terminal_boot_log", { cursor: String(next) });
      }
    });
  },

  ensureBootPane() {
    if (this.bootPane) return this.bootPane;
    const container = document.getElementById("terminal-boot-xterm");
    if (!container) return null;
    this.bootPane = new BootLogPane(this, container);
    this.observer?.observe(container);
    return this.bootPane;
  },

  escape(value) {
    const div = document.createElement("div");
    div.textContent = value;
    return div.innerHTML;
  },
};
