import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/react';
import { MarkdownRenderer } from './MarkdownRenderer';
import { BLANK_LINE_GAP_CLASS } from '../../utils/rehypeBlockLayout';

// MentionBadge reads the space and UI stores at render time. Only the mention
// case touches them; stub them so the rest of the file needs no app state.
vi.mock('../../stores/spaceStore', () => ({
  useSpaceStore: (selector: (s: unknown) => unknown) =>
    selector({
      members: [],
      spaces: [],
      currentSpaceId: null,
      userViews: new Map(),
      dmChannels: [],
      dmAlternatives: new Map(),
      channelToSpaceMap: new Map(),
      channelOriginMap: new Map(),
    }),
  getApiForOrigin: vi.fn(),
  getMyUserIdForOrigin: vi.fn(),
}));
vi.mock('../../stores/authStore', () => ({
  useAuthStore: (selector: (s: unknown) => unknown) => selector({ user: null }),
}));
vi.mock('../../stores/uiStore', () => ({
  useUIStore: (selector: (s: unknown) => unknown) =>
    selector({ openUserProfile: vi.fn() }),
}));
vi.mock('../../api/client', () => ({
  api: {},
  createApiClient: vi.fn(),
}));

// One message exercising every block the renderer overrides: inline code, a
// link, a blockquote, a GFM table, a highlighted fence and a bare fence.
const MIXED = [
  'Here is `inline code` and a [link](https://example.com).',
  '',
  '> a quoted line',
  '',
  '| Col A | Col B |',
  '| ----- | ----- |',
  '| a1 | b1 |',
  '',
  '```js',
  'const answer = 42;',
  '```',
  '',
  '```',
  'plain fenced text',
  '```',
].join('\n');

