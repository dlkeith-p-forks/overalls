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

/** @typedef {[number, number]} Point */
/** @typedef {[Point, Point]} Segment */

/**
 * The 32×32 overalls mark used by the web application. Keeping the path as
 * line segments lets the build render it without shipping an image library or
 * an external asset into the extension package.
 *
 * @type {Segment[]}
 */
const OVERALLS_SEGMENTS = [
  [[10, 2], [10, 9]], [[22, 2], [22, 9]],
  [[8, 9], [24, 9]], [[24, 9], [24, 16]], [[24, 16], [8, 16]], [[8, 16], [8, 9]],
  [[14, 11], [18, 11]], [[18, 11], [18, 14]], [[18, 14], [14, 14]], [[14, 14], [14, 11]],
  [[5, 16], [27, 16]], [[27, 16], [27, 30]], [[27, 30], [19, 30]], [[19, 30], [19, 22]],
  [[19, 22], [13, 22]], [[13, 22], [13, 30]], [[13, 30], [5, 30]], [[5, 30], [5, 16]],
];
const OVERALLS_STROKE_RADIUS = 1.2;
const RASTER_SAMPLES = 8;

/** @param {number} x @param {number} y @param {Segment} segment @returns {number} */
function segmentDistanceSquared(x, y, segment) {
  const [[startX, startY], [endX, endY]] = segment;
  const deltaX = endX - startX;
  const deltaY = endY - startY;
  const lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared === 0) return (x - startX) ** 2 + (y - startY) ** 2;
  const projection = Math.max(0, Math.min(1, ((x - startX) * deltaX + (y - startY) * deltaY) / lengthSquared));
  const nearestX = startX + projection * deltaX;
  const nearestY = startY + projection * deltaY;
  return (x - nearestX) ** 2 + (y - nearestY) ** 2;
}

/** @param {number} x @param {number} y @returns {boolean} */
function overallsStrokeAt(x, y) {
  const radiusSquared = OVERALLS_STROKE_RADIUS ** 2;
  return OVERALLS_SEGMENTS.some((segment) => segmentDistanceSquared(x, y, segment) <= radiusSquared);
}

/** @param {number} x @param {number} y @param {number} size @param {boolean} border @returns {number} */
function coverageAt(x, y, size, border) {
  const scale = size / 32;
  let covered = 0;
  for (let sampleY = 0; sampleY < RASTER_SAMPLES; sampleY++) {
    for (let sampleX = 0; sampleX < RASTER_SAMPLES; sampleX++) {
      const physicalX = x + (sampleX + 0.5) / RASTER_SAMPLES;
      const physicalY = y + (sampleY + 0.5) / RASTER_SAMPLES;
      const canonicalX = physicalX / scale;
      const canonicalY = physicalY / scale;
      const edge = physicalX < size / 16 || physicalY < size / 16 || physicalX >= size - size / 16 || physicalY >= size - size / 16;
      if (overallsStrokeAt(canonicalX, canonicalY) || (border && edge)) covered++;
    }
  }
  return covered / (RASTER_SAMPLES * RASTER_SAMPLES);
}

/**
 * @cc [owner:ghuntley,label:product] marvin-overalls-icon-state
 * Generated icons MUST use the overalls path at 16px and 32px. Supported
 * pages MUST have an opaque dark canvas with a white mark; unsupported pages
 * MUST keep the mark and one-pixel border grey on a transparent canvas.
 *
 * @param {number} size
 * @param {boolean} supported
 * @returns {Buffer} a square PNG using the overalls mark: an inverted black
 * and white mark when supported, or a grey outlined mark when unsupported.
 */
export function markPng(size, supported) {
  if (![16, 32].includes(size)) throw new Error("Unsupported icon size");
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const offset = y * (size * 4 + 1) + 1 + x * 4;
      const coverage = coverageAt(x, y, size, !supported);
      if (supported) {
        const value = Math.round(17 + (255 - 17) * coverage);
        raw[offset] = value;
        raw[offset + 1] = value;
        raw[offset + 2] = value;
        raw[offset + 3] = 255;
      } else {
        raw[offset] = 128;
        raw[offset + 1] = 128;
        raw[offset + 2] = 128;
        raw[offset + 3] = Math.round(255 * coverage);
      }
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
