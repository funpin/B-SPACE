import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { WindowFileDrop } from '../components/chat/WindowFileDrop';
import { useFileDropStore, type FileDropTarget } from '../stores/fileDropStore';
import { FILE_DROP_WATCHDOG_MS } from './useWindowFileDrop';

function files(...names: string[]) {
  return { types: ['Files'], files: names.map((n) => new File(['x'], n)), dropEffect: 'none' };
}

const textDrag = { types: ['text/plain'], files: [], dropEffect: 'none' };

function Shell() {
  return (
    <>
      <div data-file-drop-surface="">
        <nav data-testid="sidebar"><span data-testid="sidebar-item">space</span></nav>
        <aside data-testid="members">members</aside>
      </div>
      <div data-testid="modal">settings</div>
      <div data-testid="own-zone" data-file-drop-zone="">sticker picker</div>
      <WindowFileDrop />
    </>
  );
}

function registerTarget(overrides: Partial<FileDropTarget> = {}): FileDropTarget {
  const target: FileDropTarget = {
    key: 'composer-test',
    channelId: 'ch-1',
    label: '#general',
    canAttach: true,
    accept: vi.fn(),
    ...overrides,
  };
  act(() => {
    useFileDropStore.getState().register(target);
  });
  return target;
}

const overlay = () => screen.queryByTestId('file-drop-overlay');

beforeEach(() => {
  useFileDropStore.setState({ targets: [] });
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  useFileDropStore.setState({ targets: [] });
});

