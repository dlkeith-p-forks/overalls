import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, stat, truncate, rm } from 'node:fs/promises';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { createServer } from 'node:net';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

interface ZipEntry { readonly name: string; readonly bytes: Buffer }
interface HttpResult { readonly status: number; readonly body: string; readonly csp: string }

function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function zip(entries: readonly ZipEntry[]): Buffer {
  const files: Buffer[] = [];
  const directory: Buffer[] = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name);
    const checksum = crc32(entry.bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(entry.bytes.length, 18);
    local.writeUInt32LE(entry.bytes.length, 22);
    local.writeUInt16LE(name.length, 26);
    files.push(local, name, entry.bytes);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(entry.bytes.length, 20);
    central.writeUInt32LE(entry.bytes.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    directory.push(central, name);
    offset += local.length + name.length + entry.bytes.length;
  }
  const central = Buffer.concat(directory);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(central.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...files, central, end]);
}

function http(socketPath: string, path: string, headers: Readonly<Record<string, string>> = {}): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, headers }, response => {
      const bytes: Buffer[] = [];
      response.on('data', (chunk: Buffer) => bytes.push(chunk));
      response.on('end', () => {
        const csp = response.headers['content-security-policy'];
        resolve({ status: response.statusCode ?? 0, body: Buffer.concat(bytes).toString(), csp: Array.isArray(csp) ? csp.join('; ') : csp ?? '' });
      });
      response.on('error', reject);
    });
    req.setTimeout(5000, () => req.destroy(new Error('HTTP fixture deadline exceeded')));
    req.on('error', reject);
    req.end();
  });
}

function settlesWithin(completion: Promise<void>, milliseconds: number): Promise<boolean> {
  return new Promise(resolve => {
    const deadline = setTimeout(() => resolve(false), milliseconds);
    void completion.then(() => {
      clearTimeout(deadline);
      resolve(true);
    });
  });
}

const [editor, python, chromium, browserCheck, openssl] = process.argv.slice(2);
if (!editor || !python || !chromium || !browserCheck || !openssl || process.argv.length !== 7) {
  throw new Error('Usage: node check-runtime.mts <editor-package> <python> <chromium> <browser-check> <openssl>');
}
const product: unknown = JSON.parse(await readFile(join(editor, 'product.json'), 'utf8'));
if (typeof product !== 'object' || product === null || 'defaultChatAgent' in product
  || !('trustedExtensionAuthAccess' in product) || typeof product.trustedExtensionAuthAccess !== 'object'
  || product.trustedExtensionAuthAccess === null || Object.keys(product.trustedExtensionAuthAccess).length !== 0) {
  throw new Error('Packaged editor must have no optional chat agent or trusted extension authentication grants');
}
await import(pathToFileURL(join(editor, 'out/nls.messages.js')).href);
const verifier: unknown = await import(pathToFileURL(join(editor, 'out/vs/platform/extensionManagement/node/openVsxSignatureVerifier.js')).href);
if (typeof verifier !== 'object' || verifier === null || !('verifyOpenVsxSignature' in verifier)
  || typeof verifier.verifyOpenVsxSignature !== 'function') throw new Error('Missing packaged verifier');
async function verify(vsix: string, archive: string, keys: readonly string[]): Promise<string> {
  if (typeof verifier !== 'object' || verifier === null || !('verifyOpenVsxSignature' in verifier)
    || typeof verifier.verifyOpenVsxSignature !== 'function') throw new Error('Invalid packaged verifier');
  const result: unknown = await verifier.verifyOpenVsxSignature(vsix, archive, keys);
  if (typeof result !== 'string') throw new Error('Invalid packaged verifier result');
  return result;
}

