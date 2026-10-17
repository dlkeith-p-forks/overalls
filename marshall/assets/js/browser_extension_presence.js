// @ts-check

const MARKER_ATTRIBUTE = "data-overalls-browser-extension";
const MARKER_VALUE = "installed";
const SETUP_SELECTOR = "[data-overalls-extension-setup]";

/**
 * @cc [owner:ghuntley,label:product;security] browser-extension-presence-hint
 * The browser extension marker MAY hide setup entry points as a presentation
 * hint only. It MUST NOT grant access, change navigation authority, or hide
 * the direct documentation route. Any missing or non-installed marker MUST
 * leave setup entry points visible.
 * @param {Document} doc
 * @returns {boolean}
 */
function extensionIsPresent(doc) {
  return doc.documentElement.getAttribute(MARKER_ATTRIBUTE) === MARKER_VALUE;
}

/**
 * @cc [owner:ghuntley,label:product] browser-extension-setup-visibility
 * Every setup target MUST reflect the current marker state, including after a
 * LiveView patch replaces the target or the extension adds its marker later.
 * @param {Document} doc
 * @returns {void}
 */
function updateSetupVisibility(doc) {
  const hidden = extensionIsPresent(doc);
  doc.querySelectorAll(SETUP_SELECTOR).forEach((target) => {
    if (target instanceof HTMLElement) target.hidden = hidden;
  });
}

/**
 * @cc [owner:ghuntley,label:product] browser-extension-presence-observer
 * Presence detection MUST run on the initial document and observe marker and
 * subtree changes so navigation patches cannot restore stale setup controls.
 * @param {Document} doc
 * @returns {void}
 */
export function initBrowserExtensionPresence(doc) {
  updateSetupVisibility(doc);
  const observer = new MutationObserver(() => updateSetupVisibility(doc));
  observer.observe(doc.documentElement, {
    attributes: true,
    attributeFilter: [MARKER_ATTRIBUTE],
    childList: true,
    subtree: true,
  });
}
