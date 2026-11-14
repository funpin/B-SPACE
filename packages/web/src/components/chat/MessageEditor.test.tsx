import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { MessageEditor, EDITOR_MAX_HEIGHT_CLASS } from './MessageEditor';
import { useUIStore } from '../../stores/uiStore';

// jsdom lays nothing out, so scrollHeight is 0. The editor reads it to fit
// the box to its text; give it a height that follows the line count.
const LINE = 21;
let scrollHeightSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  useUIStore.setState({ isMobile: false });
  scrollHeightSpy = vi.spyOn(HTMLTextAreaElement.prototype, 'scrollHeight', 'get')
    .mockImplementation(function (this: HTMLTextAreaElement) {
      return this.value.split('\n').length * LINE + 24;
    });
});

afterEach(() => {
  scrollHeightSpy.mockRestore();
});

function setup(initialContent = 'hello') {
  const onSave = vi.fn<(content: string) => Promise<void>>().mockResolvedValue(undefined);
  const onCancel = vi.fn();
  render(<MessageEditor initialContent={initialContent} onSave={onSave} onCancel={onCancel} />);
  const textarea = screen.getByRole('textbox', { name: 'Edit message' }) as HTMLTextAreaElement;
  return { onSave, onCancel, textarea };
}

describe('MessageEditor', () => {
  it('opens as tall as the text it holds', () => {
    const { textarea } = setup('one\ntwo\nthree\nfour\nfive\nsix');
    expect(textarea.style.height).toBe(`${6 * LINE + 24}px`);
  });

  it('grows and shrinks with the text as it is typed', () => {
    const { textarea } = setup('one');
    expect(textarea.style.height).toBe(`${LINE + 24}px`);
    fireEvent.change(textarea, { target: { value: 'one\ntwo\nthree' } });
    expect(textarea.style.height).toBe(`${3 * LINE + 24}px`);
    fireEvent.change(textarea, { target: { value: 'one' } });
    expect(textarea.style.height).toBe(`${LINE + 24}px`);
  });

  it('stops growing at half the viewport and scrolls beyond it', () => {
    const { textarea } = setup();
    expect(textarea.className).toContain(EDITOR_MAX_HEIGHT_CLASS);
    expect(textarea.className).toContain('overflow-y-auto');
  });

  it('saves the trimmed text from the Save button', async () => {
    const { textarea, onSave } = setup();
    fireEvent.change(textarea, { target: { value: '  edited text \n' } });
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Save' }));
    });
    expect(onSave).toHaveBeenCalledWith('edited text');
  });

  it('cancels from the Cancel button', () => {
    const { onCancel, onSave } = setup();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onSave).not.toHaveBeenCalled();
  });

  it('gives both buttons the kit size, not link text', () => {
    setup();
    for (const name of ['Save', 'Cancel']) {
      const button = screen.getByRole('button', { name });
      expect(button.className).toContain('h-7');
      expect(button.className).not.toContain('hover:underline');
    }
  });

  it('saves on Enter, keeps Shift+Enter for a new line, cancels on Escape', async () => {
    const { textarea, onSave, onCancel } = setup('text');
    fireEvent.keyDown(textarea, { key: 'Enter', shiftKey: true });
    expect(onSave).not.toHaveBeenCalled();
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' });
    });
    expect(onSave).toHaveBeenCalledWith('text');
    fireEvent.keyDown(textarea, { key: 'Escape' });
    expect(onCancel).toHaveBeenCalledTimes(1);
  });

  it('does not save on the Enter that confirms an IME composition', () => {
    const { textarea, onSave } = setup('text');
    fireEvent.keyDown(textarea, { key: 'Enter', isComposing: true });
    expect(onSave).not.toHaveBeenCalled();
  });

  it('cannot save an empty message', () => {
    const { textarea, onSave } = setup();
    fireEvent.change(textarea, { target: { value: '   ' } });
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    fireEvent.keyDown(textarea, { key: 'Enter' });
    expect(onSave).not.toHaveBeenCalled();
  });

  it('shows the keyboard hint on desktop only', () => {
    setup();
    expect(screen.getByText('Esc to cancel • Enter to save')).toBeInTheDocument();
  });

  it('leaves the keyboard hint out on mobile', () => {
    useUIStore.setState({ isMobile: true });
    setup();
    expect(screen.queryByText('Esc to cancel • Enter to save')).toBeNull();
  });
});
