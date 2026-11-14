// Ad-hoc code signing fallback for macOS builds.
//
// Why this is needed:
//   electron-builder only signs when it can resolve a signing identity. Without
//   an Apple Developer ID, `MacPackager.sign()` bails out before signing at all
//   (`findIdentity()` -> null -> `reportError()` -> return false), so the
//   packaged bundle keeps only the linker-generated ad-hoc signatures that ship
//   inside the prebuilt Electron binaries. Packaging then invalidates those:
//   it renames the executable, rewrites Info.plist, injects app.asar, and
//   (via afterPack.js) deletes files out of Contents/Resources.
//
//   The result is not merely unsigned, it is *invalid*:
//     "code has no resources but signature indicates they must be present"
//   macOS reports an invalid signature as "Backspace.app is damaged and can't
//   be opened. You should move it to the Trash." — a dead end, with no "Open
//   Anyway" affordance anywhere in the UI.
//
// What this does:
//   Re-seals the bundle so it has a real Contents/_CodeSignature, the correct
//   bundle identifier, and a bound Info.plist. The app is still unnotarized, so
//   first launch shows the usual Gatekeeper prompt — but that prompt is
//   bypassable (System Settings -> Privacy & Security -> Open Anyway) and the
//   app runs afterwards.
//
// Which signature:
//   With MAC_SIGN_P12 (base64 of a .p12) and MAC_SIGN_P12_PASSWORD set, it signs
//   with that certificate: the project's self-signed code-signing identity
//   (docs/systems/desktop-security.md, "Stable signing identity"). The bundle's
//   designated requirement is then
//     identifier "com.backspace.desktop" and certificate leaf = H"<sha1>"
//   which every later build signed with the same certificate satisfies. That
//   is what lets macOS keep the Screen Recording / Input Monitoring grants
//   across updates (TCC stores this requirement with the grant) and lets
//   Squirrel.Mac install updates in place (it checks the update against it).
//   The certificate is not trusted by anything and does not need to be:
//   neither check evaluates trust, only the leaf hash.
//
//   Without them it falls back to an ad-hoc signature. That has no stable
//   identity: the requirement is the binary's own cdhash, which changes every
//   build, so macOS drops the grants on each update and auto-update is
//   impossible. MAC_SIGN_REQUIRED=1 (set by the release workflow) turns the
//   fallback into a build failure, because one ad-hoc release would strand
//   every installed copy on it.

