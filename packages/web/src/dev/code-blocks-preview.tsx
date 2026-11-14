// Design workbench for code in chat: fenced blocks and text-file cards, as
// docs/brand/directions.html draws them. Nothing in the app imports this
// file; `dev-code-blocks.html` is its page (Vite dev server only).
//
// `?lang=ru` shows the Russian catalog.
import { createRoot } from 'react-dom/client';
import { MemoryRouter } from 'react-router-dom';
import { CodeBlock } from '../components/chat/CodeBlock';
import { TextFileCard } from '../components/chat/TextFileCard';
import { initI18n } from '../i18n';
import i18n from '../i18n';
import { initializeInterfaceScale } from '../platform/interfaceScale';
import '../styles/globals.css';

const BUILD_LOG = [
  'vite v8.0.2 building for production...',
  'transforming (1842) src/components/voice/VoiceGrid.tsx',
  '2114 modules transformed.',
  'dist/index.html                    1.92 kB | gzip:   0.84 kB',
  'dist/assets/index-C4kQ1x9a.css    96.40 kB | gzip:  15.71 kB',
  'dist/assets/index-BqT7n2Lw.js  1,512.33 kB | gzip: 455.10 kB',
  'built in 9.84s',
  ...Array.from({ length: 207 }, (_, i) => `  packaging       step=${i + 1} platform=darwin arch=arm64`),
].join('\n');

const VOICE_HEALTH = `/** Thresholds shared by the ping graph and the connection rows. */
export const VOICE_HEALTH = {
  pingWarnMs: 120,
  pingBadMs: 250,
  lossWarn: 0.02,
  lossBad: 0.08,
} as const;

export type HealthBand = 'good' | 'warn' | 'bad';
`;

const RELEASE_NOTES = `# Release notes 2.3.0

Pointers now show **over the sharer's screen** in the desktop app.

## Fixed

- Black picture when returning to an H.264 share
- Fullscreen keeps no empty band under the picture

| Area | Change |
| ---- | ------ |
| Voice | keyframe watchdog |
| Chat | one card per text file |

\`\`\`ts
export const ok = true;
\`\`\`
`;

const FILES: Record<string, string> = {
  '/f/pasted.txt': BUILD_LOG,
  '/f/voiceHealth.ts': VOICE_HEALTH,
  '/f/release-notes.md': RELEASE_NOTES,
};

window.fetch = (input: RequestInfo | URL) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.pathname : input.url;
  const body = FILES[url];
  return Promise.resolve(body === undefined
    ? new Response('', { status: 404 })
    : new Response(body, { status: 200 }));
};

const size = (text: string) => new TextEncoder().encode(text).length;

function Workbench() {
  return (
    <div className="bg-surface-chat min-h-screen p-6 flex flex-col gap-6 max-w-[760px]">
      <section>
        <p className="text-sm text-txt-message">Fenced, with a tag written as an extension (```mjs):</p>
        <CodeBlock language="mjs" code={'async function readPrecacheSettings() {\n  const { module } = await runnerImport(limitModule);\n  return module.PRECACHE_MAX_FILE_BYTES;\n}'} />
      </section>
      <section>
        <p className="text-sm text-txt-message">Fenced, no tag (detected):</p>
        <CodeBlock language="text" code={'{ "ping": 38, "loss": 0.002, "protocol": "udp" }'} />
      </section>
      <section>
        <p className="text-sm text-txt-message">Long paste as a file:</p>
        <TextFileCard url="/f/pasted.txt" name="pasted.txt" size={size(BUILD_LOG)} onDownload={() => {}} />
      </section>
      <section>
        <p className="text-sm text-txt-message">Code file:</p>
        <TextFileCard url="/f/voiceHealth.ts" name="voiceHealth.ts" size={size(VOICE_HEALTH)} onDownload={() => {}} />
      </section>
      <section>
        <p className="text-sm text-txt-message">Markdown file:</p>
        <TextFileCard url="/f/release-notes.md" name="release-notes.md" size={size(RELEASE_NOTES)} onDownload={() => {}} />
      </section>
      <section>
        <p className="text-sm text-txt-message">Unreadable file:</p>
        <TextFileCard url="/f/missing.log" name="missing.log" size={2048} onDownload={() => {}} />
      </section>
    </div>
  );
}

async function start(): Promise<void> {
  const host = document.getElementById('root');
  if (!host) throw new Error('missing #root');
  initializeInterfaceScale();
  await initI18n();
  const lang = new URLSearchParams(window.location.search).get('lang');
  if (lang) await i18n.changeLanguage(lang);
  createRoot(host).render(
    <MemoryRouter>
      <Workbench />
    </MemoryRouter>,
  );
}

void start();
