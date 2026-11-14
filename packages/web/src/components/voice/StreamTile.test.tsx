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
