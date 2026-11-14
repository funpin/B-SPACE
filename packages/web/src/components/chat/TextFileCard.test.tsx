import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { TextFileCard } from './TextFileCard';

// MentionBadge reads the space and UI stores at render time. Only the mention
// case touches them; stub them so the rest of the file needs no app state.
vi.mock('../../stores/spaceStore', () => ({
  useSpaceStore: (selector: (s: unknown) => unknown) =>
    selector({
      members: [],
      spaces: [],
      currentSpaceId: null,
      userViews: new Map(),
      dmChannels: [],
      dmAlternatives: new Map(),
      channelToSpaceMap: new Map(),
      channelOriginMap: new Map(),
    }),
  getApiForOrigin: vi.fn(),
  getMyUserIdForOrigin: vi.fn(),
}));
vi.mock('../../stores/authStore', () => ({
  useAuthStore: (selector: (s: unknown) => unknown) => selector({ user: null }),
}));
vi.mock('../../stores/uiStore', () => ({
  useUIStore: (selector: (s: unknown) => unknown) =>
    selector({ openUserProfile: vi.fn() }),
}));
vi.mock('../../api/client', () => ({
  api: {},
  createApiClient: vi.fn(),
}));


describe('TextFileCard', () => {
  beforeEach(() => {
    // jsdom has no IntersectionObserver: the card then loads at once.
    vi.stubGlobal('IntersectionObserver', undefined);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function serve(text: string) {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, text: () => Promise.resolve(text) }));
  }

  it('shows a code file as one card with its contents', async () => {
    serve('export const a = 1;\n');
    render(<TextFileCard url="/f/a.ts" name="a.ts" size={20} onDownload={() => {}} />);
    expect(screen.getByText('a.ts')).toBeInTheDocument();
    expect(await screen.findByText(/export/)).toBeInTheDocument();
    expect(screen.getByText(/1 line/)).toBeInTheDocument();
    // No separate "show contents" step.
    expect(screen.queryByText(/show contents/i)).toBeNull();
  });

  it('renders a Markdown file formatted, and switches to its source', async () => {
    serve('# Release notes\n\n- **fast** start\n');
    const { container } = render(<TextFileCard url="/f/notes.md" name="notes.md" size={40} onDownload={() => {}} />);
    expect(await screen.findByText('Release notes')).toBeInTheDocument();
    expect(container.querySelector('strong')?.textContent).toBe('fast');

    fireEvent.click(screen.getByRole('button', { name: /show source/i }));
    expect(container.querySelector('pre')?.textContent).toContain('# Release notes');
    expect(screen.getByRole('button', { name: /show formatted/i })).toBeInTheDocument();
  });

  it('says when the file could not be read, and keeps the download', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 404, text: () => Promise.resolve('') }));
    const onDownload = vi.fn();
    render(<TextFileCard url="/f/a.txt" name="a.txt" size={10} onDownload={onDownload} />);
    await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /download/i }));
    expect(onDownload).toHaveBeenCalled();
  });
});
