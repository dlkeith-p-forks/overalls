import assert from "node:assert/strict";
import { test } from "node:test";
import vm from "node:vm";
import { readFile } from "node:fs/promises";

test("packaged detector is standalone and sets the stable marker",async()=>{
  const source=await readFile(new URL("./presence.mjs",import.meta.url),"utf8");
  assert.equal(source.includes("import "),false);
  /** @type {{dataset:Record<string,string>}} */ const root={dataset:{}};
  vm.runInNewContext(source,{document:{documentElement:root,addEventListener:()=>{}},TextEncoder});
  assert.equal(root.dataset.overallsBrowserExtension,"installed");
});
