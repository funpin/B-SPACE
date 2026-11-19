import { act, cleanup, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Room, RoomEvent, DisconnectReason, Track, ConnectionState, ConnectionQuality } from 'livekit-client';
import { useLiveKit, setStreamSubscription } from './useLiveKit';
import { useVoiceStore } from '../stores/voiceStore';
import { streamQualityKey } from '../utils/streamParticipant';

/**
 * A native client publishes its screen share through a second LiveKit
 * participant, the user's stream participant (docs/systems/voice.md, "The
 * stream participant"). A viewer never sees that participant: its share is
 * its owner's share, in the list, the tiles, the watch state and the
 * subscription.
 */

const mocks = vi.hoisted(() => ({
  token: vi.fn(),
  connect: vi.fn(), disconnect: vi.fn(),
  audio: {
    releaseInputStream: vi.fn(), resumeContext: vi.fn(),
    setVoiceProcessing: vi.fn(), setRnnoiseEnabled: vi.fn(),
    setInputDevice: vi.fn(), setInputVolume: vi.fn(),
    onResumed: vi.fn(() => vi.fn()), onInputTrackEnded: vi.fn(() => vi.fn()),
    getStreamGeneration: () => 1, getFreshTrack: () => null,
    playSound: vi.fn(),
  },
  space: {
    channelToSpaceMap: new Map<string, string>(),
    members: [] as unknown[],
    dmChannels: [] as { id: string; members: { id: string; homeUserId?: string }[] }[],
  },
}));
vi.mock('livekit-client', async importOriginal => {
  const sdk = await importOriginal<typeof import('livekit-client')>();
  return { ...sdk, Room: class extends sdk.Room {
    connect = mocks.connect;
    disconnect = mocks.disconnect;
  } };
});
vi.mock('../audio/AudioManager', () => ({ AudioManager: { getInstance: () => mocks.audio } }));
vi.mock('../audio/SpeakingDetector', () => ({
  SpeakingDetector: { getInstance: () => ({ clear: vi.fn(), syncTracks: vi.fn() }) },
}));
vi.mock('./useWebSocket', () => ({ wsSend: vi.fn() }));
vi.mock('../utils/voice', () => ({ broadcastVoiceStatus: vi.fn(), clearSpaceVoiceForDmCall: vi.fn() }));
vi.mock('../utils/hwOverdrive', () => ({ activate: vi.fn(), deactivate: vi.fn() }));
vi.mock('../stores/spaceStore', () => ({
  getApiForOrigin: () => ({ livekit: { token: mocks.token, dmToken: mocks.token } }),
  getChannelOrigin: () => '', getMyUserIdForOrigin: () => 'me',
  useSpaceStore: { getState: () => mocks.space },
}));

const OWNER = 'bob:Bob';
const STREAM = 'stream.bob:Bob';

interface FakeTrack {
  kind: Track.Kind;
  mediaStreamTrack: { id: string; readyState: 'live' };
  detach: ReturnType<typeof vi.fn>;
}

interface FakePublication {
  source: Track.Source;
  trackSid: string;
  track: FakeTrack | undefined;
  isMuted: boolean;
  isSubscribed: boolean;
  setSubscribed: ReturnType<typeof vi.fn>;
}

function makePublication(source: Track.Source, trackSid: string): FakePublication {
  return { source, trackSid, track: undefined, isMuted: false, isSubscribed: false, setSubscribed: vi.fn() };
}

function join(room: Room, identity: string, attributes: Record<string, string> = {}) {
  const trackPublications = new Map<string, FakePublication>();
  const participant = { identity, attributes, trackPublications, isMicrophoneEnabled: true, isCameraEnabled: false };
  (room.remoteParticipants as Map<string, unknown>).set(identity, participant);
  act(() => { room.emit(RoomEvent.ParticipantConnected, participant as never); });
  return participant;
}

type Joined = ReturnType<typeof join>;

const joinOwner = (room: Room) => join(room, OWNER);
const joinStream = (room: Room, owner = OWNER) => join(room, STREAM, { streamOf: owner });

function publish(room: Room, from: Joined, source: Track.Source, trackSid: string): FakePublication {
  const pub = makePublication(source, trackSid);
  from.trackPublications.set(trackSid, pub);
  act(() => { room.emit(RoomEvent.TrackPublished, pub as never, from as never); });
  return pub;
}

