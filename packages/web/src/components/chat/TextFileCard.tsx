import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { IconButton } from '../ui/IconButton';
import {
  CodeBody,
  CodeFileHeader,
  CodeFrame,
  countLines,
  FILE_COLLAPSE_AFTER_LINES,
  CODE_COLLAPSE_AFTER_LINES,
  type CodeFileInfo,
} from './CodeBlock';
import { languageOfFilename } from './codeLanguage';
import { MarkdownRenderer } from './MarkdownRenderer';

/** How much of a text file the card reads; the rest stays in the download. */
export const PREVIEW_MAX_CHARS = 64 * 1024;
/** How far below or above the screen a card starts loading, so it is ready when scrolled to. */
const LOAD_MARGIN = '600px 0px';

type LoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'failed' }
  | { status: 'ready'; text: string; truncated: boolean };

/**
 * Reads the file once the card comes near the screen. A chat full of text
 * files therefore fetches only what the reader scrolls to, and a card the
 * reader is looking at is already filled.
 */
function useTextFile(url: string, target: React.RefObject<HTMLElement | null>): LoadState {
  const [state, setState] = useState<LoadState>({ status: 'idle' });

  useEffect(() => {
    const element = target.current;
    if (!element) return;
    let cancelled = false;
    let started = false;

    const load = (): void => {
      if (started) return;
      started = true;
      setState({ status: 'loading' });
      fetch(url)
        .then((response) => {
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          return response.text();
        })
        .then((text) => {
          if (cancelled) return;
          const truncated = text.length > PREVIEW_MAX_CHARS;
          setState({ status: 'ready', text: truncated ? text.slice(0, PREVIEW_MAX_CHARS) : text, truncated });
        })
        .catch(() => {
          if (!cancelled) setState({ status: 'failed' });
        });
    };

    if (typeof IntersectionObserver === 'undefined') {
      load();
      return () => { cancelled = true; };
    }
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        load();
      }
    }, { rootMargin: LOAD_MARGIN });
    observer.observe(element);
    return () => {
      cancelled = true;
      observer.disconnect();
    };
  }, [url, target]);

  return state;
}

function isMarkdown(grammar: string): boolean {
  return grammar === 'markdown';
}

interface TextFileCardProps {
  url: string;
  name: string;
  size: number;
  onDownload: () => void;
}

/**
 * A text file in chat, as one card (docs/brand/directions.html): the file's
 * name, language, lines and size with copy and download in the header, and its
 * contents under it, collapsed behind a fade when long.
 *
 * A Markdown file is shown formatted, as the message renderer formats a
 * message, with a switch to its source in the header.
 *
 * While the file loads, the body holds the height of a collapsed preview, so a
 * long file — the usual case for a file worth attaching — fills its card
 * without moving the conversation. A short one shrinks to its text once.
 */
export function TextFileCard({ url, name, size, onDownload }: TextFileCardProps) {
  const { t } = useTranslation(['chat']);
  const cardRef = useRef<HTMLDivElement>(null);
  const state = useTextFile(url, cardRef);
  const grammar = languageOfFilename(name);
  const markdown = isMarkdown(grammar);
  const [showSource, setShowSource] = useState(false);

  const text = state.status === 'ready' ? state.text : null;
  const lineCount = text !== null ? countLines(text) : 0;
  const file: CodeFileInfo = { name, size, lines: text !== null ? lineCount : undefined, onDownload };
  const rendered = markdown && !showSource;

  const sourceSwitch = markdown && text !== null ? (
    <IconButton
      icon={showSource ? 'eye' : 'code'}
      label={showSource ? t('chat:attachment.preview.showRendered') : t('chat:attachment.preview.showSource')}
      size="sm"
      onClick={() => setShowSource((value) => !value)}
    />
  ) : null;

  const header = <CodeFileHeader file={file} grammar={grammar} copyText={text} extraActions={sourceSwitch} />;

  let body: React.ReactNode;
  if (state.status === 'failed') {
    body = <p role="alert" className="px-3 py-2.5 text-xs text-status-danger">{t('chat:attachment.preview.failed')}</p>;
  } else if (text === null) {
    body = (
      <div className="h-[118px] px-3 py-2.5" aria-busy="true">
        <span className="sr-only">{t('chat:attachment.preview.loading')}</span>
        <div className="flex flex-col gap-2.5 pt-1 animate-pulse" aria-hidden="true">
          <div className="h-2.5 w-2/3 rounded bg-surface-elevated" />
          <div className="h-2.5 w-1/2 rounded bg-surface-elevated" />
          <div className="h-2.5 w-3/4 rounded bg-surface-elevated" />
          <div className="h-2.5 w-2/5 rounded bg-surface-elevated" />
        </div>
      </div>
    );
  } else if (rendered) {
    body = (
      <div className="px-4 py-3 text-sm text-txt-message break-words [overflow-wrap:anywhere]">
        <MarkdownRenderer content={text} />
      </div>
    );
  } else {
    body = <CodeBody grammar={grammar} code={text} />;
  }

  // Formatted Markdown reads like a message, so it gets a message's room before the fade.
  const variant = rendered ? 'message' : 'file';
  const collapsible = text !== null && lineCount > (rendered ? CODE_COLLAPSE_AFTER_LINES : FILE_COLLAPSE_AFTER_LINES);

  return (
    <div ref={cardRef} className="max-w-full min-w-0">
      <CodeFrame header={header} collapsible={collapsible} lineCount={lineCount} variant={variant}>
        {body}
      </CodeFrame>
      {state.status === 'ready' && state.truncated && (
        <p className="mt-1 text-xs text-txt-tertiary">{t('chat:attachment.preview.truncated')}</p>
      )}
    </div>
  );
}
