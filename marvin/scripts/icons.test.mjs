import assert from "node:assert/strict";
import { test } from "node:test";
import { inflateSync } from "node:zlib";
import { markPng } from "./icons.mjs";

/** @param {Buffer} png @returns {{width:number,height:number,pixel:(x:number,y:number)=>[number,number,number,number]}} */
function decode(png) {
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  let offset = 8;
  /** @type {Buffer[]} */ const compressed = [];
  while (offset < png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.toString("ascii", offset + 4, offset + 8);
    if (type === "IDAT") compressed.push(png.subarray(offset + 8, offset + 8 + length));
    offset += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(compressed));
  return {
    width,
    height,
    pixel(x, y) {
      assert(x >= 0 && x < width && y >= 0 && y < height);
      const index = y * (width * 4 + 1) + 1 + x * 4;
      return /** @type {[number,number,number,number]} */ ([raw[index], raw[index + 1], raw[index + 2], raw[index + 3]]);
    },
  };
}

test("toolbar marks render the canonical overalls path in both states", () => {
  const supported = decode(markPng(32, true));
  const unsupported = decode(markPng(32, false));
  assert.equal(supported.width, 32);
  assert.equal(supported.height, 32);
  assert.deepEqual(supported.pixel(0, 0), [17, 17, 17, 255]);
  assert.deepEqual(supported.pixel(10, 5), [255, 255, 255, 255]);
  assert.deepEqual(supported.pixel(16, 5), [17, 17, 17, 255]);
  assert.deepEqual(unsupported.pixel(0, 0), [128, 128, 128, 255]);
  assert.deepEqual(unsupported.pixel(10, 5), [128, 128, 128, 255]);
  assert.equal(unsupported.pixel(16, 5)[3], 0);
});

test("toolbar mark accepts only packaged toolbar sizes", () => {
  assert.equal(decode(markPng(16, true)).width, 16);
  assert.equal(decode(markPng(16, false)).height, 16);
  assert.throws(() => markPng(24, true), /Unsupported icon size/);
});
