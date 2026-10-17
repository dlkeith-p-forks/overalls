// @ts-check

/** @typedef {{el: HTMLElement, pushEvent: (event: string, payload: Record<string, unknown>) => void, handleEvent: (event: string, callback: (payload: unknown) => void) => void, controller?: AbortController, composer?: HTMLTextAreaElement, returnFocus?: HTMLElement, choice: number, composing: boolean, detailDialogOpen?: boolean}} ComposerHook */

/**
 * @cc [owner:ghuntley,label:product] composer-command-prefix
 * A command MUST begin at the first character. Leading whitespace preserves
 * literal text, and completion MUST NOT submit a form or create a thread.
 * @param {string} value
 * @returns {string | null}
 */
export function commandPrefix(value) {
  return /^\/[a-z]*$/.test(value) ? value.slice(1) : null;
}

/** @param {ComposerHook} hook @returns {void} */
function refreshCommandAvailability(hook) {
  const state = hook.el.dataset;
  hook.el.querySelectorAll("button[data-thread-command]").forEach(button => {
    if (!(button instanceof HTMLButtonElement)) return;
    const command = button.dataset.threadCommand;
    let allowed = command === "help";
    if (command === "plan" || command === "work") allowed = state.threadNew === "true" || (state.threadWrite === "true" && state.threadReady === "true" && state.threadBusy !== "true");
    if (command === "context" || command === "skills") allowed = state.threadSelected === "true";
    if (command === "compact") allowed = state.threadWrite === "true" && state.threadReady === "true" && state.threadBusy !== "true";
    if (command === "share") allowed = state.threadManage === "true";
    if (command === "terminal") allowed = state.threadWrite === "true" && state.threadReady === "true";
    if (command === "code") allowed = state.threadEditor === "true";
    button.disabled = !allowed;
  });
}

/** @param {ComposerHook} hook @returns {HTMLDialogElement | null} */
function palette(hook) {
  return hook.el.querySelector("#thread-command-palette");
}

/** @param {ComposerHook} hook @returns {HTMLButtonElement[]} */
function choices(hook) {
  const container = palette(hook)?.open ? palette(hook) : hook.el.querySelector("[data-thread-completions]:not([hidden])") || hook.el.querySelector("#thread-skill-suggestions");
  return container ? Array.from(container.querySelectorAll("button[data-thread-command]:not([hidden]):not([disabled]), button[data-thread-skill]:not([disabled])")) : [];
}

/** @param {ComposerHook} hook @returns {void} */
function highlight(hook) {
  const buttons = choices(hook);
  hook.choice = Math.max(0, Math.min(hook.choice, buttons.length - 1));
  buttons.forEach((button, index) => {
    button.setAttribute("aria-selected", String(index === hook.choice));
    if (index === hook.choice) {
      const input = palette(hook)?.open ? hook.el.querySelector("#thread-command-search") : hook.composer;
      input?.setAttribute("aria-activedescendant", button.id);
    }
  });
}

/** @param {ComposerHook} hook @returns {void} */
function hideCompletions(hook) {
  hook.el.querySelectorAll("[data-thread-completions]").forEach(el => el.setAttribute("hidden", ""));
  hook.composer?.setAttribute("aria-expanded", "false");
  hook.composer?.removeAttribute("aria-activedescendant");
}

