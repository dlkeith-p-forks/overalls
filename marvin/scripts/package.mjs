import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { deflateRawSync } from "node:zlib";
import { buildEpoch, packageVersion, sourceDigest, sourceRoot } from "./build.mjs";
import { crc32 } from "./icons.mjs";

/** @typedef {{name:string,bytes:Buffer}} Entry */
/**
 * @cc [owner:ghuntley,label:build] marvin-deterministic-zip
 * ZIP entries MUST be sorted regular files with fixed UTC DOS timestamps,
 * Unix mode 0644, no extra metadata, and stable level-nine raw deflate.
 */
/**
 * @param {Entry[]} entries @param {number} epoch @returns {Buffer}
 */
export function archive(entries, epoch) {
  const date = new Date(epoch*1000);
  const time = (date.getUTCHours()<<11)|(date.getUTCMinutes()<<5)|(date.getUTCSeconds()>>1);
  const day = ((date.getUTCFullYear()-1980)<<9)|((date.getUTCMonth()+1)<<5)|date.getUTCDate();
  /** @type {Buffer[]} */ const local = [];
  /** @type {Buffer[]} */ const central = [];
  let offset = 0;
  const sorted = [...entries].sort((a,b)=>a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  if (new Set(sorted.map(e=>e.name)).size !== sorted.length) throw new Error("Duplicate archive entry");
  for (const entry of sorted) {
    if (!/^[a-zA-Z0-9_.\/-]+$/.test(entry.name) || entry.name.startsWith("/") || entry.name.split("/").includes("..")) throw new Error("Unsafe archive entry");
    const name = Buffer.from(entry.name);
    const compressed = deflateRawSync(entry.bytes,{level:9});
    const checksum = crc32(entry.bytes);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50,0); header.writeUInt16LE(20,4); header.writeUInt16LE(8,8);
    header.writeUInt16LE(time,10); header.writeUInt16LE(day,12); header.writeUInt32LE(checksum,14);
    header.writeUInt32LE(compressed.length,18); header.writeUInt32LE(entry.bytes.length,22); header.writeUInt16LE(name.length,26);
    local.push(header,name,compressed);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50,0); record.writeUInt16LE(0x0314,4); record.writeUInt16LE(20,6);
    record.writeUInt16LE(8,10); record.writeUInt16LE(time,12); record.writeUInt16LE(day,14); record.writeUInt32LE(checksum,16);
    record.writeUInt32LE(compressed.length,20); record.writeUInt32LE(entry.bytes.length,24); record.writeUInt16LE(name.length,28);
    record.writeUInt32LE(0x81a40000,38); record.writeUInt32LE(offset,42); central.push(record,name);
    offset += header.length+name.length+compressed.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50,0); end.writeUInt16LE(sorted.length,8); end.writeUInt16LE(sorted.length,10);
  end.writeUInt32LE(directory.length,12); end.writeUInt32LE(offset,16);
  return Buffer.concat([...local,directory,end]);
}

/** @param {string} root @returns {Promise<Entry[]>} */
async function entries(root) {
  /** @type {Entry[]} */ const result=[];
  /** @param {string} directory @returns {Promise<void>} */
  async function visit(directory) {
    for (const entry of await readdir(join(root,directory),{withFileTypes:true})) {
      const name = join(directory,entry.name);
      if (entry.isDirectory()) await visit(name);
      else if (entry.isFile()) result.push({name,bytes:await readFile(join(root,name))});
      else throw new Error("Archive entries must be regular files");
    }
  }
  await visit(""); return result;
}

/** @param {string} root @param {string} destination @param {number} epoch @returns {Promise<void>} */
export async function packageArchives(root,destination,epoch) {
  await mkdir(join(destination,"bin"),{recursive:true});
  /** @type {Record<string,{sha256:string,size:number}>} */ const artifacts={};
  for (const [platform,filename] of /** @type {const} */ ([["chrome","chrome.zip"],["firefox","firefox.xpi"]])) {
    const bytes=archive(await entries(join(destination,platform)),epoch);
    await writeFile(join(destination,"bin",filename),bytes);
    artifacts[filename]={sha256:createHash("sha256").update(bytes).digest("hex"),size:bytes.length};
  }
  const manifest={version:1,extension_version:await packageVersion(root),source_sha256:await sourceDigest(root),build_timestamp:new Date(epoch*1000).toISOString(),unsigned:true,artifacts};
  await writeFile(join(destination,"manifest.json"),JSON.stringify(manifest,null,2)+"\n");
}
if (process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) await packageArchives(sourceRoot,join(sourceRoot,"dist"),buildEpoch(process.env.SOURCE_DATE_EPOCH));
