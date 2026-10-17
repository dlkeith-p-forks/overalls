// @ts-check
import test from "node:test";
import assert from "node:assert/strict";
import { capturedRepositorySource } from "../../assets/js/repository_launch.js";

/**
 * @cc [owner:ghuntley,label:verification;security] capture-url-secret-refusal-evidence
 * Synthetic query/fragment sentinels MUST disappear before a captured URL can
 * become a storage key or POST source. URL user information MUST yield no source.
 */
test("capture omits query and fragment secrets while preserving provider revisions", () => {
  const sources = [
    "https://github.com/team/repo/tree/feature/topic",
    "https://gitlab.com/group/nested/repo/-/tree/main",
    "https://codeberg.org/team/repo/src/branch/main",
    "https://bitbucket.org/team/repo/src/main",
  ];
  for (const source of sources) {
    assert.equal(
      capturedRepositorySource(`#${source}?token=synthetic-query-secret#synthetic-fragment-secret`),
      source,
    );
    assert.equal(capturedRepositorySource(`#${source}`), source);
  }
});

test("capture refuses user information without constructing a submitted source", () => {
  for (const source of [
    "#https://synthetic-user@github.com/team/repo",
    "#https://synthetic-user:synthetic-password@github.com/team/repo",
    "#https://:synthetic-password@github.com/team/repo",
    "#https://@github.com/team/repo",
  ]) {
    assert.equal(capturedRepositorySource(source), null);
  }
});

test("privacy minimization preserves raw authority and path for server refusal", () => {
  for (const source of [
    "https://github.com:443/team/repo",
    "https://github.com/team/../repo",
    "https://github.com/team/%2e%2e/repo",
  ]) {
    assert.equal(capturedRepositorySource(`#${source}?token=synthetic-secret`), source);
  }
});

test("capture requires a parseable HTTPS URL", () => {
  for (const source of ["#https://", "#http://github.com/team/repo", "#javascript:alert(1)"]) {
    assert.equal(capturedRepositorySource(source), null);
  }
});