/** @param {ComposerHook} hook @param {string} query @returns {void} */
function filter(hook, query) {
  const container = palette(hook)?.open ? palette(hook) : hook.el.querySelector("[data-thread-completions]");
  container?.querySelectorAll("button[data-thread-command]").forEach(button => {
    if (button instanceof HTMLButtonElement) button.hidden = !button.dataset.threadCommand?.startsWith(query.toLowerCase().replace(/^\//, ""));
  });
  hook.choice = 0;
  highlight(hook);
}

/** @param {ComposerHook} hook @param {HTMLElement | undefined} trigger @returns {void} */
function openPalette(hook, trigger) {
  const dialog = palette(hook);
  if (!dialog) return;
  hook.returnFocus = trigger;
  hideCompletions(hook);
  dialog.showModal();
  const search = dialog.querySelector("input");
  if (search) { search.value = ""; search.focus(); }
  filter(hook, "");
}

/** @param {ComposerHook} hook @returns {void} */
function closePalette(hook) {
  palette(hook)?.close();
  if (hook.returnFocus?.isConnected) hook.returnFocus.focus();
  else hook.composer?.focus();
}

/** @param {ComposerHook} hook @param {string} command @param {boolean} complete @returns {void} */
function activate(hook, command, complete) {
  const input = hook.composer || hook.el.querySelector("textarea[data-thread-input]");
  if (complete && input instanceof HTMLTextAreaElement) {
    input.value = `/${command} `;
    input.dispatchEvent(new Event("input", {bubbles: true}));
    input.focus();
  } else {
    hook.pushEvent("thread_command", {command});
  }
  hideCompletions(hook);
  if (palette(hook)?.open) closePalette(hook);
}

/**
 * @cc [owner:ghuntley,label:product;security] composer-browser-controls
 * Keyboard shortcuts MUST be scoped to the composer or its dialog, preserve
 * drafts on Escape, and ignore IME composition. Browser actions MUST only send
 * command identities; the server rechecks permission and operation eligibility.
 */
export const ThreadComposer = {
  /** @this {ComposerHook} @returns {void} */
  mounted() {
    this.controller = new AbortController();
    this.choice = 0;
    this.composing = false;
    refreshCommandAvailability(this);
    const signal = this.controller.signal;
    this.el.addEventListener("compositionstart", () => { this.composing = true; }, {signal});
    this.el.addEventListener("compositionend", () => { this.composing = false; }, {signal});
    this.el.addEventListener("focusin", event => {
      if (event.target instanceof HTMLTextAreaElement && event.target.matches("[data-thread-input]")) this.composer = event.target;
    }, {signal});
    this.el.addEventListener("input", event => {
      const target = event.target;
      if (this.composing) return;
      if (target instanceof HTMLInputElement && target.id === "thread-command-search") {
        filter(this, target.value); return;
      }
      if (!(target instanceof HTMLTextAreaElement) || !target.matches("[data-thread-input]")) return;
      this.composer = target;
      const prefix = commandPrefix(target.value);
      hideCompletions(this);
      if (prefix !== null) {
        this.el.querySelector("[data-thread-completions]")?.removeAttribute("hidden");
        target.setAttribute("aria-expanded", "true");
        filter(this, prefix);
      }
      if (/(?:^|\s)\$[^\s]*$/.test(target.value)) this.pushEvent("skill_search", {query: target.value.split("$").at(-1) || ""});
    }, {signal});
    this.el.addEventListener("click", event => {
      const target = event.target instanceof Element ? event.target.closest("button") : null;
      if (!(target instanceof HTMLButtonElement)) return;
      if (target.hasAttribute("data-thread-commands-open")) openPalette(this, target);
      if (target.hasAttribute("data-thread-commands-close")) closePalette(this);
      const command = target.dataset.threadCommand;
      if (command && !target.disabled) activate(this, command, false);
    }, {signal});
    this.el.addEventListener("keydown", event => {
      if (this.composing || event.isComposing) return;
      const target = event.target;
      const inComposer = target instanceof HTMLTextAreaElement && target.matches("[data-thread-input]");
      const inPalette = palette(this)?.open && target instanceof Node && palette(this)?.contains(target);
      if (!inComposer && !inPalette) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && inComposer) {
        event.preventDefault(); openPalette(this, target); return;
      }
      const buttons = choices(this);
      if (event.key === "Escape") {
        if (inPalette) { event.preventDefault(); closePalette(this); }
        else { hideCompletions(this); this.pushEvent("dismiss_skill_search", {}); }
        return;
      }
      if (!buttons.length) return;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.choice = (this.choice + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
        highlight(this);
      } else if (event.key === "Enter" || (event.key === "Tab" && !inPalette)) {
        event.preventDefault();
        const selected = target instanceof HTMLButtonElement ? target : buttons[this.choice];
        const command = selected?.dataset.threadCommand;
        const skill = selected?.dataset.threadSkill;
        if (command) activate(this, command, event.key === "Tab");
        if (skill) this.pushEvent("select_skill", {id: skill});
      }
    }, {signal});
    palette(this)?.addEventListener("cancel", event => { event.preventDefault(); closePalette(this); }, {signal});
    this.handleEvent("thread-composer-clear", () => {
      this.el.querySelectorAll("textarea[data-thread-input]").forEach(input => {
        if (input instanceof HTMLTextAreaElement) { input.value = ""; input.dispatchEvent(new Event("input", {bubbles: true})); }
      });
      hideCompletions(this);
    });
    this.handleEvent("thread-skill-selected", () => {
      if (!this.composer) return;
      this.composer.value = this.composer.value.replace(/(^|\s)\$[^\s]*$/, "$1");
      this.composer.dispatchEvent(new Event("input", {bubbles: true}));
      this.composer.focus();
    });
    this.handleEvent("thread-focus-composer", () => {
      const input = this.el.querySelector("textarea[data-thread-input]");
      if (input instanceof HTMLTextAreaElement) input.focus();
    });
  },
  /** @this {ComposerHook} @returns {void} */
  updated() {
    refreshCommandAvailability(this);
    const dialog = this.el.querySelector("dialog[data-thread-dialog]");
    if (dialog instanceof HTMLDialogElement && !dialog.open) {
      this.returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : this.composer;
      this.detailDialogOpen = true;
      dialog.showModal();
      dialog.addEventListener("cancel", event => {
        event.preventDefault();
        this.pushEvent("close_thread_dialog", {});
      }, {once: true});
    } else if (!dialog && this.detailDialogOpen) {
      this.detailDialogOpen = false;
      if (this.returnFocus?.isConnected) this.returnFocus.focus();
      else this.composer?.focus();
    }
    if (this.el.querySelector("#thread-skill-suggestions")) highlight(this);
  },
  /** @this {ComposerHook} @returns {void} */
  destroyed() { this.controller?.abort(); },
};
