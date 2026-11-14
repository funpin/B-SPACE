import { createRequire } from 'node:module';
import { afterEach, describe, expect, it } from 'vitest';

// scripts/macSign.js is the afterPack hook's CommonJS module.
const requireScript = createRequire(__filename);
const { STABLE_REQUIREMENT, stableIdentityFromEnv } = requireScript('../scripts/macSign.js') as {
  STABLE_REQUIREMENT: RegExp;
  stableIdentityFromEnv: () => { p12: Buffer; password: string } | null;
};

const saved = { p12: process.env.MAC_SIGN_P12, password: process.env.MAC_SIGN_P12_PASSWORD };

afterEach(() => {
  process.env.MAC_SIGN_P12 = saved.p12;
  process.env.MAC_SIGN_P12_PASSWORD = saved.password;
  if (saved.p12 === undefined) delete process.env.MAC_SIGN_P12;
  if (saved.password === undefined) delete process.env.MAC_SIGN_P12_PASSWORD;
});

function env(p12: string | undefined, password: string | undefined): void {
  if (p12 === undefined) delete process.env.MAC_SIGN_P12;
  else process.env.MAC_SIGN_P12 = p12;
  if (password === undefined) delete process.env.MAC_SIGN_P12_PASSWORD;
  else process.env.MAC_SIGN_P12_PASSWORD = password;
}

describe('stableIdentityFromEnv', () => {
  it('is null when neither variable is set, or both are empty as CI passes them', () => {
    env(undefined, undefined);
    expect(stableIdentityFromEnv()).toBeNull();
    env('', '');
    expect(stableIdentityFromEnv()).toBeNull();
  });

  it('decodes the certificate when both are set', () => {
    env(Buffer.from('p12 bytes').toString('base64'), 'secret');
    const identity = stableIdentityFromEnv();
    expect(identity?.p12.toString()).toBe('p12 bytes');
    expect(identity?.password).toBe('secret');
  });

  it('refuses half a configuration', () => {
    env('cDEy', '');
    expect(() => stableIdentityFromEnv()).toThrow(/set together/);
    env('', 'secret');
    expect(() => stableIdentityFromEnv()).toThrow(/set together/);
  });
});

describe('STABLE_REQUIREMENT', () => {
  it('accepts a requirement pinned to a certificate, self-signed or chained', () => {
    expect(STABLE_REQUIREMENT.test('designated => identifier "com.backspace.desktop" and certificate root = H"18a1302a31682d9b426c6297b4b642837ab22308"')).toBe(true);
    expect(STABLE_REQUIREMENT.test('designated => identifier "com.backspace.desktop" and certificate leaf = H"83efd4a17cba15a6e6724f4da7720c9c74466b6b"')).toBe(true);
  });

  it('rejects an ad-hoc requirement', () => {
    expect(STABLE_REQUIREMENT.test('designated => cdhash H"4a9e49fe20f82802702a4e9d752748e990909659"')).toBe(false);
  });
});
