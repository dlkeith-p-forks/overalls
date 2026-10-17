import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

interface RuntimeProductView {
  readonly overallsEditor?: {
    readonly userUpdatableBundledExtensions?: unknown;
  };
}

interface BundledUpdateModule {
  canUserUpdateOverallsBundledExtension(id: string, configuration: RuntimeProductView): boolean;
}

function isBundledUpdateModule(value: unknown): value is BundledUpdateModule {
  return typeof value === 'object' && value !== null
    && 'canUserUpdateOverallsBundledExtension' in value
    && typeof value.canUserUpdateOverallsBundledExtension === 'function';
}

/** @cc [owner:ghuntley,label:verification] editor-compiled-bundled-update-membership
 * Membership checks MUST invoke the actual compiled upstream helper and include
 * foreign/core-ID refusals. They MUST NOT claim Workbench update preferences,
 * personal installation, disablement, signature enforcement or VM acceptance.
 */
async function checkBundledUpdates(bundle: string): Promise<number> {
  const module: unknown = await import(pathToFileURL(bundle).href);
  assert.ok(isBundledUpdateModule(module), 'Missing compiled bundled-update helper');
  let decisions = 0;
  const check = (id: string, configuration: RuntimeProductView, expected: boolean): void => {
    const result: unknown = module.canUserUpdateOverallsBundledExtension(id, configuration);
    assert.equal(typeof result, 'boolean', 'Compiled helper must return a boolean');
    assert.equal(result, expected, 'Compiled helper violated a bundle permission case');
    decisions += 1;
  };
  const ids = [
    'editorconfig.editorconfig',
    'cab404.vscode-direnv',
    'elixir-lsp.elixir-ls',
    'rust-lang.rust-analyzer',
  ] as const;
  const coreIds = ['vscode.git', 'vscode.json-language-features', 'vscode.typescript-language-features'] as const;
  for (let mask = 0; mask < 1 << ids.length; mask += 1) {
    const roster = ids.filter((_id, index) => (mask & (1 << index)) !== 0);
    const configuration: RuntimeProductView = { overallsEditor: { userUpdatableBundledExtensions: roster } };
    for (const [index, id] of ids.entries()) {
      const expected = (mask & (1 << index)) !== 0;
      check(id, configuration, expected);
      check(id.toUpperCase(), configuration, expected);
      check(`${id}.unreviewed`, configuration, false);
    }
    const foreignRoster: RuntimeProductView = {
      overallsEditor: { userUpdatableBundledExtensions: [...roster, ...coreIds, 'unreviewed.vendor'] },
    };
    for (const id of coreIds) {
      check(id, foreignRoster, false);
      check(id.toUpperCase(), foreignRoster, false);
    }
    check('unreviewed.vendor', foreignRoster, false);
  }
  const missing: readonly RuntimeProductView[] = [{}, { overallsEditor: {} }];
  const malformed: readonly unknown[] = [null, undefined, true, 7, 'editorconfig.editorconfig', {}, [null, 7, {}, ...coreIds]];
  for (const id of ids) {
    for (const configuration of missing) check(id, configuration, false);
    for (const roster of malformed) check(id, { overallsEditor: { userUpdatableBundledExtensions: roster } }, false);
    check(id, { overallsEditor: { userUpdatableBundledExtensions: coreIds } }, false);
  }
  return decisions;
}

const [bundle] = process.argv.slice(2);
if (!bundle || process.argv.length !== 3) {
  throw new Error('Usage: node check-bundled-updates.mts <compiled-helper.mjs>');
}
const decisions = await checkBundledUpdates(bundle);
console.log(`Compiled bundled-update helper: ${decisions} permission decisions passed; Workbench and native behavior require separate checks.`);
