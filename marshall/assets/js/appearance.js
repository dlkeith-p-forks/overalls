// @ts-check
/**
 * @cc [owner:ghuntley,label:product] appearance-public-preference
 * Appearance MUST default to the system preference, persist explicit overrides
 * when storage is available, and work on session-free public documentation.
 * Unavailable storage MUST NOT prevent rendering or switching appearance.
 */
const media = window.matchMedia("(prefers-color-scheme: dark)");
let preference = "system";
try { preference = localStorage.getItem("phx:theme") || "system"; } catch {}
const apply = () => {
  if (!["system", "light", "dark"].includes(preference)) preference = "system";
  const theme = preference === "system" ? (media.matches ? "dark" : "light") : preference;
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themeSource = preference === "system" ? "system" : "user";
  document.querySelectorAll("[data-appearance]").forEach(select => { if (select instanceof HTMLSelectElement) select.value = preference; });
};
apply();
media.addEventListener("change", apply);
window.addEventListener("storage", event => {
  if (event.key === "phx:theme" || event.key === null) {
    preference = event.newValue || "system";
    apply();
  }
});
document.addEventListener("change", event => {
  if (!(event.target instanceof HTMLSelectElement) || !event.target.matches("[data-appearance]")) return;
  preference = event.target.value;
  try {
    if (preference === "system") localStorage.removeItem("phx:theme");
    else localStorage.setItem("phx:theme", preference);
  } catch {}
  apply();
});
window.addEventListener("phx:page-loading-stop", apply);
