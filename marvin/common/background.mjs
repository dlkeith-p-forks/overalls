import { installExtension } from "./extension.mjs";
const api = globalThis.browser ?? globalThis.chrome;
if (!api) throw new Error("Marvin extension API unavailable");
installExtension(api);
