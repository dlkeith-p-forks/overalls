/**
 * Resolve browser copy from the server's Gettext catalog. Keys are source
 * msgids, matching Elixir Gettext; untrusted values are inserted as text only.
 * @param {string} message
 * @param {Record<string, string | number>} bindings
 * @returns {string}
 */
export function t(message, bindings = {}) {
  let translated = message;
  if (typeof document !== "undefined" && typeof document.querySelector === "function") {
    const encoded = document.querySelector("meta[name='overalls-messages']")?.getAttribute("content");
    if (encoded) {
      try {
        /** @type {unknown} */
        const catalog = JSON.parse(encoded);
        if (typeof catalog === "object" && catalog !== null && message in catalog) {
          const value = Reflect.get(catalog, message);
          if (typeof value === "string") translated = value;
        }
      } catch { /* English remains available when metadata is unavailable. */ }
    }
  }
  return translated.replace(/%\{([^}]+)\}/g, (placeholder, key) =>
    Object.hasOwn(bindings, key) ? String(bindings[key]) : placeholder);
}

/**
 * @cc [owner:ghuntley,label:product] locale-change-reloads-document
 * A saved or cleared language MUST reload the whole document so the server
 * renders root language/direction, including repeated saves and fragment URLs.
 * @param {{addEventListener: (event: string, listener: () => void) => void, location: {reload: () => void}}} browser
 * @returns {void}
 */
export function installLocaleReload(browser) {
  browser.addEventListener("phx:locale-updated", () => browser.location.reload());
}