describe('MarkdownRenderer', () => {
  it('renders every element of a mixed markdown message', () => {
    const { container } = render(<MarkdownRenderer content={MIXED} />);

    // Link: the `a` override, reached through urlTransform.
    const link = container.querySelector('a[href="https://example.com"]');
    expect(link).not.toBeNull();
    expect(link!.textContent).toBe('link');
    expect(link!.getAttribute('target')).toBe('_blank');
    expect(link!.getAttribute('rel')).toBe('noopener noreferrer');

    // Inline code: a <code> that is not inside a <pre>.
    const inlineCodes = Array.from(container.querySelectorAll('code')).filter(
      (el) => el.closest('pre') === null,
    );
    expect(inlineCodes.map((el) => el.textContent)).toEqual(['inline code']);

    // Blockquote.
    const quote = container.querySelector('blockquote');
    expect(quote).not.toBeNull();
    expect(quote!.textContent).toContain('a quoted line');

    // GFM table: remark-gfm plus the table/thead/tbody/tr/th/td overrides.
    const table = container.querySelector('table');
    expect(table).not.toBeNull();
    expect(Array.from(table!.querySelectorAll('th')).map((el) => el.textContent))
      .toEqual(['Col A', 'Col B']);
    expect(Array.from(table!.querySelectorAll('td')).map((el) => el.textContent))
      .toEqual(['a1', 'b1']);

    // Two fenced blocks, each its own <pre>.
    const pres = Array.from(container.querySelectorAll('pre'));
    expect(pres).toHaveLength(2);

    // Highlighted fence: prism-react-renderer emits token spans, no <code>.
    const [highlighted, bare] = pres as [HTMLElement, HTMLElement];
    expect(highlighted.textContent).toBe('const answer = 42;');
    expect(highlighted.querySelectorAll('span').length).toBeGreaterThan(1);

    // Bare fence: the remark plugin tags it `language-text`, which renders a
    // plain <code> inside the <pre> with no highlighting.
    const bareCode = bare.querySelector('code');
    expect(bareCode).not.toBeNull();
    expect(bareCode!.textContent).toBe('plain fenced text');
    expect(bareCode!.querySelector('span')).toBeNull();
  });

  it('renders emphasis, strikethrough and headings through the overrides', () => {
    const { container } = render(
      <MarkdownRenderer content={'# Title\n\n**bold** _italic_ ~~struck~~'} />,
    );

    expect(container.querySelector('strong')!.textContent).toBe('bold');
    expect(container.querySelector('em')!.textContent).toBe('italic');
    expect(container.querySelector('del')!.textContent).toBe('struck');
    // h1 is overridden to a div, so no heading element may appear.
    expect(container.querySelector('h1')).toBeNull();
    expect(container.textContent).toContain('Title');
  });

  it('turns a mention token into a badge rather than a link', () => {
    const { container } = render(<MarkdownRenderer content={'hi <@U1> there'} />);

    expect(container.querySelector('a')).toBeNull();
    expect(container.textContent).toContain('@Unknown User');
  });

  it('leaves mention tokens inside code spans alone', () => {
    const { container } = render(<MarkdownRenderer content={'`<@U1>`'} />);

    const code = container.querySelector('code');
    expect(code).not.toBeNull();
    expect(code!.textContent).toBe('<@U1>');
  });

  it('renders emoji shortcodes in message text as emoji (issue #252)', () => {
    const { container } = render(
      <MarkdownRenderer content={'on fire :heart_on_fire: and **bold :sparkles:**'} />,
    );

    expect(container.textContent).toBe('on fire ❤️‍🔥 and bold ✨');
    expect(container.querySelector('strong')!.textContent).toBe('bold ✨');
  });

  it('leaves shortcodes inside code spans and fenced blocks as typed', () => {
    const { container } = render(
      <MarkdownRenderer content={'`:smile:`\n\n```\n:smile:\n```'} />,
    );

    expect(Array.from(container.querySelectorAll('code')).map((el) => el.textContent))
      .toEqual([':smile:', ':smile:']);
  });

  it('leaves shortcodes in link text and URLs alone', () => {
    const { container } = render(
      <MarkdownRenderer content={'see https://example.com/:smile:/x'} />,
    );

    const link = container.querySelector('a')!;
    expect(link.getAttribute('href')).toBe('https://example.com/:smile:/x');
    expect(link.textContent).toBe('https://example.com/:smile:/x');
  });

  it('keeps backslash-escaped colons literal', () => {
    const { container } = render(<MarkdownRenderer content={'\\:smile\\: but :smile:'} />);
    expect(container.textContent).toBe(':smile: but 😄');
  });

  it('keeps a colon written as an entity literal', () => {
    const { container } = render(<MarkdownRenderer content={'&#58;smile: but :smile:'} />);
    expect(container.textContent).toBe(':smile: but 😄');
  });

  it('converts shortcodes in a labelled link but not in an angle-bracket autolink', () => {
    const { container } = render(
      <MarkdownRenderer content={'[:tada: party](https://example.com) <https://example.com/:smile:>'} />,
    );
    const [labelled, autolink] = Array.from(container.querySelectorAll('a'));
    expect(labelled!.textContent).toBe('🎉 party');
    expect(autolink!.textContent).toBe('https://example.com/:smile:');
  });

  it('does not treat clock times or addresses as shortcodes', () => {
    const { container } = render(<MarkdownRenderer content={'at 10:30:00 on fe80::a:b:c:d'} />);
    expect(container.textContent).toBe('at 10:30:00 on fe80::a:b:c:d');
  });
});

