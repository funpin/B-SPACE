import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';
import { VOICE_CONNECTION_MARKS } from '@backspace/shared/src/voiceConnection';
import { VoiceUserRow } from './VoiceUserRow';

const baseProps = {
  userId: 'user-1',
  displayName: 'Ada',
  avatar: null,
};

describe('VoiceUserRow', () => {
  it('shows the connection mark beside the participant, explained on hover and to assistive technology', () => {
    render(
      <VoiceUserRow
        {...baseProps}
        connectionMark={{ mark: 'weak', label: 'Ada has an unstable connection' }}
      />,
    );

    const mark = screen.getByLabelText('Ada has an unstable connection');
    expect(mark).toHaveAttribute('title', 'Ada has an unstable connection');
    expect(mark).toHaveAttribute('data-connection-mark', 'weak');
    expect(mark).toHaveClass('text-status-warn');
  });

  it('does not reserve status space when the connection is healthy', () => {
    const { container } = render(<VoiceUserRow {...baseProps} />);

    expect(container.querySelector('[data-connection-mark]')).toBeNull();
  });

  it('draws every mark, the warnings in amber and the breaks in red', () => {
    const tones: Record<string, string> = {
      connecting: 'text-txt-tertiary',
      weak: 'text-status-warn',
      'mic-unavailable': 'text-status-warn',
      lost: 'text-status-danger',
      reconnecting: 'text-status-danger',
      unresponsive: 'text-status-danger',
      failed: 'text-status-danger',
    };
    for (const mark of VOICE_CONNECTION_MARKS) {
      const { container, unmount } = render(
        <VoiceUserRow {...baseProps} connectionMark={{ mark, label: mark }} />,
      );
      const element = container.querySelector(`[data-connection-mark="${mark}"]`);
      expect(element, mark).not.toBeNull();
      expect(element, mark).toHaveClass(tones[mark]!);
      expect(element?.querySelector('svg'), mark).not.toBeNull();
      unmount();
    }
  });

  it('spins only the connecting mark, and not at all under reduced motion', () => {
    const { container } = render(
      <VoiceUserRow {...baseProps} connectionMark={{ mark: 'connecting', label: 'Connecting…' }} />,
    );
    // `motion-safe:` is the reduced-motion guard: the class applies the
    // animation only when the system does not ask for less movement.
    expect(container.querySelector('svg.motion-safe\\:animate-spin')).not.toBeNull();
    expect(container.querySelector('svg.animate-spin')).toBeNull();
  });

  it('shows a member who is not in the channel yet more quietly', () => {
    const { rerender } = render(<VoiceUserRow {...baseProps} pending />);
    expect(screen.getByText('Ada')).toHaveClass('text-txt-tertiary');

    rerender(<VoiceUserRow {...baseProps} />);
    expect(screen.getByText('Ada')).toHaveClass('text-txt-secondary');
  });
});
