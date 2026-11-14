import { useEffect } from 'react';
import { useVoiceStore } from '../../stores/voiceStore';
import { useStreamPointerStore } from '../../stores/streamPointerStore';
import { getElectronAPI } from '../../platform/platform';
import {
  currentVoiceParticipantMetaSources,
  resolveVoiceParticipantMeta,
} from '../../hooks/useVoiceParticipantMeta';
import {
  overlayPointersFor,
  resolveCssColor,
  sameOverlay,
  type OverlayPointer,
} from '../../utils/streamPointerOverlay';
import { pointerColor } from './StreamPointers';
import type { ParticipantInfo } from '../../hooks/useLiveKit';

/** How often fading and click rings are re-evaluated while pointers are shown. */
const TICK_MS = 200;

/**
 * While this client shares its screen in the desktop app, sends the viewers'
 * pointers on that share to the desktop overlay that draws them over the
 * shared display (see utils/streamPointerOverlay.ts). Renders nothing.
 *
 * Honours the same "show stream pointers" switch as the tile does: someone
 * who turned pointers off does not get them on their desktop either.
 */
export function StreamPointerOverlayBridge() {
  const isScreenSharing = useVoiceStore((s) => s.isScreenSharing);
  const showPointers = useVoiceStore((s) => s.showStreamPointers);
  const localIdentity = useVoiceStore((s) => s.participants.find((p) => p.isLocal)?.identity ?? null);

  useEffect(() => {
    const api = getElectronAPI();
    const setOverlay = api?.setStreamPointerOverlay;
    const endOverlay = api?.endStreamPointerOverlay;
    if (!setOverlay || !endOverlay || !isScreenSharing || !showPointers || !localIdentity) return;

    const colors = new Map<string, string>();
    const describe = (participant: ParticipantInfo) => {
      let color = colors.get(participant.identity);
      if (color === undefined) {
        color = resolveCssColor(pointerColor(participant.identity));
        colors.set(participant.identity, color);
      }
      const { displayName } = resolveVoiceParticipantMeta(participant, currentVoiceParticipantMetaSources());
      return { name: displayName, color };
    };

    let sent: OverlayPointer[] = [];
    let timer: ReturnType<typeof setInterval> | null = null;

    const push = (): void => {
      const list = overlayPointersFor(
        useStreamPointerStore.getState().pointers.get(localIdentity),
        useVoiceStore.getState().participants,
        Date.now(),
        describe,
      );
      if (!sameOverlay(list, sent)) {
        sent = list;
        setOverlay(list);
      }
      // Tick only while something is on screen: fading and rings are timed.
      if (list.length > 0 && timer === null) {
        timer = setInterval(push, TICK_MS);
      } else if (list.length === 0 && timer !== null) {
        clearInterval(timer);
        timer = null;
      }
    };

    push();
    const unsubscribe = useStreamPointerStore.subscribe((state, previous) => {
      if (state.pointers.get(localIdentity) !== previous.pointers.get(localIdentity)) push();
    });

    return () => {
      unsubscribe();
      if (timer !== null) clearInterval(timer);
      endOverlay();
    };
  }, [isScreenSharing, showPointers, localIdentity]);

  return null;
}
