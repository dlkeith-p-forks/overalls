// @ts-check
/**
 * Character-grid helpers ported from The Monospace Web by Oskar Wickström
 * (MIT License, assets/vendor/monospace-web/LICENSE.md). Side-effect free:
 * callers decide when to measure, pad media or render the debug overlay.
 */

/** @typedef {{width: number, height: number}} Cell */
/** @typedef {{selector: string, offset: number}} OffGrid */

const IGNORED_TAGS = new Set(["THEAD", "TBODY", "TFOOT", "TR", "TD", "TH"]);
/** Renderer-owned or overlaid DOM that legitimately sits off the page grid. */
const SKIP_SELECTOR = ".xterm, .xterm *, svg, svg *, [hidden], .sr-only, .skip-link, .glyph, .debug-grid, #flash-group, #flash-group *, dialog, dialog *, #admin-elevation-hook, #admin-elevation-hook *, [data-phx-session]";
const TOLERANCE = 0.1;

/** @param {Document} doc @returns {Cell} */
export function gridCellDimensions(doc) {
  const element = doc.createElement("div");
  element.style.position = "fixed";
  element.style.height = "var(--line-height)";
  element.style.width = "1ch";
  doc.body.appendChild(element);
  const rect = element.getBoundingClientRect();
  doc.body.removeChild(element);
  return {width: rect.width, height: rect.height};
}

/** @param {Element} element @returns {string} */
function describe(element) {
  const id = element.id ? `#${element.id}` : "";
  const classes = element.classList.length ? `.${Array.from(element.classList).slice(0, 3).join(".")}` : "";
  return `${element.tagName.toLowerCase()}${id}${classes}`;
}

/**
 * Elements whose top edge does not fall on a half-line boundary.
 * @param {Document} doc
 * @param {{root?: ParentNode, skip?: string}} [options]
 * @returns {OffGrid[]}
 */
export function offGridElements(doc, options = {}) {
  const cell = gridCellDimensions(doc);
  const half = cell.height / 2;
  const root = options.root ?? doc.body;
  const skip = options.skip ?? SKIP_SELECTOR;
  const view = doc.defaultView;
  const scrollY = view ? view.scrollY : 0;
  /** @type {OffGrid[]} */
  const offenders = [];
  for (const element of root.querySelectorAll("*")) {
    if (IGNORED_TAGS.has(element.tagName) || element.matches(skip)) continue;
    // Inline boxes follow the text run, not the grid; only block-level boxes are checked.
    if (view && view.getComputedStyle(element).display === "inline") continue;
    const rect = element.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) continue;
    const top = rect.top + scrollY;
    const remainder = top % half;
    const offset = Math.min(remainder, half - remainder);
    if (offset > TOLERANCE) offenders.push({selector: describe(element), offset});
  }
  return offenders;
}

/**
 * Pad images, video and rendered diagrams so their boxes end on a grid line.
 * @param {Document} doc
 */
export function adjustMediaPadding(doc) {
  const cell = gridCellDimensions(doc);
  /** @param {HTMLElement} media @param {number} ratio */
  const setHeightFromRatio = (media, ratio) => {
    const rect = media.getBoundingClientRect();
    const realHeight = rect.width / ratio;
    const diff = cell.height - (realHeight % cell.height);
    media.style.setProperty("padding-bottom", `${diff}px`);
  };
  /** @param {HTMLElement} media */
  const setFallbackHeight = media => {
    const rect = media.getBoundingClientRect();
    const height = Math.round((rect.width / 2) / cell.height) * cell.height;
    media.style.setProperty("height", `${height}px`);
  };
  for (const media of doc.querySelectorAll("img, video")) {
    if (!(media instanceof HTMLImageElement) && !(media instanceof HTMLVideoElement)) continue;
    const apply = () => {
      const width = media instanceof HTMLImageElement ? media.naturalWidth : media.videoWidth;
      const height = media instanceof HTMLImageElement ? media.naturalHeight : media.videoHeight;
      if (width > 0 && height > 0) setHeightFromRatio(media, width / height);
      else setFallbackHeight(media);
    };
    if (media instanceof HTMLImageElement) {
      if (media.complete) apply();
      else {
        media.addEventListener("load", apply, {once: true});
        media.addEventListener("error", () => setFallbackHeight(media), {once: true});
      }
    } else if (media.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) apply();
    else {
      media.addEventListener("loadeddata", apply, {once: true});
      media.addEventListener("error", () => setFallbackHeight(media), {once: true});
    }
  }
}

/**
 * Toggle the development grid overlay and mark off-grid elements.
 * @param {Document} doc @param {boolean} enabled
 */
export function setGridDebug(doc, enabled) {
  doc.body.classList.toggle("debug", enabled);
  let overlay = doc.body.querySelector(":scope > .debug-grid");
  if (enabled && !overlay) {
    overlay = doc.createElement("div");
    overlay.className = "debug-grid";
    overlay.setAttribute("aria-hidden", "true");
    doc.body.appendChild(overlay);
  }
  for (const marked of doc.querySelectorAll(".off-grid")) marked.classList.remove("off-grid");
  if (!enabled) return;
  for (const {selector} of offGridElements(doc)) {
    for (const element of doc.querySelectorAll(selector)) element.classList.add("off-grid");
  }
}
