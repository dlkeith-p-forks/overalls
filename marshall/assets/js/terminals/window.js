/**
 * @cc [owner:ghuntley,label:protocol;capacity] browser-terminal-credit-window
 * Sent frames MUST fit both the 256 KiB and sixteen-frame windows. Cumulative
 * receipts MUST match a sent prefix; repeated receipts MUST NOT add credit.
 * This object stores lengths only and MUST NOT retain terminal contents.
 */
export class CreditWindow {
  constructor() {
    this.sentBytes = 0;
    this.sentFrames = 0;
    this.ackedBytes = 0;
    this.ackedFrames = 0;
    /** @type {number[]} */
    this.pending = [];
  }

  get bytes() { return 262144 - (this.sentBytes - this.ackedBytes); }
  get frames() { return 16 - (this.sentFrames - this.ackedFrames); }

  /** @param {number} bytes @returns {boolean} */
  take(bytes) {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > 65535 || bytes > this.bytes || this.frames === 0 ||
        !Number.isSafeInteger(this.sentBytes + bytes) || !Number.isSafeInteger(this.sentFrames + 1)) return false;
    this.sentBytes += bytes;
    this.sentFrames++;
    this.pending.push(bytes);
    return true;
  }

  /** @param {number} frames @param {number} bytes @returns {boolean} */
  acknowledge(frames, bytes) {
    if (!Number.isSafeInteger(frames) || !Number.isSafeInteger(bytes) || frames < 0 || bytes < 0) return false;
    if (frames <= this.ackedFrames && bytes <= this.ackedBytes) return true;
    if (frames <= this.ackedFrames || frames > this.sentFrames) return false;
    const count = frames - this.ackedFrames;
    if (this.ackedBytes + this.pending.slice(0, count).reduce((sum, size) => sum + size, 0) !== bytes) return false;
    this.pending.splice(0, count);
    this.ackedBytes = bytes;
    this.ackedFrames = frames;
    return true;
  }
}
