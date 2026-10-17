// @ts-check
/** @typedef {{background: string, backgroundAlt: string, text: string, textAlt: string}} Palette */

/**
 * @cc [owner:ghuntley,label:product] canvas-theme-source
 * Browser-owned canvas colors MUST come from the current CSS theme tokens so
 * changing appearance updates terminals and diagrams alongside HTML surfaces.
 * The Monospace Web presentation exposes exactly four tokens (ADR-0161).
 */
/** @returns {Palette} */
export function readPalette() {
  const css = getComputedStyle(document.documentElement);
  /** @param {string} token */
  const value = token => css.getPropertyValue(token).trim();
  return {
    background: value("--background-color"),
    backgroundAlt: value("--background-color-alt"),
    text: value("--text-color"),
    textAlt: value("--text-color-alt"),
  };
}
