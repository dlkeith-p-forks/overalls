import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

interface ValidationModule {
  readonly compatibleEngine: (engine: string, version: string) => boolean;
  readonly validateExtension: (vsix: string, signature: string, keys: readonly string[], engine: string, version: string) => Promise<boolean>;
}

function validationModule(value: unknown): ValidationModule {
  if (typeof value !== 'object' || value === null || !('validateExtension' in value)
    || typeof value.validateExtension !== 'function' || !('compatibleEngine' in value)
    || typeof value.compatibleEngine !== 'function') {
    throw new Error('validator_unavailable');
  }
  const compatibleEngine = value.compatibleEngine;
  const validateExtension = value.validateExtension;
  return { compatibleEngine: (engine, version) => {
    const result: unknown = compatibleEngine(engine, version);
    if (typeof result !== 'boolean') { throw new Error('validator_unavailable'); }
    return result;
  }, validateExtension: (vsix, signature, keys, engine, version) => {
    const result: unknown = validateExtension(vsix, signature, keys, engine, version);
    if (!(result instanceof Promise)) { throw new Error('validator_unavailable'); }
    return result.then((valid: unknown) => {
      if (typeof valid !== 'boolean') { throw new Error('validator_unavailable'); }
      return valid;
    });
  } };
}

/**
 * @cc [owner:ghuntley,label:security] maintenance-fixed-results
 * Validation MUST fail closed for malformed arguments, untrusted signatures
 * and incompatible engines, and MUST emit only fixed outcome strings.
 */
async function main(args: readonly string[]): Promise<void> {
  const engineOnly = args[0] === '--engine-only';
  if (engineOnly) { args = args.slice(1); }
  const values = new Map<string, string>();
  const keys: string[] = [];
  const options = new Set(['--vsix', '--signature', '--engine', '--editor-version']);
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]; const value = args[i + 1];
    if (!key || !value || value.length > 4096) { throw new Error('invalid_arguments'); }
    if (key === '--key') { keys.push(await readFile(value, 'utf8')); }
    else if (options.has(key) && !values.has(key)) { values.set(key, value); }
    else { throw new Error('invalid_arguments'); }
  }
  const vsix = values.get('--vsix'); const signature = values.get('--signature');
  const engine = values.get('--engine'); const version = values.get('--editor-version');
  if (!engine || engine.length > 256 || !version || keys.length > 16
    || keys.some(key => key.length > 16384) || !/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error('invalid_arguments');
  }
  const validator = validationModule(await import(pathToFileURL(join(dirname(fileURLToPath(import.meta.url)), 'maintenance.bundle.mjs')).href));
  if (engineOnly) {
    if (vsix || signature || keys.length) { throw new Error('invalid_arguments'); }
    const compatible = validator.compatibleEngine(engine, version);
    process.stdout.write(compatible ? 'compatible\n' : 'incompatible\n');
    process.exitCode = compatible ? 0 : 3;
    return;
  }
  if (!vsix || !signature || !keys.length) { throw new Error('invalid_arguments'); }
  if (!await validator.validateExtension(vsix, signature, keys, engine, version)) {
    throw new Error('validation_refused');
  }
  process.stdout.write('validated\n');
}

try { await main(process.argv.slice(2)); }
catch { process.stderr.write('extension_validation_failed\n'); process.exitCode = 1; }