// The message container renders with `white-space: pre-wrap` so a typed line
// break shows. Any whitespace text the Markdown step adds between blocks would
// show too, as an empty line nobody typed.
describe('MarkdownRenderer block layout', () => {
  /** Whitespace-only text nodes: each one is an empty line under pre-wrap. */
  function whitespaceNodes(root: Node): string[] {
    const found: string[] = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.textContent !== null && node.textContent.trim() === '') {
        found.push(`${node.parentElement?.tagName ?? '?'}:${JSON.stringify(node.textContent)}`);
      }
    }
    return found;
  }

  function gapped(el: Element): boolean {
    return el.classList.contains(BLANK_LINE_GAP_CLASS);
  }

  /** The blocks a message is made of, in order. */
  function blocks(container: HTMLElement): Element[] {
    return Array.from(container.children);
  }

  // Typed by hand: two lines, then a numbered list indented by one space.
  const STATUS_POST = [
    'Отбивка (пиздец начали)',
    'Сделано:',
    ' 1. Самоподписанный сертификат: теперь не нужно заново закидывать разрешения после обновления',
    ' 2. Автоматизирован процесс обновления клиента через кнопку загрузки + перезагрузку приложения',
    ' 3. Управление громкостью голоса и трансляции рядом при ПКМ на трансляции',
    ' 4. Название B:SPACE (B-SPACE) обновлено во всех местах',
  ].join('\n');

  it('renders plain lines and a tight numbered list with no empty lines between them', () => {
    const { container } = render(<MarkdownRenderer content={STATUS_POST} />);

    expect(whitespaceNodes(container)).toEqual([]);
    const [lines, list, ...rest] = blocks(container);
    expect(rest).toEqual([]);
    // The two typed lines stay one block with the typed line break in it.
    expect(lines!.textContent).toBe('Отбивка (пиздец начали)\nСделано:');
    expect(list!.tagName).toBe('OL');
    // Only the four items, nothing between them.
    expect(list!.childNodes).toHaveLength(4);
    expect(Array.from(list!.children).map((li) => li.tagName)).toEqual(['LI', 'LI', 'LI', 'LI']);
    expect(list!.children[3]!.textContent).toBe('Название B:SPACE (B-SPACE) обновлено во всех местах');
    // No blank line was typed, so no block is spaced apart.
    expect(container.querySelectorAll(`.${CSS.escape(BLANK_LINE_GAP_CLASS)}`)).toHaveLength(0);
  });

  it('keeps one empty line between paragraphs where one was typed', () => {
    const { container } = render(
      <MarkdownRenderer content={'First paragraph.\n\nSecond paragraph.\nAnd a line of its own.'} />,
    );

    expect(whitespaceNodes(container)).toEqual([]);
    const [first, second] = blocks(container);
    expect(gapped(first!)).toBe(false);
    expect(gapped(second!)).toBe(true);
    expect(second!.textContent).toBe('Second paragraph.\nAnd a line of its own.');
  });

  it('spaces a loose list where the blank lines were typed', () => {
    const { container } = render(
      <MarkdownRenderer content={'A loose list:\n\n- one\n\n- two\n\n- three\n\nAnd text after it.'} />,
    );

    expect(whitespaceNodes(container)).toEqual([]);
    const [intro, list, outro] = blocks(container);
    expect(gapped(intro!)).toBe(false);
    expect(list!.tagName).toBe('UL');
    expect(gapped(list!)).toBe(true);
    expect(Array.from(list!.children).map(gapped)).toEqual([false, true, true]);
    expect(Array.from(list!.children).map((li) => li.textContent)).toEqual(['one', 'two', 'three']);
    expect(gapped(outro!)).toBe(true);
  });

  it('nests a tight list under its item with nothing in between', () => {
    const { container } = render(
      <MarkdownRenderer content={'Nested:\n- fruit\n  - apple\n  - pear\n- bread'} />,
    );

    expect(whitespaceNodes(container)).toEqual([]);
    const fruit = container.querySelector('ul > li')!;
    expect(Array.from(fruit.childNodes).map((n) => n.nodeName)).toEqual(['#text', 'UL']);
    expect(container.querySelectorAll(`.${CSS.escape(BLANK_LINE_GAP_CLASS)}`)).toHaveLength(0);
  });

  it('spaces a quote and a code block only where a blank line was typed', () => {
    const { container } = render(
      <MarkdownRenderer content={'> quoted\n> twice\n\nRun this:\n```sh\npnpm dev\n```\n\n```\nlater\n```'} />,
    );

    expect(whitespaceNodes(container)).toEqual([]);
    const quote = container.querySelector('blockquote')!;
    expect(quote.textContent).toBe('quoted\ntwice');
    expect(gapped(quote)).toBe(false);
    const [runThis, firstCode, secondCode] = blocks(container).slice(1);
    expect(gapped(runThis!)).toBe(true);
    // The fence right under "Run this:" is not spaced; the one after a blank line is.
    expect(gapped(firstCode!)).toBe(false);
    expect(gapped(secondCode!)).toBe(true);
    expect(secondCode!.querySelector('pre')!.textContent).toBe('later');
  });

  it('keeps the space between inline elements', () => {
    const { container } = render(<MarkdownRenderer content={'**a** _b_ `c`'} />);
    expect(container.textContent).toBe('a b c');
  });
});
