import {t} from "./localization.js";
// @ts-check
const PREFIX = "overalls.launch:";

/**
 * @cc [owner:ghuntley,label:security] captured-source-preserves-server-refusals
 * Source minimization MUST preserve raw authority and path spelling so it
 * cannot normalize explicit ports or traversal past the server's URL refusal.
 */
/**
 * @cc [owner:ghuntley,label:security] captured-source-minimizes-url-data
 * Source input MUST discard URL queries/fragments before browser storage or
 * submission and MUST refuse URL user information without transmitting it.
 * @param {string} fragment
 * @returns {string | null}
 */
export function capturedRepositorySource(fragment) {
  if (!fragment.startsWith("#https://")) return null;
  try {
    const source = fragment.slice(1);
    const url = new URL(source);
    const authority = source.slice("https://".length).split(/[/?#]/, 1)[0];
    if (url.protocol !== "https:" || url.username || url.password || authority.includes("@")) return null;
    const boundary = source.search(/[?#]/);
    // Preserve raw authority/path spelling so server port/traversal refusals apply.
    return boundary < 0 ? source : source.slice(0, boundary);
  } catch {
    return null;
  }
}

/**
 * @cc [owner:ghuntley,label:product;security] capture-stages-input-only
 * Capture MUST remove the URL fragment, minimize its source with
 * capturedRepositorySource, and submit source/visit only through the same-origin
 * CSRF form. It MUST NOT create a machine or choose a return path from the
 * submitted repository URL. Replays in one tab MUST reuse its nonce.
 * @param {Document} doc
 * @param {Window} browser
 * @returns {void}
 */
export function captureRepositoryLaunch(doc, browser) {
  const entry = doc.getElementById("repository-launch-entry");
  if (!(entry instanceof HTMLElement)) return;
  const hash = browser.location.hash;
  if (!hash.startsWith("#https://")) {
    const destination = entry.dataset.idleTo;
    if (destination === "/launch" || destination === "/overview" || destination === "/sign-in") {
      browser.location.replace(destination);
    }
    return;
  }
  doc.getElementById("repository-launch-page")?.removeAttribute("hidden");
  const form = doc.getElementById("repository-launch-capture");
  const sourceInput = doc.getElementById("repository-launch-source");
  const visitInput = doc.getElementById("repository-launch-visit");
  if (!(form instanceof HTMLFormElement) || !(sourceInput instanceof HTMLInputElement) ||
      !(visitInput instanceof HTMLInputElement)) return;
  try {
    browser.history.replaceState(browser.history.state, "", browser.location.pathname + browser.location.search);
  } catch {
    // A retained fragment still passes source minimization before storage.
  }
  const source = capturedRepositorySource(hash);
  if (source === null) {
    entry.textContent = t("This repository link could not be launched. Open the link again.");
    return;
  }
  let visit;
  try {
    visit = browser.sessionStorage.getItem(PREFIX + source);
  } catch {
    visit = null;
  }
  if (typeof visit !== "string" || !/^[0-9a-f]{32}$/.test(visit)) {
    const bytes = new Uint8Array(16);
    browser.crypto.getRandomValues(bytes);
    visit = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    try {
      browser.sessionStorage.setItem(PREFIX + source, visit);
    } catch {
      // The signed session preserves this nonce after capture succeeds.
    }
  }
  sourceInput.value = source;
  visitInput.value = visit;
  form.requestSubmit();
}

/**
 * @cc [owner:ghuntley,label:security;recovery] admitted-launch-clears-through-csrf
 * Completion MUST submit the server's signed receipt through a CSRF-protected
 * same-origin POST. A receipt MUST NOT choose an arbitrary destination; only
 * the HTTP controller may verify it, clear matching input and navigate.
 */
export const RepositoryLaunchComplete = {
  /**
   * @this {{handleEvent: (event: string, callback: (payload: unknown) => void) => void}}
   * @returns {void}
   */
  mounted() {
    this.handleEvent("repository-launch-complete", (payload) => {
      if (typeof payload !== "object" || payload === null || !("receipt" in payload) ||
          typeof payload.receipt !== "string" || payload.receipt.length > 4096) return;
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
      if (!csrf) return;
      const form = document.createElement("form");
      form.method = "post";
      form.action = "/launch/pending/clear";
      form.hidden = true;
      for (const [name, value] of [["receipt", payload.receipt], ["_csrf_token", csrf]]) {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = name;
        input.value = value;
        form.append(input);
      }
      document.body.append(form);
      form.requestSubmit();
    });
  },
};
