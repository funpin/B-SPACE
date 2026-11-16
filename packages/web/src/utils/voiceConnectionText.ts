import type { VoiceConnectFailureReason, VoiceConnectionMark } from '@backspace/shared/src/voiceConnection';
import i18n from '../i18n';

/**
 * Why a first connection failed, as a sentence. Null for the general reason:
 * it adds nothing to "could not connect", which every caller already says.
 */
export function voiceConnectFailureText(reason: VoiceConnectFailureReason | null | undefined): string | null {
  if (!reason || reason === 'connect_failed') return null;
  return i18n.t(`voice:status.failure.${reason}`);
}

interface MarkSubject {
  /** The mark is on the viewer's own row. */
  isSelf: boolean;
  /** The member's display name, for a mark on someone else's row. */
  name: string;
  /** For `failed`: why. */
  reason?: VoiceConnectFailureReason | null;
}

/** What a connection mark means for this member, for its tooltip and its accessible name. */
export function describeVoiceConnectionMark(mark: VoiceConnectionMark, { isSelf, name, reason }: MarkSubject): string {
  switch (mark) {
    case 'connecting':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.selfConnecting')
        : i18n.t('voice:voiceDiagnostics.participantConnecting', { name });
    case 'weak':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.selfNetwork')
        : i18n.t('voice:voiceDiagnostics.participantNetwork', { name });
    case 'lost':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.selfLost')
        : i18n.t('voice:voiceDiagnostics.participantLost', { name });
    case 'reconnecting':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.reconnecting')
        : i18n.t('voice:voiceDiagnostics.participantReconnecting', { name });
    case 'mic-unavailable':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.selfMicUnavailable')
        : i18n.t('voice:voiceDiagnostics.participantMicUnavailable', { name });
    case 'unresponsive':
      return isSelf
        ? i18n.t('voice:voiceDiagnostics.selfUnresponsive')
        : i18n.t('voice:voiceDiagnostics.participantUnresponsive', { name });
    case 'failed': {
      const why = voiceConnectFailureText(reason);
      if (isSelf) {
        return why
          ? i18n.t('voice:voiceDiagnostics.selfFailed', { reason: why })
          : i18n.t('voice:voiceDiagnostics.selfFailedPlain');
      }
      return why
        ? i18n.t('voice:voiceDiagnostics.participantFailed', { name, reason: why })
        : i18n.t('voice:voiceDiagnostics.participantFailedPlain', { name });
    }
  }
}
