import { verifyOpenVsxSignature } from './src/vs/platform/extensionManagement/node/openVsxSignatureVerifier.js';
import { isEngineValid } from './src/vs/platform/extensions/common/extensionValidator.js';

export function compatibleEngine(engine: string, version: string): boolean {
  return isEngineValid(engine, version, '2026-10-06T08:15:52.000Z');
}

/**
 * @cc [owner:ghuntley,label:security] maintenance-upstream-validation
 * Maintenance MUST use the shipped signature verifier and upstream engine
 * validator with the packaged source date; it MUST NOT accept registry keys.
 */
export async function validateExtension(vsix: string, signature: string, keys: readonly string[], engine: string, version: string): Promise<boolean> {
  return compatibleEngine(engine, version)
    && await verifyOpenVsxSignature(vsix, signature, keys) === 'Success';
}
