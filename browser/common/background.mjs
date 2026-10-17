import { installExtension } from "./extension.mjs";
const api = globalThis.browser ?? globalThis.chrome;
if (!api) throw new Error("Browser extension API unavailable");
installExtension(api);
