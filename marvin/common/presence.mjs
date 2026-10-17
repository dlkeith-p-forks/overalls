const MARKER_VALUE = "installed";

/**
 * @cc [owner:ghuntley,label:product] marvin-presence-marker
 * The detector MUST mark only the current document element with the stable
 * `data-overalls-browser-extension="installed"` attribute. It MUST NOT read,
 * transmit or persist page content.
 */
/** @param {Document} page @returns {void} */
function markInstalled(page) {
  const setMarker = () => {
    const root = page.documentElement;
    if (root === null) return false;
    root.dataset.overallsBrowserExtension = MARKER_VALUE;
    return true;
  };
  if (!setMarker()) page.addEventListener("DOMContentLoaded", setMarker, { once: true });
}

if (typeof document !== "undefined") markInstalled(document);
