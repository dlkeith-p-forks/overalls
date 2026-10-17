import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

interface AccountService {
  getDefaultAccount(): unknown;
  refresh(): unknown;
  signIn(): unknown;
  signOut(): unknown;
  getDefaultAccountAuthenticationProvider(): unknown;
  dispose(): unknown;
}

function isAccountService(value: unknown): value is AccountService {
  return typeof value === 'object' && value !== null
    && 'getDefaultAccount' in value && typeof value.getDefaultAccount === 'function'
    && 'refresh' in value && typeof value.refresh === 'function'
    && 'signIn' in value && typeof value.signIn === 'function'
    && 'signOut' in value && typeof value.signOut === 'function'
    && 'getDefaultAccountAuthenticationProvider' in value
    && typeof value.getDefaultAccountAuthenticationProvider === 'function'
    && 'dispose' in value && typeof value.dispose === 'function';
}

/** @cc [owner:ghuntley,label:verification] no-account-async-settlement
 * The actual source-built account service without product configuration MUST
 * settle account, refresh, sign-in and sign-out requests within the deadline,
 * returning no account or authentication provider.
 */
async function checkAccountService(sourceBundle: string): Promise<void> {
  const module: unknown = await import(pathToFileURL(sourceBundle).href);
  if (typeof module !== 'object' || module === null
    || !('DefaultAccountService' in module) || typeof module.DefaultAccountService !== 'function') {
    throw new Error('Missing source-built account service');
  }
  const service: unknown = Reflect.construct(module.DefaultAccountService, [{}]);
  if (!isAccountService(service)) throw new Error('Invalid source-built account service');
  let deadline: NodeJS.Timeout | undefined;
  try {
    const expired = new Promise<never>((_resolve, reject) => {
      deadline = setTimeout(() => reject(new Error('No-account initialization barrier did not settle')), 1000);
    });
    const outcomes: unknown = await Promise.race([
      Promise.all([service.getDefaultAccount(), service.refresh(), service.signIn(), service.signOut()]),
      expired,
    ]);
    assert.deepEqual(outcomes, [null, null, null, undefined]);
    assert.equal(service.getDefaultAccountAuthenticationProvider(), undefined);
  } finally {
    if (deadline) clearTimeout(deadline);
    service.dispose();
  }
}

const bundle = process.argv[2];
if (!bundle || process.argv.length !== 3) {
  throw new Error('Usage: node check-no-account.mts <source-built-account-bundle>');
}
await checkAccountService(bundle);
console.log('No-account service requests settle without an authentication provider.');
