import type { VoiceConnectionMark as VoiceConnectionMarkName } from '@backspace/shared/src/voiceConnection';
import { Icon, type IconName } from '../ui/Icon';

/**
 * The mark for the state of a member's voice connection (design-system.md,
 * "Voice connection marks"). One glyph per kind of trouble, so the shape says
 * what kind it is before the tooltip is read:
 *
 *   spinner       not in the channel yet
 *   signal bars   in the channel, network weak (amber) or gone (red)
 *   plug          the client lost its link and is restoring it
 *   microphone !  no microphone access
 *   triangle      listed, but out of reach: could not join, or went silent
 *
 * A row shows one of these at most; `resolveVoiceConnectionMark` picks it.
 */
const MARKS: Record<VoiceConnectionMarkName, { icon: IconName; tone: string; spins?: boolean }> = {
  connecting: { icon: 'loader-circle', tone: 'text-txt-tertiary', spins: true },
  weak: { icon: 'signal-weak', tone: 'text-status-warn' },
  lost: { icon: 'signal-lost', tone: 'text-status-danger' },
  reconnecting: { icon: 'unplug', tone: 'text-status-danger' },
  'mic-unavailable': { icon: 'mic-alert', tone: 'text-status-warn' },
  unresponsive: { icon: 'triangle-alert', tone: 'text-status-danger' },
  failed: { icon: 'triangle-alert', tone: 'text-status-danger' },
};

interface VoiceConnectionMarkProps {
  mark: VoiceConnectionMarkName;
  /** What is wrong, in words. Shown on hover and read by assistive technology. */
  label: string;
}

export function VoiceConnectionMark({ mark, label }: VoiceConnectionMarkProps) {
  const { icon, tone, spins } = MARKS[mark];
  return (
    <span
      className={`flex ${tone}`}
      title={label}
      role="img"
      aria-label={label}
      data-connection-mark={mark}
    >
      {/* The spinner stands still under "Reduce motion": its shape alone says "in progress". */}
      <Icon name={icon} size="xs" className={spins ? 'motion-safe:animate-spin' : undefined} />
    </span>
  );
}
