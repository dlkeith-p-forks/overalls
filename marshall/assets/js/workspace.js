// @ts-check
/**
 * @cc [owner:ghuntley,label:accessibility] workspace-drawer-focus
 * The mobile drawer MUST contain keyboard focus while open, close on Escape or
 * navigation, restore focus on dismissal, and release listeners on destruction.
 */
export const WorkspaceNavigation = {
  /** @this {{el: HTMLElement, cleanup?: () => void}} */
  mounted() {
    const sidebar = this.el.querySelector("#workspace-sidebar");
    const opener = this.el.querySelector("#navigation-open");
    const closer = this.el.querySelector("#navigation-close");
    const backdrop = this.el.querySelector("#navigation-backdrop");
    if (!(sidebar instanceof HTMLElement) || !(opener instanceof HTMLElement) ||
        !(closer instanceof HTMLElement) || !(backdrop instanceof HTMLElement)) return;
    const mobile = window.matchMedia("(max-width: 800px)");
    const focusable = () => Array.from(sidebar.querySelectorAll("a, button, select, summary"))
      .filter((node) => node instanceof HTMLElement && node.getClientRects().length > 0);
    /** @param {boolean} opened @param {boolean} [restore] */
    const setOpen = (opened, restore = true) => {
      sidebar.toggleAttribute("data-open", opened);
      opener.setAttribute("aria-expanded", String(opened));
      backdrop.hidden = !opened;
      document.body.style.overflow = opened ? "hidden" : "";
      if (opened) closer.focus();
      else if (restore && mobile.matches) opener.focus();
    };
    /** @param {Event} event */
    const click = (event) => {
      if (!(event.target instanceof Element)) return;
      if (opener.contains(event.target)) setOpen(true);
      else if (closer.contains(event.target) || backdrop.contains(event.target)) setOpen(false);
      else if (event.target.closest("a") && sidebar.hasAttribute("data-open")) setOpen(false, false);
    };
    /** @param {KeyboardEvent} event */
    const key = (event) => {
      if (!sidebar.hasAttribute("data-open")) return;
      if (event.key === "Escape") { event.preventDefault(); setOpen(false); }
      if (event.key !== "Tab") return;
      const items = focusable();
      const first = items[0], last = items.at(-1);
      if (event.shiftKey && document.activeElement === first && last instanceof HTMLElement) {
        event.preventDefault(); last.focus();
      } else if (!event.shiftKey && document.activeElement === last && first instanceof HTMLElement) {
        event.preventDefault(); first.focus();
      }
    };
    const resize = () => { if (!mobile.matches) setOpen(false, false); };
    const navigate = () => setOpen(false, false);
    this.el.addEventListener("click", click);
    document.addEventListener("keydown", key);
    mobile.addEventListener("change", resize);
    window.addEventListener("phx:page-loading-start", navigate);
    this.cleanup = () => {
      setOpen(false, false);
      this.el.removeEventListener("click", click);
      document.removeEventListener("keydown", key);
      mobile.removeEventListener("change", resize);
      window.removeEventListener("phx:page-loading-start", navigate);
    };
  },
  /** @this {{cleanup?: () => void}} */
  destroyed() { this.cleanup?.(); },
};

/** Copy only the displayed authorized command, with accessible success/failure feedback. */
export const MachineConnection = {
  /** @this {{el: HTMLElement, cleanup?: () => void}} */
  mounted() {
    /** @param {Event} event */
    const click = async (event) => {
      if (!(event.target instanceof Element)) return;
      const button = event.target.closest("[data-copy-command]");
      const id = button?.getAttribute("data-copy-command");
      if (!id) return;
      const command = this.el.querySelector(`#${CSS.escape(id)}`)?.textContent;
      const status = this.el.querySelector("#machine-copy-status");
      if (!command || !status) return;
      try {
        await navigator.clipboard.writeText(command);
        status.textContent = "Command copied.";
      } catch {
        status.textContent = "Could not copy. Select the command and copy it manually.";
      }
    };
    this.el.addEventListener("click", click);
    this.cleanup = () => this.el.removeEventListener("click", click);
  },
  /** @this {{cleanup?: () => void}} */
  destroyed() { this.cleanup?.(); },
};