const { execFileSync, spawnSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

// `codesign --sign -` never contacts a timestamp server; pinning it to none
// keeps the build hermetic rather than relying on that default.
const AD_HOC_SIGN_ARGS = ['--force', '--sign', '-', '--timestamp=none'];

/**
 * A certificate hash in the designated requirement marks a stable identity.
 * codesign anchors a self-signed certificate as `certificate root` (the leaf
 * is its own root) and a chained one as `certificate leaf`; both name the
 * project certificate and are equally stable.
 */
const STABLE_REQUIREMENT = /certificate (leaf|root) = H"[0-9a-f]{40}"/i;

/**
 * True when electron-builder has a real identity to sign with, in which case
 * this fallback must stay out of the way and let it sign properly.
 *
 * @returns {boolean}
 */
function hasRealSigningIdentity() {
  return Boolean(process.env.CSC_LINK || process.env.CSC_NAME);
}

/**
 * The project's code-signing certificate from the environment, or null.
 *
 * @returns {{ p12: Buffer, password: string } | null}
 * @throws {Error} If only one of the two variables is set, or the base64 decodes to nothing.
 */
function stableIdentityFromEnv() {
  // Empty counts as unset: CI passes '' to jobs that have no access to the
  // secret (other runners, fork PRs).
  const encoded = (process.env.MAC_SIGN_P12 || '').trim();
  const password = process.env.MAC_SIGN_P12_PASSWORD || '';
  if (!encoded && !password) return null;
  if (!encoded || !password) {
    throw new Error('[macSign] MAC_SIGN_P12 and MAC_SIGN_P12_PASSWORD must be set together');
  }
  const p12 = Buffer.from(encoded, 'base64');
  if (p12.length === 0) throw new Error('[macSign] MAC_SIGN_P12 is not valid base64');
  return { p12, password };
}

/**
 * The user's keychain search list, as paths.
 *
 * @returns {string[]}
 */
function userKeychainSearchList() {
  const out = execFileSync('security', ['list-keychains', '-d', 'user'], { encoding: 'utf8' });
  return out
    .split('\n')
    .map((line) => line.trim().replace(/^"(.*)"$/, '$1'))
    .filter(Boolean);
}

/**
 * Imports the certificate into a throwaway keychain that only codesign may
 * use, and returns the identity's SHA-1 and a cleanup function. The login
 * keychain is never touched, so a developer's machine is left as it was.
 *
 * @param {{ p12: Buffer, password: string }} identity
 * @returns {{ sha1: string, keychain: string, dispose: () => void }}
 */
function importIdentity({ p12, password }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'b-space-sign-'));
  const keychain = path.join(dir, 'signing.keychain-db');
  const p12Path = path.join(dir, 'identity.p12');
  const keychainPassword = crypto.randomBytes(24).toString('hex');
  // codesign finds an identity only in a keychain on the user's search list,
  // even with --keychain (on a GitHub runner it answers "no identity found"
  // otherwise). The list is put back exactly as it was when signing is done.
  const searchList = userKeychainSearchList();
  const dispose = () => {
    try {
      execFileSync('security', ['list-keychains', '-d', 'user', '-s', ...searchList], { stdio: 'ignore' });
    } catch {
      console.warn('[macSign] Could not restore the keychain search list');
    }
    try {
      execFileSync('security', ['delete-keychain', keychain], { stdio: 'ignore' });
    } catch {
      // Already gone; the directory removal below is what matters.
    }
    fs.rmSync(dir, { recursive: true, force: true });
  };
  try {
    fs.writeFileSync(p12Path, p12, { mode: 0o600 });
    execFileSync('security', ['create-keychain', '-p', keychainPassword, keychain]);
    // No auto-lock during a long build.
    execFileSync('security', ['set-keychain-settings', keychain]);
    execFileSync('security', ['unlock-keychain', '-p', keychainPassword, keychain]);
    execFileSync('security', ['import', p12Path, '-k', keychain, '-P', password, '-T', '/usr/bin/codesign'], { stdio: 'ignore' });
    // Lets codesign use the key without a GUI prompt (macOS 10.12+).
    execFileSync('security', ['set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', keychainPassword, keychain], { stdio: 'ignore' });
    fs.rmSync(p12Path, { force: true });
    execFileSync('security', ['list-keychains', '-d', 'user', '-s', keychain, ...searchList], { stdio: 'ignore' });

    // The self-signed certificate is listed as CSSMERR_TP_NOT_TRUSTED, which
    // is expected: codesign signs with it all the same, and nothing that reads
    // the signature evaluates trust (see the header).
    const listing = execFileSync('security', ['find-identity', '-p', 'codesigning', keychain], { encoding: 'utf8' });
    const match = listing.match(/^\s*\d+\)\s+([0-9A-F]{40})\s/m);
    if (!match) throw new Error('[macSign] MAC_SIGN_P12 holds no code-signing identity');
    return { sha1: match[1], keychain, dispose };
  } catch (err) {
    dispose();
    throw err;
  }
}

/**
 * Collects Mach-O files under Contents/Resources.
 *
 * `codesign --deep` only reaches code in the standard nested locations
 * (Frameworks, Helpers, PlugIns, XPCServices). Native modules unpacked to
 * Resources/app.asar.unpacked sit outside those, so they are sealed as plain
 * resources and never signed. Signing them explicitly first keeps every
 * Mach-O in the bundle consistently signed across both architectures.
 *
 * @param {string} dir Directory to walk.
 * @returns {string[]} Absolute paths of Mach-O files found.
 */
function collectResourceMachO(dir) {
  if (!fs.existsSync(dir)) {
    return [];
  }

  const found = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) {
      continue;
    }
    if (entry.isDirectory()) {
      found.push(...collectResourceMachO(full));
    } else if (entry.isFile() && (entry.name.endsWith('.node') || entry.name.endsWith('.dylib'))) {
      found.push(full);
    }
  }
  return found;
}

