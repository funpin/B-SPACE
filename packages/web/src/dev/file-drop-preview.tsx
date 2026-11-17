// Dev-only workbench for the window-wide file drop overlay. Nothing in the app
// imports this file; `dev-file-drop.html` is its only entry. Each frame is a
// miniature app window (space strip, channel list, chat, member list) with an
// overlay variant laid over it. A `transform` on the frame makes it the
// containing block of the overlay's `position: fixed`, so the real component
// renders inside the frame instead of over the whole page.
//
// A is the shipping `FileDropOverlay`; B and C are alternatives drawn here
// only, for the owner to compare. `?lang=ru` switches the copy.
import { createRoot } from 'react-dom/client';
import { useTranslation } from 'react-i18next';
import type { ReactNode } from 'react';
import { initI18n, setLanguage } from '../i18n';
import { isSupportedLanguage } from '../i18n/languages';
import { FileDropOverlay } from '../components/chat/WindowFileDrop';
import { Icon } from '../components/ui/Icon';
import '../styles/globals.css';

const LABEL = '#general';

function AppFrame({ children }: { children?: ReactNode }) {
  return (
    <div className="relative flex h-[420px] w-[760px] overflow-hidden rounded-xl bg-surface-base" style={{ transform: 'translateZ(0)' }}>
      <div className="flex w-14 flex-col items-center gap-2 bg-surface-channel pt-3">
        {[0, 1, 2, 3].map((i) => <div key={i} className="h-9 w-9 rounded-xl bg-surface-elevated" />)}
      </div>
      <div className="flex w-44 flex-col gap-2 border-r border-border-hard bg-surface-channel px-3 pt-4">
        {[60, 80, 50, 70, 65].map((w, i) => <div key={i} className="h-2.5 rounded bg-surface-elevated" style={{ width: `${w}%` }} />)}
      </div>
      <div className="flex flex-1 flex-col bg-surface-chat">
        <div className="flex h-11 items-center border-b border-border-hard px-4 text-sm font-semibold text-txt-primary">{LABEL}</div>
        <div className="flex flex-1 flex-col justify-end gap-3 px-4 pb-3">
          {[70, 45, 60].map((w, i) => (
            <div key={i} className="flex gap-2">
              <div className="h-7 w-7 rounded-full bg-surface-elevated" />
              <div className="h-2.5 rounded bg-surface-elevated" style={{ width: `${w}%` }} />
            </div>
          ))}
          <div className="glass-bubble h-10 rounded-xl" />
        </div>
      </div>
      <div className="flex w-36 flex-col gap-2 bg-surface-channel px-3 pt-4">
        {[70, 55, 80].map((w, i) => <div key={i} className="h-2.5 rounded bg-surface-elevated" style={{ width: `${w}%` }} />)}
      </div>
      {children}
    </div>
  );
}

/** B: no scrim. The window keeps its look; an accent edge and a pill above the composer say what happens. */
function VariantB() {
  const { t } = useTranslation('chat');
  return (
    <div className="pointer-events-none absolute inset-0 z-modal animate-fade-in">
      <div className="absolute inset-0 rounded-xl ring-2 ring-inset ring-accent-tone" />
      <div className="absolute inset-x-0 bottom-16 flex justify-center">
        <div className="glass flex items-center gap-2 rounded-2xl px-4 py-2.5">
          <Icon name="paperclip" size="sm" className="text-accent-tone" />
          <span className="text-sm font-semibold text-txt-primary">{t('fileDrop.title')}</span>
          <span className="text-sm text-txt-secondary">{LABEL}</span>
        </div>
      </div>
    </div>
  );
}

/** C: the whole window dims and blurs behind a large icon and two lines, no card and no edge. */
function VariantC() {
  const { t } = useTranslation('chat');
  return (
    <div className="pointer-events-none absolute inset-0 z-modal flex flex-col items-center justify-center gap-3 bg-surface-overlay backdrop-blur-sm animate-fade-in">
      <span className="flex h-16 w-16 items-center justify-center rounded-2xl bg-accent-primary text-on-accent">
        <Icon name="upload" size="lg" />
      </span>
      <p className="text-xl font-semibold text-txt-primary">{t('fileDrop.title')}</p>
      <p className="text-sm text-txt-secondary">{t('fileDrop.hint', { name: LABEL })}</p>
    </div>
  );
}

function Slot({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <span className="text-xs text-txt-tertiary">{caption}</span>
      {children}
    </div>
  );
}

function Workbench() {
  return (
    <div className="flex min-h-screen flex-col gap-10 bg-surface-chat p-10">
      <div className="flex flex-col gap-1">
        <h1 className="text-lg font-semibold text-txt-primary">Window file drop — design workbench</h1>
        <p className="max-w-2xl text-xs text-txt-secondary">
          What the window shows while files from the desktop are dragged over any part of it. A ships; B and C are alternatives.
        </p>
      </div>
      <div className="flex flex-wrap gap-10">
        <Slot caption="A · scrim, dashed edge, glass card (shipping)">
          <AppFrame><FileDropOverlay state={{ kind: 'accept', label: LABEL }} /></AppFrame>
        </Slot>
        <Slot caption="A · no permission to attach here">
          <AppFrame><FileDropOverlay state={{ kind: 'denied', label: LABEL }} /></AppFrame>
        </Slot>
        <Slot caption="B · no scrim, accent edge, pill above the composer">
          <AppFrame><VariantB /></AppFrame>
        </Slot>
        <Slot caption="C · dimmed and blurred window, no card">
          <AppFrame><VariantC /></AppFrame>
        </Slot>
      </div>
    </div>
  );
}

async function main(): Promise<void> {
  await initI18n();
  const lang = new URLSearchParams(window.location.search).get('lang');
  if (lang && isSupportedLanguage(lang)) await setLanguage(lang);
  const host = document.getElementById('root');
  if (host) createRoot(host).render(<Workbench />);
}

void main();
