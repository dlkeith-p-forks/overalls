const supportedHosts = new Set(["github.com", "gitlab.com", "codeberg.org", "bitbucket.org"]);

/** @param {string} value @returns {boolean} */
export function supportedSourceUrl(value) {
  if (!value.startsWith("https://") || /^https:\/\/[^/?#]*@/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password &&
      (url.port === "" || url.port === "443") && supportedHosts.has(url.hostname);
  } catch {
    return false;
  }
}

/**
 * @cc [owner:ghuntley,label:security] marvin-server-origin
 * Settings MUST select an HTTPS origin or HTTP loopback origin without
 * credentials, query, fragment or a non-root path; there MUST be no default.
 */
/**
 * @param {string} value
 * @returns {string}
 */
export function normalizeServerUrl(value) {
  const url = new URL(value.trim());
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) ||
      url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("Enter an HTTPS server origin, or an HTTP loopback origin for development.");
  }
  return `${url.origin}/`;
}

/**
 * @cc [owner:ghuntley,label:security] marvin-source-url-minimization
 * Launch URLs MUST retain only the validated provider origin and page
 * path. Source queries and fragments MUST NOT be transmitted or retained in
 * the launch fragment, because they do not identify the checkout and may carry
 * credentials. User-info URLs MUST remain unsupported. Origin/path spelling
 * MUST remain unchanged so the server can refuse explicit ports or traversal.
 */
/** @param {string} serverUrl @param {string} sourceUrl @returns {string} */
export function overallsLaunchUrl(serverUrl, sourceUrl) {
  if (!supportedSourceUrl(sourceUrl)) throw new Error("This page is not hosted by a supported Git provider.");
  const source = sourceUrl.replace(/[?#].*$/s, "");
  return `${normalizeServerUrl(serverUrl)}launch/entry#${source}`;
}
