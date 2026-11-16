import React from 'react';

interface SpinnerProps {
  /** Edge length in px. */
  size?: number;
  /** Placement and colour; the ring draws in `currentColor`. */
  className?: string;
  /** Accessible name when the spinner is the only sign of progress; omit when nearby text already says it. */
  label?: string;
}

/**
 * The one progress spinner of the Kamen kit: a faint ring with a turning
 * quarter arc, drawn in `currentColor`. Inline, so it sits in a row of text
 * or a button; `LoadingSpinner` centres it in a block.
 */
export function Spinner({ size = 20, className, label }: SpinnerProps) {
  return (
    <svg
      className={`animate-spin flex-shrink-0 ${className ?? ''}`}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      role={label ? 'img' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2.5" opacity="0.25" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" />
    </svg>
  );
}

interface LoadingSpinnerProps {
  size?: number;
  className?: string;
}

/** A spinner centred in its own block, for a pane or a page that is still loading. */
export function LoadingSpinner({ size = 40, className = '' }: LoadingSpinnerProps) {
  return (
    <div className={`flex items-center justify-center ${className}`}>
      <Spinner size={size} />
    </div>
  );
}