/**
 * Signs a packaged .app bundle in place with the given codesign arguments and
 * verifies the result.
 *
 * Verification runs here rather than only in CI so an unusable bundle fails the
 * build before electron-builder packages it into a .dmg/.zip and publishes it.
 *
 * @param {string} appPath Absolute path to the .app bundle.
 * @param {string[]} signArgs codesign arguments that pick the identity.
 * @param {string} kind What the log calls this signature.
 * @returns {void}
 * @throws {Error} If signing or verification fails.
 */
function signMacApp(appPath, signArgs, kind) {
  const resourcesDir = path.join(appPath, 'Contents', 'Resources');

  for (const binary of collectResourceMachO(resourcesDir)) {
    execFileSync('codesign', [...signArgs, binary], { stdio: 'inherit' });
    console.log(`[macSign] ${kind} signed ${path.relative(appPath, binary)}`);
  }

  // `--deep` is discouraged for distribution signing because it applies one set
  // of entitlements to every nested binary. These signatures carry no
  // entitlements (no hardened runtime, nothing to notarize), so that concern
  // does not apply here, and it is the only single-pass way to seal the
  // Electron framework and helper apps.
  execFileSync('codesign', [...signArgs, '--deep', appPath], { stdio: 'inherit' });
  console.log(`[macSign] ${kind} signed bundle ${path.basename(appPath)}`);

  execFileSync('codesign', ['--verify', '--deep', '--strict', appPath], { stdio: 'inherit' });
  console.log(`[macSign] Signature verified for ${path.basename(appPath)}`);
}

/**
 * The bundle's designated requirement, as codesign prints it.
 *
 * @param {string} appPath
 * @returns {string}
 */
function designatedRequirement(appPath) {
  // codesign writes the -d report to stderr, so both streams are kept.
  const result = spawnSync('codesign', ['-d', '-r-', appPath], { encoding: 'utf8' });
  return `${result.stdout || ''}${result.stderr || ''}`;
}

/**
 * Signs with the project's certificate and checks the outcome is the stable
 * requirement the whole scheme depends on.
 *
 * @param {string} appPath
 * @param {{ p12: Buffer, password: string }} identity
 */
function stableSignMacApp(appPath, identity) {
  const { sha1, keychain, dispose } = importIdentity(identity);
  try {
    signMacApp(appPath, ['--force', '--sign', sha1, '--keychain', keychain, '--timestamp=none'], 'Stable-identity');
    const requirement = designatedRequirement(appPath);
    if (!STABLE_REQUIREMENT.test(requirement)) {
      throw new Error(`[macSign] Signed bundle has no certificate-anchored requirement:\n${requirement}`);
    }
    console.log(`[macSign] Designated requirement pinned to certificate ${sha1.toLowerCase()}`);
  } finally {
    dispose();
  }
}

/**
 * afterPack entry point. Signs the bundle unless a real identity is configured
 * or the build host cannot run codesign.
 *
 * @param {string} appPath Absolute path to the .app bundle.
 * @returns {void}
 */
function signMacAppIfUnsigned(appPath) {
  if (hasRealSigningIdentity()) {
    console.log('[macSign] Signing identity configured — leaving signing to electron-builder');
    return;
  }

  if (process.platform !== 'darwin') {
    console.warn(
      '[macSign] Cannot ad-hoc sign from a non-macOS host — this bundle will be rejected by Gatekeeper as damaged'
    );
    return;
  }

  if (!fs.existsSync(appPath)) {
    throw new Error(`[macSign] Expected app bundle at ${appPath}, but it does not exist`);
  }

  const identity = stableIdentityFromEnv();
  if (identity) {
    stableSignMacApp(appPath, identity);
    return;
  }

  if (process.env.MAC_SIGN_REQUIRED === '1') {
    throw new Error(
      '[macSign] MAC_SIGN_REQUIRED=1 but MAC_SIGN_P12 is not set: refusing to ship an ad-hoc signed build, ' +
        'it would reset every user\'s macOS permissions and strand their auto-update'
    );
  }

  console.warn(
    '[macSign] No MAC_SIGN_P12: ad-hoc signing. macOS permissions will not survive the next update and this build cannot auto-update.'
  );
  signMacApp(appPath, AD_HOC_SIGN_ARGS, 'Ad-hoc');
}

module.exports = { signMacAppIfUnsigned, STABLE_REQUIREMENT, stableIdentityFromEnv };