const directory = await mkdtemp(join(tmpdir(), 'overalls-editor-runtime-'));
const packageBytes = zip([{ name: 'extension/package.json', bytes: Buffer.from('{"name":"fixture","publisher":"overalls","version":"1.0.0","engines":{"vscode":"*"}}') }]);
const packagePath = join(directory, 'fixture.vsix');
const signaturePath = join(directory, 'fixture.sigzip');
const { privateKey, publicKey } = generateKeyPairSync('ed25519');
const key = publicKey.export({ type: 'spki', format: 'pem' }).toString();
const signature = sign(null, packageBytes, privateKey);
try {
  await writeFile(packagePath, packageBytes);
  await writeFile(signaturePath, zip([{ name: '.signature.sig', bytes: signature }]));
  assert.equal(await verify(packagePath, signaturePath, [key]), 'Success');
  const otherKey = generateKeyPairSync('ed25519').publicKey.export({ type: 'spki', format: 'pem' }).toString();
  assert.equal(await verify(packagePath, signaturePath, [otherKey]), 'Untrusted');
  assert.notEqual(await verify(packagePath, signaturePath, []), 'Success');
  const changed = Buffer.from(packageBytes);
  changed[changed.length - 1] ^= 1;
  await writeFile(packagePath, changed);
  assert.notEqual(await verify(packagePath, signaturePath, [key]), 'Success');
  await writeFile(packagePath, packageBytes);
  for (const entries of [
    [],
    [{ name: '.signature.sig', bytes: Buffer.alloc(63) }],
    [{ name: '.signature.sig', bytes: signature }, { name: '.signature.sig', bytes: signature }],
    [{ name: '.signature.sig', bytes: signature }, { name: 'oversized', bytes: Buffer.alloc(1024 * 1024 + 1) }],
  ]) {
    await writeFile(signaturePath, zip(entries));
    assert.notEqual(await verify(packagePath, signaturePath, [key]), 'Success');
  }
  await writeFile(signaturePath, Buffer.from('malformed archive'));
  assert.notEqual(await verify(packagePath, signaturePath, [key]), 'Success');
  assert.notEqual(await verify(packagePath, join(directory, 'missing.sigzip'), [key]), 'Success');
  await truncate(packagePath, 256 * 1024 * 1024 + 1);
  assert.notEqual(await verify(packagePath, signaturePath, [key]), 'Success');

  const descriptor: unknown = JSON.parse(await readFile(join(editor, 'overalls-editor-release.json'), 'utf8'));
  if (typeof descriptor !== 'object' || descriptor === null || !('source_commit' in descriptor)
    || typeof descriptor.source_commit !== 'string' || !('release_id' in descriptor)
    || typeof descriptor.release_id !== 'string') throw new Error('Invalid editor descriptor');
  const manualPath = join(directory, 'manual.vsix');
  await writeFile(manualPath, zip([{ name: 'extension/package.json', bytes: Buffer.from(JSON.stringify({
    name: 'manual', publisher: 'overalls', version: '1.0.0', engines: { vscode: '*' },
    extensionDependencies: ['overalls.no-such-gallery-dependency'],
    extensionPack: ['overalls.no-such-gallery-pack'],
  })) }]));
  execFileSync(join(editor, 'bin/overalls-code'), [
    '--install-extension', manualPath, '--disable-telemetry',
    '--server-data-dir', join(directory, 'manual-data'), '--extensions-dir', join(directory, 'manual-extensions'),
  ], { timeout: 20000, stdio: 'pipe' });
  const installed = await readFile(join(directory, 'manual-extensions', 'overalls.manual-1.0.0', 'package.json'), 'utf8');
  assert(installed.includes('no-such-gallery-dependency'));
  const socket = join(directory, 'editor.sock');
  const port = await new Promise<number>((resolve, reject) => {
    const reservation = createServer();
    reservation.on('error', reject);
    reservation.listen(0, '127.0.0.1', () => {
      const address = reservation.address();
      if (!address || typeof address === 'string') { reservation.close(); reject(new Error('Invalid fixture address')); return; }
      reservation.close(error => error ? reject(error) : resolve(address.port));
    });
  });
  const hostname = `e-${'a'.repeat(26)}-${'b'.repeat(25)}a.editors.overalls.test`;
  const origin = `https://${hostname}:${port}`;
  const server = spawn(join(editor, 'bin/overalls-code'), [
    '--socket-path', socket, '--without-connection-token', '--disable-telemetry',
    '--disable-workspace-trust',
    '--server-data-dir', join(directory, 'data'), '--extensions-dir', join(directory, 'extensions'),
  ], { env: { ...process.env, OVERALLS_EDITOR_ORIGIN: origin }, stdio: 'ignore' });
  let serverStartError: Error | undefined;
  const exited = new Promise<void>(resolve => {
    server.once('exit', () => resolve());
    server.once('error', error => {
      serverStartError = error;
      resolve();
    });
  });
  try {
    let ready = false;
    for (let attempt = 0; attempt < 30; attempt += 1) {
      try {
        if (serverStartError) throw serverStartError;
        const response = await http(socket, '/version');
        if (response.status === 200 && response.body === descriptor.source_commit) { ready = true; break; }
      } catch { /* Startup may not have published the listener yet. */ }
      if (server.exitCode !== null) throw new Error('Packaged editor exited before readiness');
      await new Promise<void>(resolve => setTimeout(resolve, 1000));
    }
    assert(ready, 'Packaged editor must become ready');
    assert.equal((await stat(socket)).mode & 0o777, 0o600);
    const page = await http(socket, '/', { host: 'forged.invalid', 'x-forwarded-host': 'forged.invalid', 'x-original-host': 'forged.invalid' });
    assert.equal(page.status, 200);
    assert(page.csp.includes("frame-ancestors 'none'"));
    assert(page.body.includes(origin.slice('https://'.length)));
    assert(page.body.includes(`/code-assets/${descriptor.release_id}/`));
    assert(!page.body.includes('forged.invalid'));
    assert(!page.body.includes('.vscode-cdn.net/'));
    assert.equal((await http(socket, '/?tkn=fixture')).status, 400);
    const certificate = join(directory, 'browser-cert.pem');
    const certificateKey = join(directory, 'browser-key.pem');
    execFileSync(openssl, [
      'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
      '-keyout', certificateKey, '-out', certificate, '-subj', '/CN=packaged-browser-fixture',
      '-days', '1', '-addext', `subjectAltName=DNS:${hostname}`,
    ], { timeout: 5000, stdio: 'ignore' });
    execFileSync(python, [
      browserCheck, '--socket', socket, '--origin', origin, '--chromium', chromium,
      '--certificate', certificate, '--key', certificateKey,
    ], { timeout: 45000, killSignal: 'SIGTERM', stdio: 'inherit' });
  } finally {
    if (!serverStartError && server.exitCode === null && server.signalCode === null) server.kill('SIGTERM');
    if (!await settlesWithin(exited, 2000)) {
      server.kill('SIGKILL');
      if (!await settlesWithin(exited, 2000)) throw new Error('Editor fixture server cleanup deadline exceeded');
    }
  }
  console.log('Packaged signature verification, origin isolation, Unix readiness, socket mode and browser initialization passed.');
} finally {
  await rm(directory, { recursive: true, force: true });
}
