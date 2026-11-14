import React, { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { Highlight, themes } from 'prism-react-renderer';
import { IconButton } from '../ui/IconButton';
import { Icon } from '../ui/Icon';
import { Tag } from '../ui/Tag';
import { useFormatters } from '../../i18n/formatters';
import { detectCodeLanguage, languageLabel, normalizeCodeLanguage } from './codeLanguage';

// One Dark token colours on the block's own ground: the frame draws the
// surface, so the highlighter paints no background of its own.
const codeTheme = {
  ...themes.oneDark,
  plain: {
    ...themes.oneDark.plain,
    backgroundColor: 'transparent',
    color: 'rgb(var(--text-message))',
  },
};

/** How long the copy button shows its confirmation. */
const COPIED_FEEDBACK_MS = 1500;

/** A block of code in a message longer than this starts collapsed. */
export const CODE_COLLAPSE_AFTER_LINES = 20;
/**
 * A file's preview longer than this starts collapsed. Lower than a message's
 * block: a file is reference material the reader opens on purpose, and its
 * card should not push the conversation off the screen.
 */
export const FILE_COLLAPSE_AFTER_LINES = 6;

/**
 * How tall a collapsed body is. The last part fades out
 * (docs/brand/directions.html, `.code.clip`), which says "there is more"
 * better than a hard cut at a line.
 */
const COLLAPSED_HEIGHT: Record<'message' | 'file', string> = {
  message: 'max-h-[248px]',
  file: 'max-h-[118px]',
};
const FADE_MASK = '[mask-image:linear-gradient(#000_55%,transparent)] [-webkit-mask-image:linear-gradient(#000_55%,transparent)]';

function CopyButton({ text }: { text: string }) {
  const { t } = useTranslation('common');
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => () => {
    if (timerRef.current !== null) clearTimeout(timerRef.current);
  }, []);

  const handleCopy = () => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      if (timerRef.current !== null) clearTimeout(timerRef.current);
      timerRef.current = setTimeout(() => {
        timerRef.current = null;
        setCopied(false);
      }, COPIED_FEEDBACK_MS);
    }).catch(() => {
      // The clipboard is unavailable (insecure context or denied permission);
      // the button stays as it was so nothing claims a copy that did not happen.
    });
  };

  return (
    <IconButton
      icon={copied ? 'check' : 'copy'}
      label={copied ? t('actions.copied') : t('actions.copy')}
      size="sm"
      onClick={handleCopy}
    />
  );
}

/** A grammar's label: its colour when it has one, the neutral label otherwise. */
export function LanguageTag({ grammar }: { grammar: string }) {
  const label = languageLabel(grammar);
  if (!label) return null;
  return label.color ? <Tag color={label.color}>{label.name}</Tag> : <Tag>{label.name}</Tag>;
}

/** The file a block shows, for the file header. */
export interface CodeFileInfo {
  name: string;
  /** Bytes, as stored. */
  size: number;
  /** Lines, once the contents are known. */
  lines?: number | undefined;
  /** The file's own download, owned by the attachment. */
  onDownload: () => void;
}

/** The header of a file card: the file, its language, its size, and the actions. */
export function CodeFileHeader({
  file,
  grammar,
  copyText,
  extraActions,
}: {
  file: CodeFileInfo;
  grammar: string;
  /** The whole text to copy; null while it is not loaded. */
  copyText: string | null;
  /** Buttons before copy and download (the Markdown source switch). */
  extraActions?: ReactNode;
}) {
  const { t } = useTranslation(['chat', 'common']);
  const { formatBytes } = useFormatters();
  const facts = [
    file.lines !== undefined ? t('chat:code.lines', { count: file.lines }) : null,
    formatBytes(file.size),
  ].filter((fact): fact is string => fact !== null).join(' · ');
  return (
    <>
      <Icon name="file-text" size="sm" className="flex-shrink-0 text-txt-tertiary" />
      <span className="min-w-0 truncate text-compact font-medium text-txt-primary" title={file.name}>{file.name}</span>
      <LanguageTag grammar={grammar} />
      <span className="whitespace-nowrap tabular-nums">{facts}</span>
      <span className="ml-auto flex items-center gap-0.5 flex-shrink-0">
        {extraActions}
        {copyText !== null && <CopyButton text={copyText} />}
        <IconButton icon="download" label={t('common:actions.download')} size="sm" onClick={file.onDownload} />
      </span>
    </>
  );
}

export interface CodeFrameProps {
  /** The header row's contents, laid out in a row. */
  header: ReactNode;
  children: ReactNode;
  /** Whether the body is long enough to start collapsed. */
  collapsible: boolean;
  /** Lines in the whole text, for the "show all" row. */
  lineCount: number;
  variant: 'message' | 'file';
}

