import { createPortal } from 'react-dom';
import { useTranslation } from 'react-i18next';
import { useWindowFileDrop, type WindowFileDropState } from '../../hooks/useWindowFileDrop';
import { usePortalContainer } from '../../hooks/usePortalContainer';
import { Icon } from '../ui/Icon';

/**
 * What the window shows while files are dragged over it: a scrim, a dashed
 * edge around the window, and a glass card naming where the files will go,
 * or saying they cannot be attached there. Purely visual: it never takes
 * pointer events, so the drag keeps hitting the element underneath.
 */
export function FileDropOverlay({ state }: { state: Exclude<WindowFileDropState, { kind: 'idle' }> }) {
  const { t } = useTranslation('chat');
  const accept = state.kind === 'accept';
  return (
    <div
      className="pointer-events-none fixed inset-0 z-modal flex bg-surface-overlay p-3 animate-fade-in"
      data-testid="file-drop-overlay"
      data-state={state.kind}
    >
      <div
        className={`flex flex-1 items-center justify-center rounded-2xl border-2 border-dashed ${accept ? 'border-accent-tone' : 'border-status-danger'}`}
      >
        <div role="status" className="glass-modal flex max-w-sm flex-col items-center gap-2 rounded-2xl px-6 py-5 text-center">
          <span
            className={`mb-1 flex h-12 w-12 items-center justify-center rounded-xl ${accept ? 'bg-accent-primary text-on-accent' : 'glass-pill text-status-danger'}`}
          >
            <Icon name={accept ? 'upload' : 'ban'} size="lg" />
          </span>
          <p className="text-lg font-semibold text-txt-primary">
            {accept ? t('fileDrop.title') : t('fileDrop.deniedTitle')}
          </p>
          <p className="text-sm text-txt-secondary">
            {accept ? t('fileDrop.hint', { name: state.label }) : t('fileDrop.deniedHint', { name: state.label })}
          </p>
        </div>
      </div>
    </div>
  );
}

/** Mounted once by the app shell: wires the window-level file drop and draws its overlay. */
export function WindowFileDrop() {
  const state = useWindowFileDrop();
  const portalContainer = usePortalContainer();
  if (state.kind === 'idle') return null;
  return createPortal(<FileDropOverlay state={state} />, portalContainer);
}
