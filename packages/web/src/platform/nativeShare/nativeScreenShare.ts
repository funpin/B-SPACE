/**
 * The native macOS shell's own screen share, from the page's side.
 *
 * The shell publishes the share itself: it joins the call as the user's
 * stream participant (docs/systems/voice.md, "The stream participant") and
 * sends what it captures with one hardware encode. Nothing of the share
 * passes through the page: there is no MediaStream to stage, preview or
 * publish. The page asks the call's server for a stream token, tells the
 * shell what to share and how, and hears what becomes of it.
 *
 * This file is the bridge's shape and nothing else: what is staged between a
 * pick and Start, and the calls. What a share does to the call's state is in
 * utils/nativeShare.ts.
 */
import { getElectronAPI } from '../platform';

/**
 * What the stream setup screen holds between a pick and Start where the
 * shell shares: the source, previewed by the shell in a layer over the page
 * (`useNativeSharePreviewFrame` says where). Elsewhere it holds a
 * MediaStream.
 */
export interface NativeStagedShare {
  readonly kind: 'native-share';
  readonly sourceId: string;
  /** The size of the preview's picture, for its box's aspect. */
  readonly width: number;
  readonly height: number;
}

export type StagedShare = MediaStream | NativeStagedShare;

export function isNativeStagedShare(staged: StagedShare | null | undefined): staged is NativeStagedShare {
  return !!staged && (staged as NativeStagedShare).kind === 'native-share';
}

/** Why the shell refused, as it said it (`reason` of a bridge answer). */
export class NativeShareError extends Error {
  constructor(readonly reason: string) {
    super(`The shell refused the share: ${reason}`);
    // What the setup screen has words for: no permission reads as a capture
    // that was not allowed, an unsupported shell as one that is not there.
    this.name = reason === 'unsupported' ? 'NotSupportedError' : 'NativeShareError';
  }
}

/**
 * Whether this shell publishes shares itself. Whether the call the user is
 * in can take one is a separate question (`voiceStore.streamTokenSource`).
 */
export function shellCanShare(): boolean {
  const api = getElectronAPI();
  return typeof api?.startNativeScreenShare === 'function'
    && typeof api.updateNativeScreenShare === 'function'
    && typeof api.stopNativeScreenShare === 'function'
    && typeof api.onNativeScreenShareEvent === 'function'
    && typeof api.startNativeSharePreview === 'function';
}

/** Has the shell capture `sourceId` for a preview. Throws `NativeShareError`. */
export async function stageNativeShare(sourceId: string): Promise<NativeStagedShare> {
  const start = getElectronAPI()?.startNativeSharePreview;
  if (!start) throw new NativeShareError('unsupported');
  const answer = await start({ sourceId });
  if (!answer.ok) throw new NativeShareError(answer.reason);
  return { kind: 'native-share', sourceId, width: answer.width, height: answer.height };
}

/** The preview is not wanted any more: the stage was dropped, or it went live. */
export function dropNativeStage(): void {
  const api = getElectronAPI();
  api?.setNativeSharePreviewFrame?.(null);
  api?.stopNativeSharePreview?.();
}

/** Where the page's preview box is now; null hides the picture. */
export function placeNativePreview(frame: NativeSharePreviewFrame | null): void {
  getElectronAPI()?.setNativeSharePreviewFrame?.(frame);
}

export async function startShellShare(options: NativeScreenShareOptions): Promise<NativeScreenShareResult> {
  const start = getElectronAPI()?.startNativeScreenShare;
  if (!start) return { ok: false, reason: 'unsupported' };
  return start(options);
}

export async function updateShellShare(update: NativeScreenShareUpdate): Promise<NativeScreenShareResult> {
  const change = getElectronAPI()?.updateNativeScreenShare;
  if (!change) return { ok: false, reason: 'unsupported' };
  return change(update);
}

export function stopShellShare(): void {
  getElectronAPI()?.stopNativeScreenShare?.();
}

/** Subscribes to what the shell says about the share and the preview. */
export function onShellShareEvent(listener: (event: NativeScreenShareEvent) => void): () => void {
  return getElectronAPI()?.onNativeScreenShareEvent?.(listener) ?? (() => { });
}