/**
 * The frame every block of code and every text file in chat is drawn in
 * (docs/brand/directions.html, `.code`): a sunken panel, a header row over a
 * hairline, the body, and — when the body is long — a fading cut-off with a
 * full-width "show all, N lines" row under it. The body changes height only
 * when the reader presses that row.
 */
export function CodeFrame({ header, children, collapsible, lineCount, variant }: CodeFrameProps) {
  const { t } = useTranslation(['chat']);
  const [expanded, setExpanded] = useState(false);
  const clipped = collapsible && !expanded;
  return (
    <div className="mt-1 w-full max-w-[640px] rounded-xl bg-surface-input shadow-[inset_0_0_0_1px_var(--glass-border)] overflow-hidden">
      <div className="flex items-center gap-2 min-h-[34px] py-[3px] pl-3 pr-1 text-2xs text-txt-tertiary shadow-[inset_0_-1px_0_var(--glass-border)]">
        {header}
      </div>
      <div
        data-testid="code-body"
        data-clipped={clipped || undefined}
        className={clipped ? `${COLLAPSED_HEIGHT[variant]} overflow-hidden ${FADE_MASK}` : ''}
      >
        {children}
      </div>
      {collapsible && (
        <button
          type="button"
          aria-expanded={expanded}
          onClick={() => setExpanded((value) => !value)}
          className="w-full h-8 flex items-center justify-center text-xs font-medium text-txt-secondary hover:text-txt-primary hover:bg-interactive-hover shadow-[inset_0_1px_0_var(--glass-border)] transition-colors duration-fast"
        >
          {expanded ? t('chat:code.collapse') : t('chat:code.showAll', { count: lineCount })}
        </button>
      )}
    </div>
  );
}

const CODE_PRE = 'm-0 px-3 py-2.5 text-compact leading-[1.65] font-mono overflow-x-auto';

/** Highlighted code, or plain text for a grammar the block does not have. */
export function CodeBody({ grammar, code }: { grammar: string; code: string }) {
  if (grammar === 'text') {
    return (
      <pre className={`${CODE_PRE} whitespace-pre text-txt-message`}>
        <code>{code}</code>
      </pre>
    );
  }
  return (
    <Highlight theme={codeTheme} code={code} language={grammar}>
      {({ style, tokens, getLineProps, getTokenProps }) => (
        <pre className={CODE_PRE} style={{ ...style, margin: 0 }}>
          {tokens.map((line, i) => {
            const lineProps = getLineProps({ line });
            return (
              <div key={i} {...lineProps} style={{ ...lineProps.style, minHeight: '1.65em' }}>
                {line.map((token, key) => (
                  <span key={key} {...getTokenProps({ token })} />
                ))}
              </div>
            );
          })}
        </pre>
      )}
    </Highlight>
  );
}

/** How many lines a text has, not counting the newline that ends the last one. */
export function countLines(text: string): number {
  if (text.length === 0) return 0;
  return text.replace(/\n$/, '').split('\n').length;
}

export interface CodeBlockProps {
  /** The fence's language tag, or 'text' when the author gave none. */
  language: string;
  code: string;
  /** Set when the block shows a file: the header then names the file. */
  file?: CodeFileInfo | undefined;
}

/**
 * A block of code in chat.
 *
 * - The fence's tag is normalised (```mjs is JavaScript); a block with no tag
 *   is guessed by `detectCodeLanguage`, and the header says the language was
 *   detected. When nothing matches it renders as plain text with no label.
 * - A long block starts collapsed behind a fade; copy always takes all of it.
 * - With `file`, the header is the file's: name, language, lines and size,
 *   copy and download.
 */
export function CodeBlock({ language, code, file }: CodeBlockProps) {
  const { t } = useTranslation(['chat']);
  const normalized = normalizeCodeLanguage(language);
  const detected = useMemo(
    () => (normalized === 'text' && !file ? detectCodeLanguage(code) : null),
    [normalized, file, code],
  );
  const grammar = detected ?? normalized;
  const lineCount = useMemo(() => countLines(code), [code]);
  const variant = file ? 'file' : 'message';
  const collapsible = lineCount > (file ? FILE_COLLAPSE_AFTER_LINES : CODE_COLLAPSE_AFTER_LINES);

  const header = file ? (
    <CodeFileHeader file={{ ...file, lines: lineCount }} grammar={grammar} copyText={code} />
  ) : (
    <>
      <LanguageTag grammar={grammar} />
      {detected && <span className="truncate">{t('chat:code.autoDetected')}</span>}
      <span className="ml-auto flex-shrink-0">
        <CopyButton text={code} />
      </span>
    </>
  );

  return (
    <CodeFrame header={header} collapsible={collapsible} lineCount={lineCount} variant={variant}>
      <CodeBody grammar={grammar} code={code} />
    </CodeFrame>
  );
}

export const MemoizedCodeBlock = React.memo(CodeBlock);
