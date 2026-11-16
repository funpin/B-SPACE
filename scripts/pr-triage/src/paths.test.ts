import { describe, it, expect } from 'vitest';
import { classifyPaths, isLockfile, isPackageJson } from './paths.ts';
import type { ChangedFile } from './types.ts';

function files(...names: string[]): ChangedFile[] {
  return names.map((filename) => ({ filename, status: 'modified' }));
}

describe('classifyPaths', () => {
  it('returns nothing for ordinary source and docs changes', () => {
    const hits = classifyPaths(
      files('README.md', 'packages/web/src/utils/screenShare.ts', 'docs/systems/voice.md', 'scripts/check-i18n.mjs'),
    );
    expect(hits).toEqual([]);
  });

  it('puts workflow and composite action files under ci', () => {
    const hits = classifyPaths(files('.github/workflows/ci.yml', '.github/actions/setup/action.yml'));
    expect(hits).toEqual([
      { area: 'ci', path: '.github/workflows/ci.yml' },
      { area: 'ci', path: '.github/actions/setup/action.yml' },
    ]);
  });

  it('does not treat other .github files as ci', () => {
    expect(classifyPaths(files('.github/dependabot.yml', '.github/PULL_REQUEST_TEMPLATE.md'))).toEqual([]);
  });

  it('puts install-time configuration under installTime', () => {
    const hits = classifyPaths(
      files('.pnpmfile.cjs', 'packages/web/.pnpmfile.cjs', '.npmrc', 'packages/server/.npmrc', 'pnpm-workspace.yaml', 'packages/patches/uiohook-napi@1.5.5.patch'),
    );
    expect(hits.map((h) => h.area)).toEqual(['installTime', 'installTime', 'installTime', 'installTime', 'installTime', 'installTime']);
  });

  it('does not classify package.json by path; its content decides', () => {
    expect(classifyPaths(files('package.json', 'packages/desktop/package.json'))).toEqual([]);
    expect(isPackageJson('package.json')).toBe(true);
    expect(isPackageJson('packages/desktop/package.json')).toBe(true);
    expect(isPackageJson('packages/desktop/package.json.bak')).toBe(false);
    expect(isPackageJson('scripts/metrics/package-lock.json')).toBe(false);
  });

  it('puts container, deploy and desktop build files under buildRecipes', () => {
    const names = [
      'deploy/Dockerfile',
      'deploy/Dockerfile.dockerignore',
      'deploy/Dockerfile.dev',
      'deploy/docker-compose.yml',
      'deploy/docker-compose.proxy.yml',
      'deploy/docker-entrypoint.sh',
      'deploy/Caddyfile',
      'deploy/install.sh',
      'deploy/update.sh',
      'deploy/migrate-layout.sh',
      'deploy/backup.sh',
      'deploy/restore.sh',
      'deploy/deploy.sh',
      'packages/desktop/electron-builder.yml',
      'packages/desktop/scripts/afterPack.js',
      'packages/desktop-macos/Package.swift',
      'packages/desktop-macos/scripts/bundle.sh',
      'packages/desktop-macos/scripts/sign.sh',
    ];
    const hits = classifyPaths(files(...names));
    expect(hits.map((h) => h.path)).toEqual(names);
    expect(new Set(hits.map((h) => h.area))).toEqual(new Set(['buildRecipes']));
  });

  it('leaves the documented env example and files that only share a name alone', () => {
    expect(classifyPaths(files('deploy/.env.example', 'Dockerfile', 'docker-compose.yml', 'install.sh'))).toEqual([]);
    expect(classifyPaths(files(
      'packages/desktop-macos/Sources/BSpaceCore/NavigationPolicy.swift',
      'packages/desktop-macos/contract/harness.html',
      'Package.swift',
    ))).toEqual([]);
  });

  it('puts scanner configuration under scannerConfig', () => {
    const names = [
      '.github/codeql/codeql-config.yml',
      '.github/security/osv-scanner.toml',
      '.github/security/trivyignore',
      '.github/security/zap-rules.tsv',
      '.gitleaks.toml',
    ];
    const hits = classifyPaths(files(...names));
    expect(hits.map((h) => h.path)).toEqual(names);
    expect(new Set(hits.map((h) => h.area))).toEqual(new Set(['scannerConfig']));
  });

  it('classifies the previous name of a renamed file too', () => {
    const hits = classifyPaths([
      { filename: '.github/workflows/security.txt', status: 'renamed', previous_filename: '.github/workflows/security.yml' },
    ]);
    expect(hits).toEqual([
      { area: 'ci', path: '.github/workflows/security.txt' },
      { area: 'ci', path: '.github/workflows/security.yml' },
    ]);
  });

  it('classifies removed files', () => {
    expect(classifyPaths([{ filename: '.github/workflows/codeql.yml', status: 'removed' }])).toEqual([
      { area: 'ci', path: '.github/workflows/codeql.yml' },
    ]);
  });

  it('reports each path once even when it matches twice', () => {
    const hits = classifyPaths([
      { filename: '.github/workflows/ci.yml', status: 'renamed', previous_filename: '.github/workflows/ci.yml' },
    ]);
    expect(hits).toHaveLength(1);
  });

  it('is not fooled by a directory that merely contains a magic name', () => {
    expect(classifyPaths(files('docs/Dockerfile.md', 'packages/web/src/Caddyfile.ts', 'notes/.npmrc.md'))).toEqual([]);
  });

  it('recognises the lockfile, which gets its own analysis', () => {
    expect(isLockfile('pnpm-lock.yaml')).toBe(true);
    expect(isLockfile('packages/web/pnpm-lock.yaml')).toBe(false);
  });
});
