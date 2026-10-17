import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

interface EditorInputs {
  readonly sourceCommit: string;
  readonly sourceHash: string;
  readonly npmHash: string;
  readonly version: string;
  readonly nodeVersion: string;
  readonly electronTypesVersion: string;
  readonly electronTypesHash: string;
}

/** @cc [owner:ghuntley,label:build] patch-input-validation
 * Patch checking MUST validate the pinned input schema and apply every patch to
 * the requested upstream tree. A successful check MUST NOT claim a build passed.
 */
function parseInputs(value: unknown): EditorInputs {
  if (typeof value !== 'object' || value === null
    || !('sourceCommit' in value) || typeof value.sourceCommit !== 'string'
    || !('sourceHash' in value) || typeof value.sourceHash !== 'string'
    || !('npmHash' in value) || typeof value.npmHash !== 'string'
    || !('version' in value) || typeof value.version !== 'string'
    || !('nodeVersion' in value) || typeof value.nodeVersion !== 'string'
    || !('electronTypesVersion' in value) || typeof value.electronTypesVersion !== 'string'
    || !('electronTypesHash' in value) || typeof value.electronTypesHash !== 'string'
    || !/^[a-f0-9]{40}$/.test(value.sourceCommit)
    || !/^sha256-[A-Za-z0-9+/]{43}=$/.test(value.sourceHash)
    || !/^sha256-[A-Za-z0-9+/]{43}=$/.test(value.npmHash)
    || !/^\d+\.\d+\.\d+$/.test(value.version)
    || !/^24\.\d+\.\d+$/.test(value.nodeVersion)
    || !/^\d+\.\d+\.\d+$/.test(value.electronTypesVersion)
    || !/^sha256-[A-Za-z0-9+/]{43}=$/.test(value.electronTypesHash)
    || value.npmHash === 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=') {
    throw new Error('Invalid or unresolved pinned editor inputs');
  }
  return {
    sourceCommit: value.sourceCommit, sourceHash: value.sourceHash,
    npmHash: value.npmHash, version: value.version, nodeVersion: value.nodeVersion,
    electronTypesVersion: value.electronTypesVersion, electronTypesHash: value.electronTypesHash,
  };
}

const packageDirectory = dirname(fileURLToPath(import.meta.url));
const sourceDirectory = process.argv[2];
if (!sourceDirectory || process.argv.length !== 3) {
  throw new Error('Usage: node check-patches.mts <unmodified-upstream-source-directory>');
}
const inputs = parseInputs(JSON.parse(execFileSync('nix-instantiate', [
  '--eval', '--strict', '--json', join(packageDirectory, 'inputs.nix'),
], { encoding: 'utf8' })));
const source = resolve(sourceDirectory);
const manifest: unknown = JSON.parse(readFileSync(join(source, 'package.json'), 'utf8'));
if (typeof manifest !== 'object' || manifest === null || !('version' in manifest) || manifest.version !== inputs.version) {
  throw new Error('The upstream version differs from the reviewed inputs');
}
if (execFileSync('git', ['rev-parse', 'HEAD'], { cwd: source, encoding: 'utf8' }).trim() !== inputs.sourceCommit) {
  throw new Error('The upstream commit differs from the reviewed inputs');
}
const checkout = mkdtempSync(join(tmpdir(), 'overalls-editor-patch-check-'));
try {
  execFileSync('git', ['clone', '--shared', '--no-checkout', source, checkout], { stdio: 'ignore' });
  execFileSync('git', ['checkout', '--detach', inputs.sourceCommit], { cwd: checkout, stdio: 'ignore' });
  const patches = readdirSync(join(packageDirectory, 'patches')).filter(name => /^\d{4}-[a-z0-9-]+\.patch$/.test(name)).sort();
  if (patches.length === 0) { throw new Error('Missing maintained patch stack'); }
  for (const name of patches) {
    const patch = join(packageDirectory, 'patches', name);
    execFileSync('git', ['apply', '--check', patch], { cwd: checkout, stdio: 'inherit' });
    execFileSync('git', ['apply', patch], { cwd: checkout, stdio: 'inherit' });
  }
} finally { rmSync(checkout, { recursive: true, force: true }); }
console.log(`Patch stack applies to Code OSS ${inputs.version} (${inputs.sourceCommit}). Run the Nix package build to verify compilation and offline inputs.`);