describe('window file drop', () => {
  it('accepts a file dragged over a part of the window that is not the chat', () => {
    const target = registerTarget();
    render(<Shell />);
    const sidebar = screen.getByTestId('sidebar-item');

    fireEvent.dragEnter(sidebar, { dataTransfer: files('a.png') });
    const over = files('a.png');
    const notCancelled = fireEvent.dragOver(sidebar, { dataTransfer: over });

    expect(notCancelled).toBe(false);
    expect(over.dropEffect).toBe('copy');
    expect(overlay()).toHaveAttribute('data-state', 'accept');
    expect(screen.getByRole('status')).toHaveTextContent('#general');

    const drop = files('a.png', 'b.txt');
    fireEvent.drop(sidebar, { dataTransfer: drop });

    expect(target.accept).toHaveBeenCalledTimes(1);
    const handed = vi.mocked(target.accept).mock.calls[0]![0];
    expect(Array.from(handed.files).map((f) => f.name)).toEqual(['a.png', 'b.txt']);
    expect(overlay()).toBeNull();
  });

  it('keeps file drags away from the in-page drag handlers', () => {
    registerTarget();
    const inner = vi.fn();
    render(
      <div data-file-drop-surface="" onDrop={inner} onDragOver={inner}>
        <span data-testid="row">row</span>
        <WindowFileDrop />
      </div>,
    );
    fireEvent.dragOver(screen.getByTestId('row'), { dataTransfer: files('a.png') });
    fireEvent.drop(screen.getByTestId('row'), { dataTransfer: files('a.png') });
    expect(inner).not.toHaveBeenCalled();
  });

  it('ignores a drag that carries no files', () => {
    const target = registerTarget();
    const reorder = vi.fn();
    render(
      <div data-file-drop-surface="" onDrop={reorder}>
        <span data-testid="row">row</span>
        <WindowFileDrop />
      </div>,
    );
    const row = screen.getByTestId('row');

    fireEvent.dragEnter(row, { dataTransfer: textDrag });
    const notCancelled = fireEvent.dragOver(row, { dataTransfer: textDrag });
    fireEvent.drop(row, { dataTransfer: textDrag });

    expect(notCancelled).toBe(true);
    expect(overlay()).toBeNull();
    expect(reorder).toHaveBeenCalledTimes(1);
    expect(target.accept).not.toHaveBeenCalled();
  });

  it('refuses a drop when no conversation is open, without letting the browser open the file', () => {
    render(<Shell />);
    const sidebar = screen.getByTestId('sidebar');

    fireEvent.dragEnter(sidebar, { dataTransfer: files('a.png') });
    const over = files('a.png');
    const notCancelled = fireEvent.dragOver(sidebar, { dataTransfer: over });
    const dropNotCancelled = fireEvent.drop(sidebar, { dataTransfer: files('a.png') });

    expect(notCancelled).toBe(false);
    expect(over.dropEffect).toBe('none');
    expect(dropNotCancelled).toBe(false);
    expect(overlay()).toBeNull();
  });

  it('says so and refuses the drop where the user may not attach files', () => {
    const target = registerTarget({ canAttach: false });
    render(<Shell />);
    const members = screen.getByTestId('members');

    fireEvent.dragEnter(members, { dataTransfer: files('a.png') });
    const over = files('a.png');
    fireEvent.dragOver(members, { dataTransfer: over });

    expect(over.dropEffect).toBe('none');
    expect(overlay()).toHaveAttribute('data-state', 'denied');
    expect(screen.getByRole('status')).toHaveTextContent('#general');

    expect(fireEvent.drop(members, { dataTransfer: files('a.png') })).toBe(false);
    expect(target.accept).not.toHaveBeenCalled();
  });

  it('refuses a drop over a modal outside the app shell', () => {
    const target = registerTarget();
    render(<Shell />);
    const modal = screen.getByTestId('modal');

    fireEvent.dragEnter(modal, { dataTransfer: files('a.png') });
    const over = files('a.png');
    expect(fireEvent.dragOver(modal, { dataTransfer: over })).toBe(false);
    expect(over.dropEffect).toBe('none');
    expect(overlay()).toBeNull();

    expect(fireEvent.drop(modal, { dataTransfer: files('a.png') })).toBe(false);
    expect(target.accept).not.toHaveBeenCalled();
  });

  it('leaves an element with its own file drop handling alone', () => {
    const target = registerTarget();
    const own = vi.fn();
    render(<Shell />);
    const zone = screen.getByTestId('own-zone');
    zone.addEventListener('drop', own);

    expect(fireEvent.dragOver(zone, { dataTransfer: files('a.png') })).toBe(true);
    fireEvent.drop(zone, { dataTransfer: files('a.png') });

    expect(own).toHaveBeenCalledTimes(1);
    expect(target.accept).not.toHaveBeenCalled();
    expect(overlay()).toBeNull();
  });

  it('drops to the composer registered last and falls back when it unmounts', () => {
    const first = registerTarget({ key: 'a', label: '#first' });
    let unregister = () => {};
    act(() => {
      unregister = useFileDropStore.getState().register({ key: 'b', channelId: 'ch-2', label: '#second', canAttach: true, accept: vi.fn() });
    });
    act(() => unregister());
    render(<Shell />);
    fireEvent.drop(screen.getByTestId('sidebar'), { dataTransfer: files('a.png') });
    expect(first.accept).toHaveBeenCalledTimes(1);
  });

  describe('resetting', () => {
    it('hides the overlay when the drag leaves the window, counting nested enters', () => {
      registerTarget();
      render(<Shell />);
      const sidebar = screen.getByTestId('sidebar');
      const item = screen.getByTestId('sidebar-item');

      fireEvent.dragEnter(sidebar, { dataTransfer: files('a.png') });
      fireEvent.dragEnter(item, { dataTransfer: files('a.png') });
      fireEvent.dragLeave(sidebar, { dataTransfer: files('a.png') });
      expect(overlay()).not.toBeNull();

      fireEvent.dragLeave(item, { dataTransfer: files('a.png') });
      expect(overlay()).toBeNull();
    });

    it('hides the overlay when the drag is cancelled', () => {
      registerTarget();
      render(<Shell />);
      const sidebar = screen.getByTestId('sidebar');
      fireEvent.dragEnter(sidebar, { dataTransfer: files('a.png') });
      expect(overlay()).not.toBeNull();
      fireEvent.dragEnd(sidebar);
      expect(overlay()).toBeNull();
    });

    it('hides the overlay when dragover stops arriving without a dragleave', () => {
      vi.useFakeTimers();
      registerTarget();
      render(<Shell />);
      const sidebar = screen.getByTestId('sidebar');
      fireEvent.dragEnter(sidebar, { dataTransfer: files('a.png') });
      act(() => vi.advanceTimersByTime(FILE_DROP_WATCHDOG_MS - 100));
      fireEvent.dragOver(sidebar, { dataTransfer: files('a.png') });
      act(() => vi.advanceTimersByTime(FILE_DROP_WATCHDOG_MS - 100));
      expect(overlay()).not.toBeNull();
      act(() => vi.advanceTimersByTime(200));
      expect(overlay()).toBeNull();
    });
  });
});
