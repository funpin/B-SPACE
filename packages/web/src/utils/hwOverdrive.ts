// packages/web/src/utils/hwOverdrive.ts
//
// Self-contained SDP profile override for hardware H.264 encoding.
// Zero imports from our codebase — operates at the WebRTC API layer.

let _active = false;
let _originalCreateOffer: typeof RTCPeerConnection.prototype.createOffer | null = null;

function rewriteSdp(sdp: string): string {
  return sdp.replace(/profile-level-id=(42e01f|42c01f)/gi, 'profile-level-id=4d0032');
}

/**
 * Whether the override belongs on this engine: Chromium only.
 *
 * Chromium offers H.264 Constrained Baseline and picks its hardware encoder
 * for the rewritten Main profile. WebKit (Safari, the native macOS client)
 * encodes H.264 in hardware as it is and refuses the rewritten offer:
 * `setLocalDescription` fails with "Failed to set local video description recv
 * parameters", the negotiation is lost, and LiveKit drops the participant from
 * the call the moment a share is published. Firefox has no hardware H.264 to
 * select. An engine is Chromium when its user agent names a Chrome or Chromium
 * version; Chrome on iOS is WebKit and names `CriOS` instead.
 */
export function appliesTo(userAgent: string | null | undefined): boolean {
  return /\b(?:Chrome|Chromium)\/\d/.test(userAgent ?? '');
}

/**
 * Activate the SDP profile override.
 * Patches RTCPeerConnection.prototype.createOffer to rewrite
 * H.264 Constrained Baseline (42e01f/42c01f) → Main Profile (4d0032).
 * No-op if already active, and on an engine it does not belong on
 * (`appliesTo`).
 */
export function activate(): void {
  if (_active) return;
  if (!appliesTo(typeof navigator === 'undefined' ? null : navigator.userAgent)) return;

  _originalCreateOffer = RTCPeerConnection.prototype.createOffer;
  _active = true;

  // RTCPeerConnection.prototype.createOffer has two overloads in the WebRTC typings.
  // We cast through unknown to satisfy TypeScript while keeping the runtime shape correct.
  const patched: typeof RTCPeerConnection.prototype.createOffer = async function (
    this: RTCPeerConnection,
    options?: RTCOfferOptions,
  ): Promise<RTCSessionDescriptionInit> {
    const offer = await (_originalCreateOffer as (options?: RTCOfferOptions) => Promise<RTCSessionDescriptionInit>).call(this, options);
    if (_active && offer.sdp) {
      return { type: offer.type, sdp: rewriteSdp(offer.sdp) };
    }
    return offer;
  } as unknown as typeof RTCPeerConnection.prototype.createOffer;

  RTCPeerConnection.prototype.createOffer = patched;
}

/**
 * Deactivate the SDP profile override.
 * Restores the original createOffer prototype. No-op if not active.
 */
export function deactivate(): void {
  if (!_active) return;
  if (_originalCreateOffer) {
    RTCPeerConnection.prototype.createOffer = _originalCreateOffer;
    _originalCreateOffer = null;
  }
  _active = false;
}

/** Check if the SDP override is currently active. */
export function isActive(): boolean {
  return _active;
}