/** The subscription arriving: the publication has a live track now. */
function subscribe(room: Room, from: Joined, pub: FakePublication, kind: Track.Kind): FakeTrack {
  const track: FakeTrack = { kind, mediaStreamTrack: { id: `mst-${pub.trackSid}`, readyState: 'live' }, detach: vi.fn() };
  pub.track = track;
  pub.isSubscribed = true;
  act(() => { room.emit(RoomEvent.TrackSubscribed, track as never, pub as never, from as never); });
  return track;
}

/** A participant leaving, in livekit-client's order (Room.handleParticipantDisconnected). */
function leave(room: Room, who: Joined): void {
  (room.remoteParticipants as Map<string, unknown>).delete(who.identity);
  for (const pub of [...who.trackPublications.values()]) {
    who.trackPublications.delete(pub.trackSid);
    act(() => { room.emit(RoomEvent.TrackUnpublished, pub as never, who as never); });
  }
  act(() => { room.emit(RoomEvent.ParticipantDisconnected, who as never); });
}

async function viewerRoom(): Promise<Room> {
  const { result } = renderHook(() => useLiveKit());
  await act(async () => { await result.current.connect('channel'); });
  const room = result.current.room!;
  (room as { state: ConnectionState }).state = ConnectionState.Connected;
  vi.spyOn(room.localParticipant, 'publishData').mockResolvedValue(undefined);
  return room;
}

const listed = () => useVoiceStore.getState().participants.filter((p) => !p.isLocal);
const owner = () => listed().find((p) => p.identity === OWNER);

