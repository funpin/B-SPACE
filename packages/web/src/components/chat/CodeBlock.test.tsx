import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/react';
import { CODE_COLLAPSE_AFTER_LINES, CodeBlock, countLines, FILE_COLLAPSE_AFTER_LINES } from './CodeBlock';

function linesOf(count: number): string {
  return Array.from({ length: count }, (_, i) => `line ${i + 1}`).join('\n');
}

describe('CodeBlock', () => {
  it('shows a short block whole, with no toggle', () => {
    const { container } = render(<CodeBlock language="text" code={linesOf(CODE_COLLAPSE_AFTER_LINES)} />);
    expect(screen.getByTestId('code-body')).not.toHaveAttribute('data-clipped');
    expect(container.querySelector('[aria-expanded]')).toBeNull();
  });

  it('cuts a long block off behind a fade and opens it on request, keeping all of it for copy', () => {
    const total = CODE_COLLAPSE_AFTER_LINES + 5;
    const { container } = render(<CodeBlock language="text" code={linesOf(total)} />);
    const body = screen.getByTestId('code-body');
    expect(body).toHaveAttribute('data-clipped', 'true');
    expect(body.className).toContain('mask-image');
    // The whole text is laid out; the fade only hides it.
    expect(container.querySelector('pre')!.textContent).toContain(`line ${total}`);

    const toggle = container.querySelector('[aria-expanded]')!;
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
    expect(toggle.textContent).toContain(String(total));
    fireEvent.click(toggle);
    expect(toggle).toHaveAttribute('aria-expanded', 'true');
    expect(body).not.toHaveAttribute('data-clipped');
  });

  it('labels a block with no hint by its detected language, and says it was detected', () => {
    render(<CodeBlock language="text" code={'{\n  "port": 3000\n}'} />);
    expect(screen.getByText('JSON')).toBeInTheDocument();
    expect(screen.getByText(/detected automatically/i)).toBeInTheDocument();
  });

  it('reads a fence tag written as an extension as its language', () => {
    render(<CodeBlock language="mjs" code="const a = 1;" />);
    expect(screen.getByText('JavaScript')).toBeInTheDocument();
    expect(screen.queryByText('mjs')).toBeNull();
    expect(screen.queryByText(/detected automatically/i)).toBeNull();
  });

  it('leaves undetected text without a language label', () => {
    render(<CodeBlock language="text" code="just some words here" />);
    expect(screen.queryByText('text')).toBeNull();
  });

  it('draws a file header with the name, lines, size and a download', () => {
    const onDownload = vi.fn();
    render(
      <CodeBlock
        language="typescript"
        code={linesOf(FILE_COLLAPSE_AFTER_LINES + 1)}
        file={{ name: 'voiceHealth.ts', size: 1434, onDownload }}
      />,
    );
    expect(screen.getByText('voiceHealth.ts')).toBeInTheDocument();
    expect(screen.getByText('TypeScript')).toBeInTheDocument();
    expect(screen.getByText(new RegExp(`^${FILE_COLLAPSE_AFTER_LINES + 1} lines · `))).toBeInTheDocument();
    expect(screen.getByTestId('code-body')).toHaveAttribute('data-clipped', 'true');
    fireEvent.click(screen.getByRole('button', { name: /download/i }));
    expect(onDownload).toHaveBeenCalledTimes(1);
  });
});

describe('countLines', () => {
  it('does not count the newline that ends the last line', () => {
    expect(countLines('')).toBe(0);
    expect(countLines('a')).toBe(1);
    expect(countLines('a\nb\n')).toBe(2);
  });
});
