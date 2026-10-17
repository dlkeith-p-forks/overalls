import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { markPng } from "./icons.mjs";

export const sourceRoot = resolve(import.meta.dirname, "..");
/** @typedef {'chrome'|'firefox'} Platform */
/** @typedef {{version: string, source_sha256: string, build_timestamp: string, platform: string}} BuildInfo */

/** @param {string} root @returns {Promise<string[]>} */
export async function sourceFiles(root) {
  /** @type {string[]} */
  const files = [];
  /** @param {string} directory @returns {Promise<void>} */
  async function visit(directory) {
    for (const entry of await readdir(join(root, directory), { withFileTypes: true })) {
      if (["dist", "node_modules"].includes(entry.name)) continue;
      const name = join(directory, entry.name);
      if (entry.isDirectory()) await visit(name);
      else if (entry.isFile()) files.push(name);
      else throw new Error("Browser source must contain only regular files and directories");
    }
  }
  await visit("");
  return files.sort();
}

/** @param {string} root @returns {Promise<string>} */
export async function sourceDigest(root) {
  const hash = createHash("sha256");
  for (const name of await sourceFiles(root)) {
    hash.update(name).update("\0").update(createHash("sha256").update(await readFile(join(root, name))).digest()).update("\0");
  }
  return hash.digest("hex");
}

/** @param {string} root @returns {Promise<string>} */
export async function packageVersion(root) {
  /** @type {unknown} */
  const data = JSON.parse(await readFile(join(root,"package.json"),"utf8"));
  if (typeof data !== "object" || data === null || !("version" in data) || typeof data.version !== "string" || !/^\d+\.\d+\.\d+$/.test(data.version)) {
    throw new Error("Browser package version must be a release version");
  }
  return data.version;
}

/** @param {string | undefined} value @returns {number} */
export function buildEpoch(value) {
  const epoch = value === undefined ? 315532800 : Number(value);
  if (!Number.isSafeInteger(epoch) || epoch < 315532800 || epoch > 4354819199) throw new Error("SOURCE_DATE_EPOCH must fit ZIP's 1980–2107 timestamp range");
  return epoch;
}

/** @param {string} root @param {string} destination @param {number} epoch @returns {Promise<void>} */
export async function build(root, destination, epoch) {
  const version = await packageVersion(root);
  const digest = await sourceDigest(root);
  await rm(destination, { recursive: true, force: true });
  for (const platform of /** @type {const} */ (["chrome", "firefox"])) {
    const output = join(destination,platform);
    await mkdir(join(output,"common"),{recursive:true});
    await mkdir(join(output,"icons"),{recursive:true});
    for (const name of ["extension.mjs","launch.mjs"]) await writeFile(join(output,"common",name),await readFile(join(root,"common",name)));
    for (const name of ["background.mjs","options.mjs","options.html","options.css"]) {
      const contents = (await readFile(join(root,"common",name),"utf8")).replace('from "./extension.mjs"','from "./common/extension.mjs"').replace('from "./launch.mjs"','from "./common/launch.mjs"');
      await writeFile(join(output,name),contents);
    }
    const manifest = {
      manifest_version: 3, name: "Open in Overalls", version,
      description: "Open a hosted Git repository page in a Overalls workspace.",
      permissions: ["activeTab","storage","contextMenus"],
      host_permissions: ["https://github.com/*","https://gitlab.com/*","https://codeberg.org/*","https://bitbucket.org/*"],
      action: { default_title: "Open in Overalls (unsupported page)", default_icon: { 16: "icons/unsupported-16.png", 32: "icons/unsupported-32.png" } },
      background: platform === "chrome" ? { service_worker: "background.mjs", type: "module" } : { scripts: ["background.mjs"], type: "module" },
      options_ui: { page: "options.html", open_in_tab: true },
      ...(platform === "firefox" ? { browser_specific_settings: { gecko: { id: "open-in-overalls@ghuntley.dev", strict_min_version: "140.0", data_collection_permissions: {required:["none"]} }, gecko_android: {strict_min_version:"142.0"} } } : {}),
    };
    /** @type {BuildInfo} */
    const info = {version,source_sha256:digest,build_timestamp:new Date(epoch*1000).toISOString(),platform:`browser-${platform}`};
    await writeFile(join(output,"manifest.json"),JSON.stringify(manifest,null,2)+"\n");
    await writeFile(join(output,"build-info.json"),JSON.stringify(info,null,2)+"\n");
    for (const size of [16,32]) for (const supported of [true,false]) await writeFile(join(output,"icons",`${supported?"supported":"unsupported"}-${size}.png`),markPng(size,supported));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await build(sourceRoot,join(sourceRoot,"dist"),buildEpoch(process.env.SOURCE_DATE_EPOCH));
}
