import type { ChangedFile, PathHit, PipelineArea } from './types.ts';

/**
 * Which changed paths rewrite the CI pipeline itself.
 *
 * The lists below are derived from what the `pull_request` workflows in
 * `.github/workflows/` actually execute or read on a fork PR, not from a
 * generic notion of "sensitive files". `ci.yml` runs `pnpm install`,
 * `pnpm build`, `pnpm -r test` and a Docker build; `dast.yml` builds and
 * starts the container image from `deploy/`; `desktop-macos.yml` runs the
 * SwiftPM manifest and the build scripts of the native macOS client;
 * `security.yml`/`codeql.yml` read their scanner configuration from the
 * checkout. A change to any of those inputs alters what runs or what is
 * checked, so it is listed here.
 *
 * Deliberately NOT listed: application source, tests, Vite/PostCSS/vitest
 * configs, `scripts/*.mjs`. Every one of those executes on the runner too,
 * inside the test and build steps, and that is true of every PR. The
 * verdict wording accounts for it; enumerating it would make every PR
 * "read first" and the signal worthless.
 *
 * `package.json` is not a path signal either: a dependency bump is routine
 * and a new `postinstall` is not, and only the content tells them apart.
 * See `package-json.ts`.
 */
const RULES: Array<{ area: PipelineArea; test: (path: string) => boolean }> = [
  { area: 'ci', test: (p) => p.startsWith('.github/workflows/') || p.startsWith('.github/actions/') },
  {
    area: 'installTime',
    test: (p) =>
      basename(p) === '.pnpmfile.cjs' ||
      basename(p) === '.npmrc' ||
      p === 'pnpm-workspace.yaml' ||
      p.startsWith('packages/patches/'),
  },
  {
    area: 'buildRecipes',
    test: (p) =>
      // Everything the image build, the compose stack and an operator's host
      // execute: the Dockerfile and its ignore file, the compose files, the
      // Caddyfile, the entrypoint and the install/update/backup/restore/deploy
      // scripts. `.env.example` is documentation and is not listed.
      (p.startsWith('deploy/') && p !== 'deploy/.env.example') ||
      p === 'packages/desktop/electron-builder.yml' ||
      p.startsWith('packages/desktop/scripts/') ||
      // The native macOS client: its SwiftPM manifest is code the runner
      // executes before anything is compiled, and its scripts build, sign and
      // check the bundle. Its Swift sources are application source, like the
      // TypeScript of every other package.
      p === 'packages/desktop-macos/Package.swift' ||
      p.startsWith('packages/desktop-macos/scripts/'),
  },
  {
    area: 'scannerConfig',
    test: (p) =>
      p.startsWith('.github/codeql/') ||
      p.startsWith('.github/security/') ||
      p === '.gitleaks.toml',
  },
];

function basename(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash === -1 ? path : path.slice(slash + 1);
}

/**
 * Classifies every changed path, including the previous name of a rename,
 * so that renaming a workflow away (which disables it) is caught the same
 * as editing it. Order follows the input; each path appears at most once.
 */
export function classifyPaths(files: ChangedFile[]): PathHit[] {
  const seen = new Set<string>();
  const hits: PathHit[] = [];
  for (const file of files) {
    const candidates = [file.filename];
    if (file.previous_filename !== undefined && file.previous_filename !== file.filename) {
      candidates.push(file.previous_filename);
    }
    for (const path of candidates) {
      if (seen.has(path)) continue;
      seen.add(path);
      const rule = RULES.find((r) => r.test(path));
      if (rule) hits.push({ area: rule.area, path });
    }
  }
  return hits;
}

/** A `package.json` anywhere in the tree (workspace roots and packages). */
export function isPackageJson(path: string): boolean {
  return basename(path) === 'package.json';
}

/** Only the root lockfile is used by `pnpm install --frozen-lockfile`. */
export function isLockfile(path: string): boolean {
  return path === 'pnpm-lock.yaml';
}
