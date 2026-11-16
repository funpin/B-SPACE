import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ConnectionError } from 'livekit-client';
import {
  VOICE_CONNECT_FAILURE_REASONS,
  VOICE_HEARTBEAT_INTERVAL_MS,
  resolveVoiceConnectionMark,
} from '@backspace/shared/src/voiceConnection';

const mocks = vi.hoisted(() => ({
  wsSend: vi.fn(),
  channelOrigin: vi.fn<(channelId: string) => string>(() => ''),
}));
vi.mock('../hooks/useWebSocket', () => ({ wsSend: mocks.wsSend }));
vi.mock('../stores/spaceStore', () => ({ getChannelOrigin: (channelId: string) => mocks.channelOrigin(channelId) }));

import {
  announceVoiceAttempt,
  classifyConnectFailure,
  resetVoiceLinkForTest,
  startVoiceHeartbeat,
  stopVoiceHeartbeat,
  useVoiceLinkStore,
  voiceAttemptCompleted,
} from './voiceLink';
import { describeVoiceConnectionMark, voiceConnectFailureText } from './voiceConnectionText';

const HOME = '';
const REMOTE = 'https://remote.example';

beforeEach(() => {
  vi.useFakeTimers();
  mocks.wsSend.mockReset();
  mocks.channelOrigin.mockReturnValue(HOME);
  resetVoiceLinkForTest();
});

afterEach(() => {
  resetVoiceLinkForTest();
  vi.useRealTimers();
});

describe('classifyConnectFailure', () => {
  it('names a failure before the room as a token failure, whatever was thrown', () => {
    expect(classifyConnectFailure(new Error('503'), 'token')).toBe('token_failed');
    expect(classifyConnectFailure(ConnectionError.notAllowed('no', 401), 'token')).toBe('token_failed');
  });

  it('tells a media path that did not come up from a server that did not answer', () => {
    expect(classifyConnectFailure(ConnectionError.internal('could not establish pc connection'), 'room'))
      .toBe('media_unreachable');
    expect(classifyConnectFailure(new Error('could not establish publisher connection, state: failed'), 'room'))
      .toBe('media_unreachable');
    expect(classifyConnectFailure(ConnectionError.serverUnreachable('could not establish signal connection'), 'room'))
      .toBe('server_unreachable');
    expect(classifyConnectFailure(ConnectionError.timeout('room connection has timed out (signal)'), 'room'))
      .toBe('server_unreachable');
    expect(classifyConnectFailure(ConnectionError.websocket('Encountered websocket error during connection establishment'), 'room'))
      .toBe('server_unreachable');
  });

  it('names a refusal, and falls back to the general reason for the rest', () => {
    expect(classifyConnectFailure(ConnectionError.notAllowed('invalid token', 401), 'room')).toBe('not_allowed');
    expect(classifyConnectFailure(ConnectionError.internal('Unexpected first message'), 'room')).toBe('connect_failed');
    expect(classifyConnectFailure(new Error('anything'), 'room')).toBe('connect_failed');
    expect(classifyConnectFailure('a string', 'room')).toBe('connect_failed');
  });
});

describe('announceVoiceAttempt', () => {
  it('says nothing to an instance that does not relay attempts', () => {
    announceVoiceAttempt('voice-1', 'connecting');
    announceVoiceAttempt('voice-1', 'failed', 'not_allowed');
    announceVoiceAttempt(null, 'idle');

    expect(mocks.wsSend).not.toHaveBeenCalled();
  });

  it('reports the attempt, its failure with the reason, and its end', () => {
    useVoiceLinkStore.getState().setHost(HOME, true);

    announceVoiceAttempt('voice-1', 'connecting');
    announceVoiceAttempt('voice-1', 'failed', 'media_unreachable');
    announceVoiceAttempt(null, 'idle');
    announceVoiceAttempt(null, 'idle');

    expect(mocks.wsSend.mock.calls).toEqual([
      [{ type: 'voice_connecting', channelId: 'voice-1', state: 'connecting' }, HOME],
      [{ type: 'voice_connecting', channelId: 'voice-1', state: 'failed', reason: 'media_unreachable' }, HOME],
      [{ type: 'voice_connecting', channelId: 'voice-1', state: 'idle' }, HOME],
    ]);
  });

  it('ends an attempt on one instance before starting one on another', () => {
    useVoiceLinkStore.getState().setHost(HOME, true);
    useVoiceLinkStore.getState().setHost(REMOTE, true);

    announceVoiceAttempt('voice-1', 'connecting');
    mocks.channelOrigin.mockReturnValue(REMOTE);
    announceVoiceAttempt('voice-9', 'connecting');

    expect(mocks.wsSend.mock.calls.slice(1)).toEqual([
      [{ type: 'voice_connecting', channelId: 'voice-1', state: 'idle' }, HOME],
      [{ type: 'voice_connecting', channelId: 'voice-9', state: 'connecting' }, REMOTE],
    ]);
  });

  it('has nothing to end once the join completed the attempt', () => {
    useVoiceLinkStore.getState().setHost(HOME, true);
    announceVoiceAttempt('voice-1', 'connecting');
    voiceAttemptCompleted();
    mocks.wsSend.mockClear();

    announceVoiceAttempt(null, 'idle');

    expect(mocks.wsSend).not.toHaveBeenCalled();
  });
});

