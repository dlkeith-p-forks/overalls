import { deflateSync } from "node:zlib";

/** @param {Uint8Array} bytes @returns {number} */
export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** @param {string} type @param {Buffer} data @returns {Buffer} */
function chunk(type, data) {
  const name = Buffer.from(type);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([header, name, data, checksum]);
}

/**
 * A 5×7 bitmap "K" in the Monospace Web spirit: one character cell on a
 * bordered square, drawn in black and white so it reads on any toolbar.
 */
const GLYPH = [
  "#...#",
  "#..#.",
  "#.#..",
  "##...",
  "#.#..",
  "#..#.",
  "#...#",
];
const GLYPH_WIDTH = 5;
const GLYPH_HEIGHT = 7;

/**
 * @param {number} size
 * @param {boolean} supported
 * @returns {Buffer} a square PNG: filled with a white "K" when supported, an
 * outlined grey square with a grey "K" when the page is unsupported.
 */
export function markPng(size, supported) {
  if (![16, 32].includes(size)) throw new Error("Unsupported icon size");
  const border = size / 16;
  const scale = size === 16 ? 2 : 4;
  const left = Math.floor((size - GLYPH_WIDTH * scale) / 2);
  const top = Math.floor((size - GLYPH_HEIGHT * scale) / 2);
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const edge = x < border || y < border || x >= size - border || y >= size - border;
      const column = Math.floor((x - left) / scale);
      const row = Math.floor((y - top) / scale);
      const glyph = row >= 0 && row < GLYPH_HEIGHT && column >= 0 && column < GLYPH_WIDTH && GLYPH[row]?.[column] === "#";
      const offset = y * (size * 4 + 1) + 1 + x * 4;
      /** @type {[number, number]} value and alpha */
      const [value, alpha] = supported
        ? (glyph ? [255, 255] : [17, 255])
        : (edge || glyph ? [128, 255] : [128, 0]);
      raw[offset] = value;
      raw[offset + 1] = value;
      raw[offset + 2] = value;
      raw[offset + 3] = alpha;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
