import {t} from "./localization.js";
// @ts-check
import mermaid from "../vendor/mermaid/mermaid.mjs";
import {readPalette} from "./palette.js";

/**
 * @cc [owner:ghuntley,label:integration] handbook-render-owner
 * Mermaid's automatic document scan MUST be disabled before window load.
 * Only the mounted section hook may consume and replace diagram source.
 */
/** Mermaid colours derive from the four presentation tokens (ADR-0161). */
function themeVariables() {
  const p = readPalette();
  return {
    fontFamily: "JetBrains Mono, ui-monospace, monospace", fontSize: "16px",
    background: p.background, mainBkg: p.backgroundAlt, primaryColor: p.backgroundAlt,
    primaryTextColor: p.text, primaryBorderColor: p.text, secondaryColor: p.background,
    secondaryTextColor: p.text, secondaryBorderColor: p.text, tertiaryColor: p.backgroundAlt,
    tertiaryTextColor: p.text, tertiaryBorderColor: p.textAlt, lineColor: p.text, textColor: p.text,
    nodeBorder: p.text, nodeTextColor: p.text, clusterBkg: p.background, clusterBorder: p.textAlt,
    titleColor: p.text, edgeLabelBackground: p.background, noteBkgColor: p.backgroundAlt,
    noteTextColor: p.text, noteBorderColor: p.text, actorBkg: p.background, actorBorder: p.text,
    actorTextColor: p.text, actorLineColor: p.textAlt, signalColor: p.text, signalTextColor: p.text,
    labelBoxBkgColor: p.background, labelBoxBorderColor: p.text, labelTextColor: p.text,
    loopTextColor: p.text, activationBkgColor: p.backgroundAlt, activationBorderColor: p.text,
    sequenceNumberColor: p.background,
  };
}

mermaid.initialize({startOnLoad: false, securityLevel: "strict", suppressErrorRendering: true,
  theme: "base", themeVariables: themeVariables(), flowchart: {htmlLabels: false}});

/** @typedef {{el: HTMLElement, observer?: MutationObserver, revision?: number, disposed?: boolean, sources?: Map<HTMLElement, string>}} HandbookHook */
let sequence = 0;
/**
 * @cc [owner:ghuntley,label:security] handbook-diagram-source
 * Only repository-authored Mermaid blocks inside the handbook may render.
 * Rendering MUST use strict mode without HTML labels, links or source directives.
 * Failed diagrams MUST retain their readable source; unmounted hooks cannot publish.
 */
/** @param {HandbookHook} hook @returns {Promise<void>} */
async function render(hook) {
  const revision = (hook.revision || 0) + 1;
  hook.revision = revision;
  const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "default";
  mermaid.initialize({startOnLoad: false, securityLevel: "strict", suppressErrorRendering: true,
    theme: "base", darkMode: theme === "dark", themeVariables: themeVariables(),
    flowchart: {htmlLabels: false}});
  for (const [pre, source] of hook.sources || []) {
    if (hook.disposed || hook.revision !== revision) return;
    try {
      if (/%%\{|\bclick\s|^---/m.test(source)) throw new Error("Unsupported diagram directive");
      const {svg} = await mermaid.render(`hldd-diagram-${++sequence}`, source);
      if (hook.disposed || hook.revision !== revision) return;
      pre.classList.add("hldd-diagram");
      pre.innerHTML = svg;
      pre.setAttribute("aria-label", t("Design diagram; explanation follows in the handbook"));
    } catch {
      if (hook.disposed || hook.revision !== revision) return;
      pre.classList.remove("hldd-diagram");
      pre.textContent = t("Diagram unavailable. Source:\n%{source}", {source});
    }
  }
  if (!hook.disposed && hook.revision === revision) hook.el.dataset.hlddRenderedTheme = theme;
}

export const Handbook = {
  /** @this {HandbookHook} */
  mounted() {
    this.sources = new Map();
    this.el.querySelectorAll("pre > code.mermaid").forEach(code => {
      const pre = code.parentElement;
      if (pre) this.sources?.set(pre, code.textContent || "");
    });
    void render(this);
    this.observer = new MutationObserver(() => { void render(this); });
    this.observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]});
  },
  /** @this {HandbookHook} */
  destroyed() {
    this.disposed = true;
    this.observer?.disconnect();
    this.sources?.clear();
  },
};