describe('voice heartbeat', () => {
  it('beats at once and then on the interval, until stopped', () => {
    useVoiceLinkStore.getState().setHost(HOME, true);

    startVoiceHeartbeat(HOME);
    expect(mocks.wsSend).toHaveBeenCalledTimes(1);
    expect(mocks.wsSend).toHaveBeenLastCalledWith({ type: 'voice_heartbeat' }, HOME);

    vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS * 3);
    expect(mocks.wsSend).toHaveBeenCalledTimes(4);

    stopVoiceHeartbeat();
    vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS * 3);
    expect(mocks.wsSend).toHaveBeenCalledTimes(4);
  });

  it('never beats to an instance that would answer each beat with an error', () => {
    startVoiceHeartbeat(HOME);
    vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS * 3);

    expect(mocks.wsSend).not.toHaveBeenCalled();
  });

  it('keeps one timer when started again', () => {
    useVoiceLinkStore.getState().setHost(HOME, true);
    startVoiceHeartbeat(HOME);
    startVoiceHeartbeat(HOME);
    mocks.wsSend.mockClear();

    vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS);

    expect(mocks.wsSend).toHaveBeenCalledTimes(1);
  });
});

describe('the mark a row shows', () => {
  it('is none when nothing is wrong', () => {
    expect(resolveVoiceConnectionMark({})).toBeNull();
    expect(resolveVoiceConnectionMark({ quality: 'good' })).toBeNull();
    expect(resolveVoiceConnectionMark({ quality: 'unknown', connecting: null })).toBeNull();
  });

  it('is the most serious of the troubles that apply', () => {
    const everything = {
      connecting: 'connecting' as const,
      quality: 'lost' as const,
      isUnresponsive: true,
      isReconnecting: true,
      isMicUnavailable: true,
    };
    expect(resolveVoiceConnectionMark({ ...everything, connecting: 'failed' })).toBe('failed');
    expect(resolveVoiceConnectionMark(everything)).toBe('unresponsive');
    expect(resolveVoiceConnectionMark({ ...everything, isUnresponsive: false })).toBe('reconnecting');
    expect(resolveVoiceConnectionMark({ quality: 'lost', isMicUnavailable: true })).toBe('lost');
    expect(resolveVoiceConnectionMark({ quality: 'poor', isMicUnavailable: true })).toBe('mic-unavailable');
    expect(resolveVoiceConnectionMark({ quality: 'poor' })).toBe('weak');
    expect(resolveVoiceConnectionMark({ connecting: 'connecting' })).toBe('connecting');
  });
});

describe('the words for a mark', () => {
  it('has a sentence for every reason but the general one', () => {
    for (const reason of VOICE_CONNECT_FAILURE_REASONS) {
      const text = voiceConnectFailureText(reason);
      if (reason === 'connect_failed') expect(text).toBeNull();
      else expect(text, reason).toMatch(/\.$/);
    }
    expect(voiceConnectFailureText(null)).toBeNull();
  });

  it('speaks of "you" on the own row and by name on anyone else\'s', () => {
    expect(describeVoiceConnectionMark('lost', { isSelf: true, name: 'Ada' })).toBe('Your connection dropped');
    expect(describeVoiceConnectionMark('lost', { isSelf: false, name: 'Ada' })).toBe('Ada lost connection');
    expect(describeVoiceConnectionMark('connecting', { isSelf: true, name: 'Ada' })).toBe('Connecting…');
  });

  it('adds the reason to a failure when there is one to give', () => {
    expect(describeVoiceConnectionMark('failed', { isSelf: false, name: 'Ada', reason: 'not_allowed' }))
      .toBe('Ada could not connect. The server refused the connection.');
    expect(describeVoiceConnectionMark('failed', { isSelf: false, name: 'Ada', reason: 'connect_failed' }))
      .toBe('Ada could not connect.');
    expect(describeVoiceConnectionMark('failed', { isSelf: true, name: 'Ada' })).toBe('Could not connect.');
  });
});
