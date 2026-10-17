import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";
import { build, buildEpoch, sourceRoot } from "./build.mjs";
import { archive, packageArchives } from "./package.mjs";

/** @param {Buffer} bytes @returns {Map<string,Buffer>} */
function unpack(bytes) {
  /** @type {Map<string,Buffer>} */ const entries=new Map();
  let offset=0;
  while(bytes.readUInt32LE(offset)===0x04034b50) {
    const nameLength=bytes.readUInt16LE(offset+26);
    const compressedSize=bytes.readUInt32LE(offset+18);
    const start=offset+30+nameLength;
    const name=bytes.subarray(offset+30,start).toString();
    entries.set(name,inflateRawSync(bytes.subarray(start,start+compressedSize)));
    offset=start+compressedSize;
  }
  return entries;
}

test("archives are deterministic independent of input order and reject traversal",()=>{
  const a={name:"a.txt",bytes:Buffer.from("a")}, b={name:"b.txt",bytes:Buffer.from("b")};
  assert.deepEqual(archive([a,b],315532800),archive([b,a],315532800));
  assert.deepEqual(unpack(archive([b,a],315532800)),new Map([["a.txt",a.bytes],["b.txt",b.bytes]]));
  assert.throws(()=>archive([{name:"../escape",bytes:Buffer.alloc(0)}],315532800));
  assert.throws(()=>archive([a,a],315532800));
  assert.throws(()=>buildEpoch("invalid")); assert.throws(()=>buildEpoch("0"));
});

test("both packages agree with the version authority and have narrow permissions",async()=>{
  const temporary=await mkdtemp(join(tmpdir(),"overalls-browser-package-"));
  try {
    const destination=join(temporary,"dist");
    await build(sourceRoot,destination,315532800);
    await packageArchives(sourceRoot,destination,315532800);
    const chrome=await readFile(join(destination,"bin","chrome.zip"));
    await utimes(join(destination,"chrome","manifest.json"),new Date(),new Date());
    await packageArchives(sourceRoot,destination,315532800);
    assert.deepEqual(await readFile(join(destination,"bin","chrome.zip")),chrome);
    for (const name of ["chrome.zip","firefox.xpi"]) {
      const entries=unpack(await readFile(join(destination,"bin",name)));
      assert.equal(entries.size,12);
      const manifestBytes=entries.get("manifest.json"); assert.ok(manifestBytes);
      /** @type {unknown} */ const manifest=JSON.parse(manifestBytes.toString());
      assert.ok(typeof manifest==="object" && manifest!==null && "version" in manifest && "permissions" in manifest && "host_permissions" in manifest);
      assert.equal(manifest.version,"0.1.0");
      assert.deepEqual(manifest.permissions,["activeTab","storage","contextMenus"]);
      assert.deepEqual(manifest.host_permissions,["https://github.com/*","https://gitlab.com/*","https://codeberg.org/*","https://bitbucket.org/*"]);
      assert.equal([...entries.keys()].some(value=>value.includes("node_modules")||value.endsWith(".test.mjs")),false);
      const icon=entries.get("icons/supported-32.png"); assert.ok(icon);
      assert.equal(icon.readUInt32BE(16),32); assert.equal(icon.readUInt32BE(20),32);
    }
  } finally {await rm(temporary,{recursive:true,force:true});}
});
