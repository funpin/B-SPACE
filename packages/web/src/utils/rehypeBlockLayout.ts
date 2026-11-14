// ─── rehype plugin: block layout as it was typed ────────────────────────────
// A chat message keeps the author's line breaks: its container renders text
// with `white-space: pre-wrap`, so a single newline inside a paragraph (a
// soft break) shows as a new line, the way it was typed.
//
// The Markdown → HTML step does not write only the author's text, though.
// mdast-util-to-hast puts a "\n" text node between every two block elements
// and inside every list and quote, to pretty-print the HTML it would emit.
// HTML ignores that whitespace; `pre-wrap` does not, and draws each one as an
// empty line. A paragraph followed by a numbered list then showed a blank line
// above the list, one between every two items and one under it, none of which
// the author typed.
//
// This plugin makes the tree say only what was typed:
//   - A whitespace-only text node next to a block element is formatting, not
//     content, and is removed. Whitespace between inline elements (the space
//     in `**a** **b**`) has no block sibling and stays.
//   - Where the author did leave a blank line between two blocks (two
//     paragraphs, a paragraph and a list, the items of a loose list), the
//     later block gets the `BLANK_LINE_BEFORE` class. The renderer turns it
//     into a gap of one line, so the spacing follows the source rather than
//     the Markdown block types.

/** The Tailwind class the renderer gives such a block: one empty line above it. */
export const BLANK_LINE_GAP_CLASS = 'mt-[1lh]';

/** The class a block carries when a blank line separates it from the block before it in the source. */
export const BLANK_LINE_BEFORE = 'md-blank-line-before';

/** The elements mdast-util-to-hast emits for Markdown blocks (GFM included). */
const BLOCK_TAGS: ReadonlySet<string> = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'blockquote', 'pre', 'hr',
  'ul', 'ol', 'li',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td',
  'section', 'div',
]);

interface Point {
  line: number;
}

interface HastNode {
  type: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
  position?: { start: Point; end: Point };
}

function isBlock(node: HastNode): boolean {
  return node.type === 'element' && node.tagName !== undefined && BLOCK_TAGS.has(node.tagName);
}

function isFormattingWhitespace(node: HastNode): boolean {
  return node.type === 'text' && (node.value === undefined || node.value.trim() === '');
}

/** True when at least one empty line lies between the two blocks in the source. */
function blankLineBetween(previous: HastNode, next: HastNode): boolean {
  const end = previous.position?.end.line;
  const start = next.position?.start.line;
  if (end === undefined || start === undefined) return false;
  return start - end > 1;
}

function addClass(node: HastNode, name: string): void {
  const properties = node.properties ?? (node.properties = {});
  const current = properties.className;
  const list = Array.isArray(current)
    ? current.filter((value): value is string => typeof value === 'string')
    : typeof current === 'string' ? current.split(/\s+/).filter(Boolean) : [];
  if (!list.includes(name)) list.push(name);
  properties.className = list;
}

function layout(node: HastNode): void {
  const children = node.children;
  if (!children) return;
  const kept = children.some(isBlock)
    ? children.filter((child) => !isFormattingWhitespace(child))
    : children;
  node.children = kept;
  let previousBlock: HastNode | null = null;
  for (const child of kept) {
    if (isBlock(child)) {
      if (previousBlock && blankLineBetween(previousBlock, child)) addClass(child, BLANK_LINE_BEFORE);
      previousBlock = child;
    }
    layout(child);
  }
}

export function rehypeBlockLayout() {
  return (tree: HastNode) => {
    layout(tree);
  };
}
