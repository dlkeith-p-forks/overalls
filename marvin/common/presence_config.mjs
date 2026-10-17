import { normalizeServerUrl } from "./launch.mjs";

/** @typedef {import('../types/api.js').ExtensionApi} ExtensionApi */
/** @typedef {import('../types/api.js').ContentScriptRegistration} ContentScriptRegistration */

const SCRIPT_FILE = "presence.mjs";

/** @param {string} serverUrl @returns {string} */
export function presenceMatchPattern(serverUrl) {
  const normalized = normalizeServerUrl(serverUrl);
  const origin = new URL(normalized);
  return `${origin.protocol}//${origin.host}/*`;
}

/** @param {string} serverUrl @returns {string} */
export function presenceRegistrationId(serverUrl) {
  const normalized = normalizeServerUrl(serverUrl);
  // Keep IDs bounded for browsers that impose a registration-ID length limit;
  // the exact origin remains enforced by the registration's `matches` field.
  let hash = 14695981039346656037n;
  const mask = 18446744073709551615n;
  for (const byte of new TextEncoder().encode(normalized)) {
    hash = ((hash ^ BigInt(byte)) * 1099511628211n) & mask;
  }
  return `overalls-presence-${hash.toString(16).padStart(16, "0")}`;
}

/** @param {string | undefined} serverUrl @returns {string | undefined} */
function registrationId(serverUrl) {
  if (typeof serverUrl !== "string") return undefined;
  try {
    return presenceRegistrationId(serverUrl);
  } catch {
    return undefined;
  }
}

/** @param {ExtensionApi} api @param {string} pattern @param {boolean} requestPermission @returns {Promise<void>} */
async function requirePermission(api, pattern, requestPermission) {
  // A permission request must be made directly from the settings form's user
  // activation. Awaiting `contains` first can consume that activation in
  // Chromium, which then rejects an otherwise valid request.
  if (requestPermission && await api.permissions.request({ origins: [pattern] })) return;
  if (await api.permissions.contains({ origins: [pattern] })) return;
  throw new Error("Allow access to this Overalls origin to enable browser extension detection.");
}

/** @param {ExtensionApi} api @param {string} serverUrl @returns {Promise<void>} */
async function injectExistingTabs(api, serverUrl) {
  const expectedOrigin = new URL(normalizeServerUrl(serverUrl)).origin;
  let tabs;
  try {
    tabs = await api.tabs.query({});
  } catch {
    return;
  }
  await Promise.all(tabs.flatMap((tab) => {
    if (tab.id === undefined || typeof tab.url !== "string") return [];
    try {
      if (new URL(tab.url).origin !== expectedOrigin) return [];
    } catch {
      return [];
    }
    return [api.scripting.executeScript({ target: { tabId: tab.id }, files: [SCRIPT_FILE] }).catch(() => {})];
  }));
}

/**
 * @cc [owner:ghuntley,label:security] marvin-presence-registration
 * Dynamic detector registration MUST match only the normalized configured
 * server origin, run at document start, and require that origin's optional
 * host permission. A failed permission request or registration MUST reject
 * before settings are changed.
 */
/**
 * @param {ExtensionApi} api
 * @param {string} serverUrl
 * @param {string | undefined} previousServerUrl
 * @param {boolean} requestPermission
 * @returns {Promise<string>}
 */
export async function configurePresence(api, serverUrl, previousServerUrl, requestPermission) {
  const normalized = normalizeServerUrl(serverUrl);
  const pattern = presenceMatchPattern(normalized);
  await requirePermission(api, pattern, requestPermission);
  const id = presenceRegistrationId(normalized);
  const oldId = registrationId(previousServerUrl);
  if (oldId === id) {
    await injectExistingTabs(api, normalized);
    return normalized;
  }
  /** @type {ContentScriptRegistration} */
  const registration = {
    id,
    matches: [pattern],
    js: [SCRIPT_FILE],
    runAt: "document_start",
    persistAcrossSessions: true,
  };
  // Replacing an existing registration for this origin is idempotent. A
  // previous origin remains registered until the new one has succeeded.
  await api.scripting.unregisterContentScripts({ ids: [id] }).catch(() => {});
  await api.scripting.registerContentScripts([registration]);
  await injectExistingTabs(api, normalized);
  if (oldId !== undefined && oldId !== id) {
    await api.scripting.unregisterContentScripts({ ids: [oldId] }).catch(() => {});
  }
  return normalized;
}

/**
 * Restore a stored detector without prompting. Browser startup and extension
 * installation cannot provide a permission prompt user gesture.
 * @param {ExtensionApi} api @param {string | undefined} serverUrl @returns {Promise<void>}
 */
export async function restorePresence(api, serverUrl) {
  if (typeof serverUrl !== "string") return;
  await configurePresence(api, serverUrl, undefined, false);
}
