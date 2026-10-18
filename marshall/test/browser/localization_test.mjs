import test from "node:test";
import assert from "node:assert/strict";
import {t} from "../../assets/js/localization.js";

test("server catalog changes language without changing source keys", () => {
  const previous = globalThis.document;
  globalThis.document = {querySelector: () => ({getAttribute: () => JSON.stringify({"Hello %{name}": "こんにちは、%{name}"})})};
  try {
    assert.equal(t("Hello %{name}", {name: "<user>"}), "こんにちは、<user>");
    assert.equal(t("Unknown %{name}", {name: "guest"}), "Unknown guest");
  } finally { globalThis.document = previous; }
});

test("malformed or non-string catalog values fall back to source", () => {
  const previous = globalThis.document;
  for (const encoded of ["not json", "null", '{"Hello":42}']) {
    globalThis.document = {querySelector: () => ({getAttribute: () => encoded})};
    assert.equal(t("Hello"), "Hello");
  }
  globalThis.document = previous;
});
