import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { activate, appliesTo, deactivate, isActive } from './hwOverdrive';

const CHROME = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
const ELECTRON = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) B-SPACE/2.3.2 Chrome/138.0.7204.251 Electron/43.0.0 Safari/537.36';
const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15';
const NATIVE_MAC = `${SAFARI} BSpaceDesktop/2.3.2`;
const CHROME_ON_IOS = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/138.0.7204.156 Mobile/15E148 Safari/604.1';
const FIREFOX = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0';

const OFFER = [
  'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f',
  'a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42C01F',
  'a=fmtp:100 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f',
].join('\r\n');

describe('the H.264 profile override', () => {
  let original: () => Promise<RTCSessionDescriptionInit>;

  beforeEach(() => {
    original = vi.fn(async () => ({ type: 'offer' as const, sdp: OFFER }));
    // The test environment has no WebRTC; the override only needs the prototype.
    vi.stubGlobal('RTCPeerConnection', class {});
    RTCPeerConnection.prototype.createOffer = original as typeof RTCPeerConnection.prototype.createOffer;
  });
  afterEach(() => {
    deactivate();
    vi.unstubAllGlobals();
  });

  function asEngine(userAgent: string): void {
    vi.stubGlobal('navigator', { userAgent });
  }

  it('belongs on Chromium, in a browser and in the Electron app', () => {
    expect(appliesTo(CHROME)).toBe(true);
    expect(appliesTo(ELECTRON)).toBe(true);
  });

  it('does not belong on WebKit or Firefox', () => {
    expect(appliesTo(SAFARI)).toBe(false);
    expect(appliesTo(NATIVE_MAC)).toBe(false);
    // Chrome on iOS is WebKit underneath.
    expect(appliesTo(CHROME_ON_IOS)).toBe(false);
    expect(appliesTo(FIREFOX)).toBe(false);
    expect(appliesTo('')).toBe(false);
    expect(appliesTo(null)).toBe(false);
  });

  it('rewrites Constrained Baseline to Main in a Chromium offer, and nothing else', async () => {
    asEngine(ELECTRON);
    activate();
    expect(isActive()).toBe(true);
    const offer = await new RTCPeerConnection().createOffer();
    expect(offer.sdp).toBe([
      'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d0032',
      'a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=4d0032',
      'a=fmtp:100 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f',
    ].join('\r\n'));
  });

  it('leaves the offer of the native macOS client alone', async () => {
    asEngine(NATIVE_MAC);
    activate();
    expect(isActive()).toBe(false);
    expect(RTCPeerConnection.prototype.createOffer).toBe(original);
    const offer = await new RTCPeerConnection().createOffer();
    expect(offer.sdp).toBe(OFFER);
  });

  it('puts the engine\'s own createOffer back when it is switched off', async () => {
    asEngine(CHROME);
    activate();
    expect(RTCPeerConnection.prototype.createOffer).not.toBe(original);
    deactivate();
    expect(isActive()).toBe(false);
    expect(RTCPeerConnection.prototype.createOffer).toBe(original);
  });

  it('is switched on once, however often it is asked', () => {
    asEngine(CHROME);
    activate();
    const patched = RTCPeerConnection.prototype.createOffer;
    activate();
    expect(RTCPeerConnection.prototype.createOffer).toBe(patched);
    deactivate();
    expect(RTCPeerConnection.prototype.createOffer).toBe(original);
  });
});
