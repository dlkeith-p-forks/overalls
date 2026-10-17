import { supportedSourceUrl, overallsLaunchUrl } from "./launch.mjs";
import { restorePresence } from "./presence_config.mjs";

/** @typedef {import('../types/api.js').ExtensionApi} ExtensionApi */
/** @typedef {import('../types/api.js').Tab} Tab */
const MENU_ID = "configure-overalls-server";
const ICONS = {
  supported: { 16: "icons/supported-16.png", 32: "icons/supported-32.png" },
  unsupported: { 16: "icons/unsupported-16.png", 32: "icons/unsupported-32.png" },
};

/** @param {ExtensionApi} api @returns {void} */
export function installExtension(api) {
  api.runtime.onInstalled.addListener(() => {
    void api.contextMenus.removeAll().then(() => api.contextMenus.create({
      id: MENU_ID, title: "Configure Overalls server…", contexts: ["action"],
    })).catch(() => {});
    void refreshActiveTab(api);
    void restoreStoredPresence(api);
  });
  api.runtime.onStartup.addListener(() => {
    void refreshActiveTab(api);
    void restoreStoredPresence(api);
  });
  api.tabs.onActivated.addListener(({ tabId }) => { void refreshTab(api, tabId); });
  api.tabs.onUpdated.addListener((_tabId, change, tab) => {
    if (change.url !== undefined || change.status !== undefined) void updateAction(api, tab).catch(() => {});
  });
  api.contextMenus.onClicked.addListener((info) => {
    if (info.menuItemId === MENU_ID) void api.runtime.openOptionsPage();
  });
  api.action.onClicked.addListener((tab) => { void launchActiveTab(api, tab).catch(() => {}); });
}

/** @param {ExtensionApi} api @returns {Promise<void>} */
async function restoreStoredPresence(api) {
  try {
    const stored = await api.storage.sync.get("overallsServerUrl");
    await restorePresence(api, typeof stored.overallsServerUrl === "string" ? stored.overallsServerUrl : undefined);
  } catch {
    // A missing optional permission or malformed setting leaves the extension
    // usable; the settings page can request access after an explicit save.
  }
}

/**
 * @cc [owner:ghuntley,label:security] marvin-active-tab-grant
 * An existing tab whose URL is withheld MUST keep its action enabled so an
 * explicit click can grant activeTab. Unknown toolbar state MUST NOT transmit
 * anything; launchActiveTab MUST still validate the click's observed URL.
 */
/** @param {ExtensionApi} api @param {Tab | undefined} tab @returns {Promise<'unknown'|'supported'|'unsupported'>} */
export async function updateAction(api, tab) {
  if (tab?.id === undefined) return "unknown";
  const known = typeof tab.url === "string";
  const supported = typeof tab.url === "string" && supportedSourceUrl(tab.url);
  await api.action.setIcon({ tabId: tab.id, path: ICONS[supported ? "supported" : "unsupported"] });
  await api.action.setTitle({ tabId: tab.id, title: supported || !known ? "Open in Overalls" : "Open in Overalls (unsupported page)" });
  await api.action[supported || !known ? "enable" : "disable"](tab.id);
  return known ? (supported ? "supported" : "unsupported") : "unknown";
}

/** @param {ExtensionApi} api @param {number} tabId @returns {Promise<void>} */
async function refreshTab(api, tabId) {
  try { await updateAction(api, await api.tabs.get(tabId)); } catch { /* Tab may have closed. */ }
}

/** @param {ExtensionApi} api @returns {Promise<void>} */
async function refreshActiveTab(api) {
  try { await updateAction(api, (await api.tabs.query({ active: true, currentWindow: true }))[0]); }
  catch { /* No active tab is available during browser shutdown. */ }
}

/** @param {ExtensionApi} api @param {Tab} tab @returns {Promise<'unsupported'|'unconfigured'|'opened'>} */
export async function launchActiveTab(api, tab) {
  if (typeof tab.url !== "string" || !supportedSourceUrl(tab.url)) {
    await showUnsupported(api, tab.id);
    return "unsupported";
  }
  const stored = await api.storage.sync.get("overallsServerUrl");
  let launch;
  try {
    if (typeof stored.overallsServerUrl !== "string") throw new Error("Unconfigured server");
    launch = overallsLaunchUrl(stored.overallsServerUrl, tab.url);
  } catch {
    await api.runtime.openOptionsPage();
    return "unconfigured";
  }
  await api.tabs.create({ url: launch });
  return "opened";
}

/**
 * @cc [owner:ghuntley,label:product] marvin-refused-click-feedback
 * An unsupported explicit click with a tab ID MUST show a temporary fixed
 * refusal badge and title without including the page URL or transmitting it.
 */
/** @param {ExtensionApi} api @param {number | undefined} tabId @returns {Promise<void>} */
async function showUnsupported(api, tabId) {
  if (tabId === undefined) return;
  await api.action.setBadgeBackgroundColor({ tabId, color: "#666666" });
  await api.action.setBadgeText({ tabId, text: "!" });
  await api.action.setTitle({ tabId, title: "Unsupported page" });
  setTimeout(() => {
    void api.action.setBadgeText({ tabId, text: "" }).then(() => refreshTab(api, tabId)).catch(() => {});
  }, 3000);
}