beforeEach(() => {
  vi.clearAllMocks();
  mocks.token.mockResolvedValue({ token: 'test', url: 'wss://example.invalid' });
  mocks.audio.resumeContext.mockResolvedValue(undefined);
  mocks.audio.setRnnoiseEnabled.mockResolvedValue(undefined);
  mocks.audio.setInputDevice.mockResolvedValue(null);
  mocks.connect.mockResolvedValue(undefined);
  mocks.disconnect.mockImplementation(async function (this: Room) {
    this.emit(RoomEvent.Disconnected, DisconnectReason.CLIENT_INITIATED);
  });
  mocks.space.dmChannels = [];
  useVoiceStore.setState({ ...useVoiceStore.getInitialState(), isMuted: false });
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('a stream participant in the room', () => {
  it('is not listed, and its share is its owner\'s share', async () => {
    const room = await viewerRoom();
    joinOwner(room);
    const stream = joinStream(room);
    expect(listed().map((p) => p.identity)).toEqual([OWNER]);
    expect(owner()?.isScreenSharing).toBe(false);

    publish(room, stream, Track.Source.ScreenShare, 'TR_V');

    expect(listed().map((p) => p.identity)).toEqual([OWNER]);
    expect(owner()).toMatchObject({ userId: 'bob', username: 'Bob', isScreenSharing: true });
  });

  it('gives its owner the tracks a viewer subscribed to', async () => {
    const room = await viewerRoom();
    joinOwner(room);
    const stream = joinStream(room);
    const video = publish(room, stream, Track.Source.ScreenShare, 'TR_V');
    const sound = publish(room, stream, Track.Source.ScreenShareAudio, 'TR_A');
    expect(owner()?.screenTrack).toBeNull();

    const videoTrack = subscribe(room, stream, video, Track.Kind.Video);
    const soundTrack = subscribe(room, stream, sound, Track.Kind.Audio);

    expect(owner()?.screenTrack).toBe(videoTrack.mediaStreamTrack);
    expect(owner()?.lkScreenTrack).toBe(videoTrack);
    expect(owner()?.screenAudioTrack).toBe(soundTrack.mediaStreamTrack);
    // The sound is played by the client's own renderer, not by LiveKit's element.
    expect(soundTrack.detach).toHaveBeenCalled();
  });

  it('is nobody on the list while its owner is not in the room', async () => {
    const room = await viewerRoom();
    const stream = joinStream(room);
    publish(room, stream, Track.Source.ScreenShare, 'TR_V');
    expect(listed()).toEqual([]);

    joinOwner(room);
    expect(owner()?.isScreenSharing).toBe(true);
  });

  it('is told neither which shares this client watches nor that it is deafened', async () => {
    const room = await viewerRoom();
    useVoiceStore.setState({ isDeafened: true });
    joinStream(room);
    expect(room.localParticipant.publishData).not.toHaveBeenCalled();
  });

  it('never has anything but a share subscribed to', async () => {
    const room = await viewerRoom();
    joinOwner(room);
    const stream = joinStream(room);
    const voice = publish(room, stream, Track.Source.Microphone, 'TR_M');
    const camera = publish(room, stream, Track.Source.Camera, 'TR_C');
    expect(voice.setSubscribed).not.toHaveBeenCalled();
    expect(camera.setSubscribed).not.toHaveBeenCalled();
    expect(owner()?.isCameraOn).toBe(false);
  });

  it('keeps its connection quality apart from its owner\'s', async () => {
    const room = await viewerRoom();
    const person = joinOwner(room);
    const stream = joinStream(room);
    act(() => {
      room.emit(RoomEvent.ConnectionQualityChanged, ConnectionQuality.Excellent, person as never);
      room.emit(RoomEvent.ConnectionQualityChanged, ConnectionQuality.Poor, stream as never);
    });
    const qualities = useVoiceStore.getState().connectionQualities;
    expect(qualities.get(OWNER)).toBe('excellent');
    expect(qualities.get(streamQualityKey(OWNER))).toBe('poor');
    expect(qualities.has(STREAM)).toBe(false);
  });
});

describe('watching a share published through a stream participant', () => {
  async function sharing() {
    const room = await viewerRoom();
    const person = joinOwner(room);
    const stream = joinStream(room);
    const video = publish(room, stream, Track.Source.ScreenShare, 'TR_V');
    return { room, person, stream, video };
  }

  it('subscribes to the stream participant\'s publications by the owner\'s identity', async () => {
    const { room, stream, video } = await sharing();
    const sound = publish(room, stream, Track.Source.ScreenShareAudio, 'TR_A');
    expect(video.setSubscribed).not.toHaveBeenCalled();

    setStreamSubscription(room, OWNER, true);
    expect(video.setSubscribed).toHaveBeenCalledWith(true);
    expect(sound.setSubscribed).toHaveBeenCalledWith(true);

    setStreamSubscription(room, OWNER, false);
    expect(video.setSubscribed).toHaveBeenLastCalledWith(false);
    expect(sound.setSubscribed).toHaveBeenLastCalledWith(false);
  });

  it('takes in the sound that is turned on in the middle of the share', async () => {
    const { room, stream } = await sharing();
    useVoiceStore.getState().watchStream('bob');

    const sound = publish(room, stream, Track.Source.ScreenShareAudio, 'TR_A');

    expect(sound.setSubscribed).toHaveBeenCalledWith(true);
  });

  it('leaves the sound of a share it does not watch alone', async () => {
    const { room, stream } = await sharing();
    const sound = publish(room, stream, Track.Source.ScreenShareAudio, 'TR_A');
    expect(sound.setSubscribed).not.toHaveBeenCalled();
  });

  it('ends the watch when the share is unpublished', async () => {
    const { room, stream, video } = await sharing();
    useVoiceStore.getState().watchStream('bob');
    useVoiceStore.getState().setStreamVolume('bob', 150);
    useVoiceStore.getState().recordStreamWatch(OWNER, 'carol:Carol', true);

    stream.trackPublications.delete(video.trackSid);
    act(() => { room.emit(RoomEvent.TrackUnpublished, video as never, stream as never); });

    const state = useVoiceStore.getState();
    expect(state.watchingStreams.has('bob')).toBe(false);
    expect(state.streamVolumes.has('bob')).toBe(false);
    expect(state.streamWatchers.has(OWNER)).toBe(false);
    expect(owner()?.isScreenSharing).toBe(false);
  });

  it('ends the watch when the stream participant leaves, and its owner stays', async () => {
    const { room, stream } = await sharing();
    useVoiceStore.getState().watchStream('bob');
    // Somebody watches a share of the local user: a leaving stream participant is not a viewer leaving.
    useVoiceStore.getState().recordStreamWatch('me:Me', 'carol:Carol', true);

    leave(room, stream);

    const state = useVoiceStore.getState();
    expect(state.watchingStreams.has('bob')).toBe(false);
    expect(listed().map((p) => p.identity)).toEqual([OWNER]);
    expect(owner()?.isScreenSharing).toBe(false);
    expect(state.streamWatchers.get('me:Me')?.has('carol:Carol')).toBe(true);
  });

  it('ends the watch when the owner leaves and the stream participant is still publishing', async () => {
    const { room, person } = await sharing();
    useVoiceStore.getState().watchStream('bob');
    useVoiceStore.getState().setStreamMute('bob', true);

    leave(room, person);

    const state = useVoiceStore.getState();
    expect(listed()).toEqual([]);
    expect(state.watchingStreams.has('bob')).toBe(false);
    expect(state.streamMutes.has('bob')).toBe(false);
  });

  it('keeps the watch across a republish the owner announced', async () => {
    const { room, person, stream, video } = await sharing();
    useVoiceStore.getState().watchStream('bob');
    const announce = new TextEncoder().encode(JSON.stringify({ type: 'stream_republish' }));
    act(() => { room.emit(RoomEvent.DataReceived, announce, person as never); });

    stream.trackPublications.delete(video.trackSid);
    act(() => { room.emit(RoomEvent.TrackUnpublished, video as never, stream as never); });
    expect(useVoiceStore.getState().watchingStreams.has('bob')).toBe(true);
    expect(owner()?.isScreenSharing).toBe(true);

    const next = publish(room, stream, Track.Source.ScreenShare, 'TR_V2');
    expect(next.setSubscribed).toHaveBeenCalledWith(true);
  });
});

describe('a share published by the participant itself', () => {
  it('is still its share: nothing changes for a client that has no stream participant', async () => {
    const room = await viewerRoom();
    const person = joinOwner(room);
    const video = publish(room, person, Track.Source.ScreenShare, 'TR_V');
    expect(owner()?.isScreenSharing).toBe(true);

    setStreamSubscription(room, OWNER, true);
    expect(video.setSubscribed).toHaveBeenCalledWith(true);
  });
});

describe('this client\'s own share, published by its shell', () => {
  const ME = 'me:Me';

  async function sharingFromTheShell() {
    const room = await viewerRoom();
    (room.localParticipant as { identity: string }).identity = ME;
    const stream = join(room, `stream.${ME}`, { streamOf: ME });
    return { room, stream };
  }

  const me = () => useVoiceStore.getState().participants.find((p) => p.isLocal);

  it('is the local participant\'s share, watched for the local tile', async () => {
    const { room, stream } = await sharingFromTheShell();
    expect(listed()).toEqual([]);
    expect(me()?.isScreenSharing).toBe(false);

    const video = publish(room, stream, Track.Source.ScreenShare, 'TR_V');

    expect(listed()).toEqual([]);
    expect(me()?.isScreenSharing).toBe(true);
    expect(video.setSubscribed).toHaveBeenCalledWith(true);
    expect(useVoiceStore.getState().watchingStreams.has('me')).toBe(true);

    const track = subscribe(room, stream, video, Track.Kind.Video);
    expect(me()?.screenTrack).toBe(track.mediaStreamTrack);
  });

  it('never has its sound fetched back', async () => {
    const { room, stream } = await sharingFromTheShell();
    publish(room, stream, Track.Source.ScreenShare, 'TR_V');
    const sound = publish(room, stream, Track.Source.ScreenShareAudio, 'TR_A');
    expect(sound.setSubscribed).not.toHaveBeenCalled();

    setStreamSubscription(room, ME, true);
    expect(sound.setSubscribed).not.toHaveBeenCalled();

    // Letting go is never refused.
    setStreamSubscription(room, ME, false);
    expect(sound.setSubscribed).toHaveBeenCalledWith(false);
  });

  it('is unwatched when it is unpublished', async () => {
    const { room, stream } = await sharingFromTheShell();
    const video = publish(room, stream, Track.Source.ScreenShare, 'TR_V');
    stream.trackPublications.delete(video.trackSid);
    act(() => { room.emit(RoomEvent.TrackUnpublished, video as never, stream as never); });
    expect(useVoiceStore.getState().watchingStreams.has('me')).toBe(false);
  });
});

