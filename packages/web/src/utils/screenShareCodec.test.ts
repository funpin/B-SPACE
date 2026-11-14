import { afterEach, describe, expect, it } from 'vitest';
import {
  detectCodecPlatform,
  isScreenShareCodecChoice,
  isSoftwareH264Encoder,
  noteSoftwareH264,
  resetSoftwareH264ForTest,
  resolveScreenShareCodec,
} from './screenShareCodec';

afterEach(() => resetSoftwareH264ForTest());

describe('resolveScreenShareCodec', () => {
  it('keeps an explicit choice whatever the platform', () => {
    expect(resolveScreenShareCodec('vp9', 'mac', false)).toBe('vp9');
    expect(resolveScreenShareCodec('h264', 'linux', false)).toBe('h264');
    expect(resolveScreenShareCodec('h264', 'mac', true)).toBe('h264');
  });

  it('picks hardware H264 under Auto where the platform has it', () => {
    for (const platform of ['mac', 'windows', 'ios', 'android'] as const) {
      expect(resolveScreenShareCodec('auto', platform, false)).toBe('h264');
    }
  });

  it('keeps VP9 under Auto where hardware H264 is not the rule', () => {
    expect(resolveScreenShareCodec('auto', 'linux', false)).toBe('vp9');
    expect(resolveScreenShareCodec('auto', 'other', false)).toBe('vp9');
  });

  it('goes back to VP9 under Auto once H264 was seen in software this session', () => {
    expect(resolveScreenShareCodec('auto', 'mac')).toBe('h264');
    noteSoftwareH264();
    expect(resolveScreenShareCodec('auto', 'mac')).toBe('vp9');
    expect(sessionStorage.getItem('b-space:screen-share-software-h264')).toBe('1');
  });
});

describe('detectCodecPlatform', () => {
  it('trusts the desktop bridge first', () => {
    expect(detectCodecPlatform({ desktopPlatform: 'darwin', userAgent: 'Windows NT' })).toBe('mac');
    expect(detectCodecPlatform({ desktopPlatform: 'win32' })).toBe('windows');
    expect(detectCodecPlatform({ desktopPlatform: 'linux' })).toBe('linux');
  });

  it('reads the browser otherwise', () => {
    expect(detectCodecPlatform({ userAgentDataPlatform: 'macOS' })).toBe('mac');
    expect(detectCodecPlatform({ platform: 'Win32' })).toBe('windows');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (X11; Linux x86_64)' })).toBe('linux');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' })).toBe('ios');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (Linux; Android 15)' })).toBe('android');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' })).toBe('windows');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' })).toBe('mac');
    expect(detectCodecPlatform({ userAgent: 'Mozilla/5.0 (darwin) AppleWebKit/537.36 jsdom/26.0.0' })).toBe('other');
    expect(detectCodecPlatform({})).toBe('other');
  });
});

describe('isSoftwareH264Encoder', () => {
  it('recognises OpenH264 and nothing else', () => {
    expect(isSoftwareH264Encoder('OpenH264')).toBe(true);
    expect(isSoftwareH264Encoder('SimulcastEncoderAdapter (OpenH264, OpenH264)')).toBe(true);
    expect(isSoftwareH264Encoder('VideoToolbox')).toBe(false);
    expect(isSoftwareH264Encoder('MediaFoundationVideoEncodeAccelerator')).toBe(false);
    expect(isSoftwareH264Encoder(null)).toBe(false);
  });
});

describe('isScreenShareCodecChoice', () => {
  it('accepts the three choices only', () => {
    expect(['auto', 'vp9', 'h264'].every(isScreenShareCodecChoice)).toBe(true);
    expect(isScreenShareCodecChoice('vp8')).toBe(false);
    expect(isScreenShareCodecChoice(undefined)).toBe(false);
  });
});
