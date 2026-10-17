import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

/** @typedef {{text: string, columns: number[], width: number}} Line */
/** @typedef {{height: string, transform: string}} RowStyle */
/** @typedef {{textContent: string, style: RowStyle, attributes: Map<string, string>, setAttribute: (key: string, value: string) => void, getBoundingClientRect: () => {width: number}}} Row */

const source = readFileSync(new URL("../../assets/vendor/xterm/xterm.mjs", import.meta.url), "utf8");
// Expose the pinned class only inside this test VM; execute the shipped methods.
assert.equal(source.split("export{Dl as Terminal};").length, 2);
/** @type {Record<string, unknown>} */
const scope = { process: { title: "node", versions: { node: "24" }, platform: "linux", env: {} }, queueMicrotask };
runInNewContext(source.replace("export{Dl as Terminal};", "globalThis.accessibility = Tt.prototype;"), scope);
const prototype = scope.accessibility;
assert(prototype !== null && typeof prototype === "object");

/**
 * @cc [owner:ghuntley,label:verification] shipped-accessibility-layout-regression
 * The regression MUST execute the actual vendored accessibility methods. Mixed
 * width and blank rows MUST retain text, logical columns and scaled widths;
 * one refresh MUST NOT force layout separately for every changed row.
 */
/** @param {Line[]} lines */
function fixture(lines) {
  let dirty = true;
  let layouts = 0;
  let announcements = 0;
  /** @type {Row[]} */
  const rows = lines.map((line) => {
    let text = "old text";
    let transform = "scaleX(2)";
    let height = "10px";
    const attributes = new Map();
    return {
      get textContent() { return text; },
      set textContent(value) { text = value; dirty = true; },
      style: {
        get transform() { return transform; },
        set transform(value) { transform = value; dirty = true; },
        get height() { return height; },
        set height(value) { height = value; dirty = true; },
      },
      attributes,
      /** @param {string} key @param {string} value */
      setAttribute(key, value) { attributes.set(key, value); },
      getBoundingClientRect() {
        if (dirty) { layouts += 1; dirty = false; }
        const scale = transform === "" ? 1 : Number(transform.slice(7, -1));
        return { width: line.width * scale };
      },
    };
  });
  /** @type {WeakMap<Row, number[]>} */
  const columns = new WeakMap();
  assert(prototype !== null && typeof prototype === "object");
  /** @type {object} */
  const manager = Object.create(prototype);
  Object.assign(manager, {
    _rowElements: rows,
    _rowColumns: columns,
    _accessibilityContainer: { style: { width: "", fontSize: "" } },
    _renderService: { dimensions: { css: { cell: { width: 9, height: 20 }, canvas: { width: 720 } } } },
    _terminal: {
      rows: lines.length,
      options: { fontSize: 13 },
      buffer: {
        ydisp: 4,
        lines: {
          length: lines.length + 4,
          /** @param {number} index */
          get(index) {
            const line = lines[index - 4];
            return {
              /** @param {boolean} _trim @param {undefined} _start @param {undefined} _end @param {number[]} mapping */
              translateToString(_trim, _start, _end, mapping) {
                mapping.push(...line.columns);
                return line.text;
              },
            };
          },
        },
      },
    },
    _announceCharacters() { announcements += 1; },
  });
  return {
    rows,
    columns,
    get layouts() { return layouts; },
    get announcements() { return announcements; },
    /** @param {string} name @param {number[]} args */
    call(name, args = []) {
      assert(name in manager);
      const method = Reflect.get(manager, name);
      assert.equal(typeof method, "function");
      Reflect.apply(method, manager, args);
    },
  };
}

/** @type {Line[]} */
const lines = [
  { text: "ASCII", columns: [0, 1, 2, 3, 4, 5], width: 40 },
  { text: "界é", columns: [0, 2, 3], width: 25 },
  { text: "", columns: [], width: 8 },
];

test("the shipped xterm artifacts retain their reviewed patch integrity", () => {
  /** @type {unknown} */
  const manifest = JSON.parse(readFileSync(new URL("../../assets/vendor/xterm/accessibility-layout.json", import.meta.url), "utf8"));
  assert(manifest !== null && typeof manifest === "object");
  for (const [name, field] of [["xterm.mjs", "patched_esm_sha256"], ["xterm.css", "css_sha256"], ["LICENSE", "license_sha256"]]) {
    assert(field in manifest);
    /** @type {unknown} */
    const expected = Reflect.get(manifest, field);
    assert.equal(typeof expected, "string");
    const bytes = readFileSync(new URL(`../../assets/vendor/xterm/${name}`, import.meta.url));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), expected);
  }
});

test("accessibility output keeps mixed-width and blank rows without layout per row", () => {
  const state = fixture(lines);
  state.call("_renderRows", [0, 2]);
  assert.deepEqual(state.rows.map((row) => row.textContent), ["ASCII", "界é", "\u00a0"]);
  assert.deepEqual(state.rows.map((row) => row.style.transform), ["scaleX(1.125)", "scaleX(1.08)", "scaleX(1.125)"]);
  assert.deepEqual(state.rows.map((row) => row.attributes.get("aria-posinset")), ["5", "6", "7"]);
  assert(state.rows.every((row) => row.attributes.get("aria-setsize") === "7"));
  const blankColumns = state.columns.get(state.rows[2]);
  assert(blankColumns);
  assert.deepEqual([...blankColumns], [0, 1]);
  assert.equal(state.announcements, 1);
  assert.equal(state.layouts, 1);
});

test("a partial accessibility refresh leaves other rows untouched", () => {
  const state = fixture(lines);
  state.call("_renderRows", [0, 1]);
  assert.equal(state.rows[2].textContent, "old text");
  assert.equal(state.rows[2].style.transform, "scaleX(2)");
  assert.equal(state.announcements, 1);
  assert.equal(state.layouts, 1);
});

test("accessibility resize retains row geometry without layout per row", () => {
  const state = fixture(lines);
  state.rows.forEach((row, index) => state.columns.set(row, lines[index].columns));
  state.call("_refreshRowsDimensions");
  assert(state.rows.every((row) => row.style.height === "20px"));
  assert.deepEqual(state.rows.map((row) => row.style.transform), ["scaleX(1.125)", "scaleX(1.08)", ""]);
  assert.equal(state.layouts, 1);
});
