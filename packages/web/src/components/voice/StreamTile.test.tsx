import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render } from '@testing-library/react';
import { StreamTile } from './StreamTile';
import { useVoiceStore } from '../../stores/voiceStore';
import { useContextMenuStore, type ContextMenuItem } from '../../stores/contextMenuStore';
import type { StreamTile as StreamTileType } from '../../hooks/useLiveKit';

vi.mock('../../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({ playSound: vi.fn() }) },
}));

vi.mock('../../hooks/useLiveKit', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../hooks/useLiveKit')>();
  return {
    ...actual,
    getActiveRoom: () => null,
    setStreamSubscription: vi.fn(),
  };
});

function streamTile(userId: string, isLocal: boolean): StreamTileType {
  return {
    kind: 'stream',
    key: `${userId}:stream`,
    participant: {
      identity: userId,
      userId,
      username: userId,
      homeUserId: null,
      isMuted: false,
      isDeafened: false,
      isCameraOn: false,
      isScreenSharing: true,
      isLocal,
      audioTrack: null,
      videoTrack: null,
      screenTrack: null,
      screenAudioTrack: null,
      lkVideoTrack: null,
      lkScreenTrack: null,
      cachedUser: null,
    } as unknown as StreamTileType['participant'],
    screenTrack: null,
    screenAudioTrack: null,
    lkScreenTrack: null,
  };
}

function openMenu(tile: StreamTileType): ContextMenuItem[] {
  const { container } = render(<StreamTile tile={tile} />);
  fireEvent.contextMenu(container.querySelector('[data-context-menu]')!);
  return useContextMenuStore.getState().menu?.items ?? [];
}

const keys = (items: ContextMenuItem[]) => items.map((item) => item.key);

beforeEach(() => {
  useContextMenuStore.setState({ menu: null });
  useVoiceStore.setState({
    watchingStreams: new Set(['bob']),
    participantMutes: new Map(),
    participantVolumes: new Map(),
    streamMutes: new Map(),
    streamVolumes: new Map(),
  });
});

describe('StreamTile context menu', () => {
  it('puts the sharer’s own volume right above the stream volume', () => {
    const order = keys(openMenu(streamTile('bob', false)));

    expect(order).toContain('user-volume');
    expect(order.indexOf('user-volume')).toBe(order.indexOf('stream-volume') - 1);
  });

  it('offers muting the sharer next to muting the stream', () => {
    const items = openMenu(streamTile('bob', false));
    const order = keys(items);
    expect(order.indexOf('mute-user')).toBe(order.indexOf('mute-stream') - 1);

    const muteUser = items.find((item) => item.key === 'mute-user');
    if (muteUser?.type !== 'checkbox') throw new Error('mute-user is not a checkbox');
    muteUser.onChange(true);

    expect(useVoiceStore.getState().participantMutes.get('bob')).toBe(true);
    expect(useVoiceStore.getState().streamMutes.get('bob') ?? false).toBe(false);
  });

  it('shows no per-user sound controls on your own stream', () => {
    const order = keys(openMenu(streamTile('me', true)));

    expect(order).not.toContain('user-volume');
    expect(order).not.toContain('mute-user');
  });
});

describe('StreamTile while its sharer has no picture to send', () => {
  function paused(userId: string, isLocal: boolean): StreamTileType {
    const tile = streamTile(userId, isLocal);
    return { ...tile, participant: { ...tile.participant, screenSharePaused: true } };
  }

  it('says so to a viewer who is watching, in place of the offer to watch', () => {
    const { getByTestId, container } = render(<StreamTile tile={paused('bob', false)} stats={null} />);

    expect(getByTestId('stream-tile-paused').textContent).toContain('bob');
    expect(container.querySelector('[data-testid="stream-tile-placeholder"] button')).toBeNull();
  });

  it('still offers the stream to someone who is not watching it', () => {
    useVoiceStore.setState({ watchingStreams: new Set() });

    const { getByTestId, container } = render(<StreamTile tile={paused('bob', false)} stats={null} />);

    expect(getByTestId('stream-tile-paused')).toBeTruthy();
    expect(container.querySelector('[data-testid="stream-tile-placeholder"] button')).not.toBeNull();
  });

  it('tells the sharer that viewers do not see the window', () => {
    const { getByTestId, queryByTestId } = render(<StreamTile tile={paused('me', true)} stats={null} />);

    expect(getByTestId('stream-tile-paused-own')).toBeTruthy();
    expect(queryByTestId('stream-tile-paused')).toBeNull();
  });

  it('says nothing of it for a share that has a picture', () => {
    const { queryByTestId } = render(<StreamTile tile={streamTile('bob', false)} stats={null} />);

    expect(queryByTestId('stream-tile-paused')).toBeNull();
    expect(queryByTestId('stream-tile-paused-own')).toBeNull();
  });
});
