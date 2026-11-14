import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Button } from '../ui/Button';
import { useAutoGrowTextarea } from '../../hooks/useAutoGrowTextarea';
import { useUIStore } from '../../stores/uiStore';

/** The editor grows with its text up to half the viewport, then scrolls inside. */
export const EDITOR_MAX_HEIGHT_CLASS = 'max-h-[calc(50*var(--app-vh))]';

interface MessageEditorProps {
  /** The message text the editor opens with. A new value (the message changed elsewhere) replaces what is in the box. */
  initialContent: string;
  /** Receives the trimmed, non-empty text. The editor stays open until the caller closes it. */
  onSave: (content: string) => Promise<void> | void;
  onCancel: () => void;
}

/**
 * The inline editor of a message: a box as tall as the text in it, and a row
 * under it with the keyboard hint and the Cancel and Save buttons.
 * Enter saves, Shift+Enter starts a new line, Escape cancels.
 */
export function MessageEditor({ initialContent, onSave, onCancel }: MessageEditorProps) {
  const { t } = useTranslation(['chat', 'common']);
  const isMobile = useUIStore((s) => s.isMobile);
  const [content, setContent] = useState(initialContent);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  useAutoGrowTextarea(textareaRef, content);

  // Open with the caret after the last character, the place an edit usually starts.
  useEffect(() => {
    setContent(initialContent);
    const frame = requestAnimationFrame(() => {
      const textarea = textareaRef.current;
      if (!textarea) return;
      textarea.focus();
      textarea.setSelectionRange(initialContent.length, initialContent.length);
    });
    return () => cancelAnimationFrame(frame);
  }, [initialContent]);

  const trimmed = content.trim();
  const save = async () => {
    if (trimmed) await onSave(trimmed);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // The Enter that confirms an IME composition belongs to the IME.
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      void save();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      onCancel();
    }
  };

  return (
    <div className="mt-1 w-full">
      <textarea
        ref={textareaRef}
        value={content}
        onChange={(e) => setContent(e.target.value)}
        onKeyDown={handleKeyDown}
        aria-label={t('chat:message.edit.label')}
        className={`input-standard block w-full p-3 rounded-lg resize-none overflow-y-auto text-sm leading-[21px] ${EDITOR_MAX_HEIGHT_CLASS}`}
        rows={1}
      />
      <div className="mt-2 flex items-center gap-2">
        {!isMobile && (
          <p className="flex-1 min-w-0 text-xs text-txt-tertiary">{t('chat:message.edit.hint')}</p>
        )}
        <div className="ml-auto flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={onCancel}>
            {t('common:actions.cancel')}
          </Button>
          <Button variant="primary" size="sm" onClick={() => void save()} disabled={!trimmed}>
            {t('common:actions.save')}
          </Button>
        </div>
      </div>
    </div>
  );
}
