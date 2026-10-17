import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

interface PolicyCheckModule {
  runOverallsPolicyChecks(): Promise<void>;
}

function isPolicyCheckModule(value: unknown): value is PolicyCheckModule {
  return typeof value === 'object' && value !== null
    && 'runOverallsPolicyChecks' in value && typeof value.runOverallsPolicyChecks === 'function';
}

/** @cc [owner:ghuntley,label:verification] editor-native-policy-checks
 * Checks MUST run compiled upstream modules with immutable product policy set
 * before import. No copied policy engine or source-text assertion proves behavior.
 */
async function checkPolicies(bundles: readonly string[]): Promise<void> {
  Object.defineProperties(globalThis, {
    _VSCODE_PRODUCT_JSON: {
      value: Object.freeze({
        version: '1.141.0', nameShort: 'Overalls Editor', nameLong: 'Overalls Editor',
        overallsEditor: Object.freeze({
          releaseId: 'compiled-policy-check', protocol: 1, extensionSigningKeys: Object.freeze([]),
          policy: Object.freeze({ builtInAI: 'disabled', workspaceTrust: 'disabled' }),
        }),
      }),
    },
    _VSCODE_PACKAGE_JSON: { value: Object.freeze({ version: '1.141.0' }) },
  });
  for (const bundle of bundles) {
    const module: unknown = await import(pathToFileURL(bundle).href);
    assert.ok(isPolicyCheckModule(module), 'Missing compiled upstream policy checks');
    await module.runOverallsPolicyChecks();
  }
}

const bundles = process.argv.slice(2);
if (bundles.length !== 2) {
  throw new Error('Usage: node check-policy.mts <configuration-check.mjs> <service-check.mjs>');
}
await checkPolicies(bundles);
console.log('Compiled product policy: configuration scope matrix, direct native services and policy write refusals passed.');
