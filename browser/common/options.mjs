import { normalizeServerUrl } from "./launch.mjs";
const api = globalThis.browser ?? globalThis.chrome;
const form = document.querySelector("form");
const input = document.querySelector("#server-url");
const status = document.querySelector("#status");
const guideLink = document.querySelector("#guide-link");
if (!api || !(form instanceof HTMLFormElement) || !(input instanceof HTMLInputElement) ||
    !(status instanceof HTMLElement) || !(guideLink instanceof HTMLAnchorElement)) {
  throw new Error("Extension settings unavailable");
}

/**
 * @cc [owner:ghuntley,label:product;security] browser-settings-guide-link
 * Extension settings MUST link to the configured server's canonical browser
 * extension guide after saving a valid origin. An unset or invalid origin MUST
 * fall back to the reviewed source guide without guessing a Overalls server.
 */
/** @param {HTMLAnchorElement} link @param {string} serverUrl @returns {void} */
function updateGuideLink(link, serverUrl) {
  try {
    link.href = new URL("/docs/browser-extension", normalizeServerUrl(serverUrl)).href;
  } catch {
    link.href = "https://github.com/antithesishq/kittens/blob/main/marshall/priv/docs/browser-extension.md";
  }
}
const settings = api.storage.sync;
try {
  const response = await fetch(new URL("build-info.json", import.meta.url));
  if (!response.ok) throw new Error("Build information unavailable");
  /** @type {unknown} */
  const build = await response.json();
  if (typeof build !== "object" || build === null) throw new Error("Invalid build information");
  for (const field of ["version", "source_sha256", "build_timestamp", "platform"]) {
    const element = document.querySelector(`[data-build="${field}"]`);
    if (element && field in build) {
      /** @type {unknown} */ const value = Reflect.get(build, field);
      if (typeof value === "string") element.textContent = value;
    }
  }
} catch { /* Settings remain usable when optional metadata is unavailable. */ }
const stored = await settings.get("overallsServerUrl");
input.value = typeof stored.overallsServerUrl === "string" ? stored.overallsServerUrl : "";
updateGuideLink(guideLink, input.value);
form.addEventListener("submit", (event) => {
  event.preventDefault();
  try {
    const value = normalizeServerUrl(input.value);
    void settings.set({ overallsServerUrl: value }).then(() => {
      input.value = value;
      updateGuideLink(guideLink, value);
      status.dataset.error = "false";
      status.textContent = "Saved.";
    }, () => {
      status.dataset.error = "true";
      status.textContent = "The browser could not save this setting.";
    });
  } catch (error) {
    status.dataset.error = "true";
    status.textContent = error instanceof Error ? error.message : "Invalid server URL.";
  }
});
