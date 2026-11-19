/**
 * The bridges the desktop shell exposes to its pages, as data.
 *
 * `bridgeContract.json` is the one description of them: which members exist on
 * `window.backspace` (the main window) and `window.bspaceUpdate` (the update
 * window), what kind each is and which channel it travels on. Two shells
 * implement it: Electron's preload scripts here, and the native macOS shell in
 * `packages/desktop-macos`, which builds its page-side script from the same
 * file. The description is JSON, not TypeScript, so that the Swift build reads
 * it as it is, with no generated copy that could fall behind.
 *
 * A sandboxed preload cannot require a local module, so `preload.ts` and
 * `updatePreload.ts` stay written by hand. `bridgeContract.test.ts` reads their
 * source and fails when they and the description disagree, in either direction.
 *
 * A member marked `nativeOnly` exists in the native macOS shell alone: it
 * stands in for something Chromium does by itself and WebKit does not. The
 * preloads do not have it, so a page checks that it is there before calling.
 */
import contract from './bridgeContract.json';

/**
 * - `value`: a plain property, read synchronously.
 * - `fire`: a call that sends and returns `undefined`.
 * - `invoke`: a call that returns a Promise of the shell's answer.
 * - `subscribe`: takes a callback for an event the shell sends. Returns a
 *   function that removes the callback when `unsubscribe` is true, and
 *   `undefined` otherwise (the older members, kept as they shipped).
 */
export const BRIDGE_MEMBER_KINDS = ['value', 'fire', 'invoke', 'subscribe'] as const;
export type BridgeMemberKind = (typeof BRIDGE_MEMBER_KINDS)[number];

export type BridgeMember = (
  | { name: string; kind: 'value' }
  | { name: string; kind: 'fire' | 'invoke'; channel: string }
  | { name: string; kind: 'subscribe'; channel: string; unsubscribe: boolean }
) & {
  /** Present, and true, on a member only the native macOS shell exposes. */
  nativeOnly?: true;
};

export const BRIDGE_NAMES = ['backspace', 'bspaceUpdate'] as const;
export type BridgeName = (typeof BRIDGE_NAMES)[number];

export type BridgeContract = Record<BridgeName, readonly BridgeMember[]>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isMemberKind(value: unknown): value is BridgeMemberKind {
  return typeof value === 'string' && (BRIDGE_MEMBER_KINDS as readonly string[]).includes(value);
}

function parseMember(bridge: string, value: unknown): BridgeMember {
  if (!isRecord(value)) throw new Error(`${bridge}: a member is not an object`);
  const { name, kind, channel, unsubscribe, nativeOnly, ...rest } = value;
  if (typeof name !== 'string' || name.length === 0) throw new Error(`${bridge}: a member has no name`);
  const where = `${bridge}.${name}`;
  const extra = Object.keys(rest);
  if (extra.length > 0) throw new Error(`${where}: unknown field ${extra.join(', ')}`);
  if (!isMemberKind(kind)) throw new Error(`${where}: unknown kind ${String(kind)}`);
  // Left out, not false: a member of both shells is the ordinary case.
  if (nativeOnly !== undefined && nativeOnly !== true) throw new Error(`${where}: "nativeOnly" is true or left out`);
  const only: { nativeOnly?: true } = nativeOnly === true ? { nativeOnly } : {};

  if (kind === 'value') {
    if (channel !== undefined || unsubscribe !== undefined) throw new Error(`${where}: a value has no channel`);
    return { name, kind, ...only };
  }
  if (typeof channel !== 'string' || channel.length === 0) throw new Error(`${where}: no channel`);
  if (kind === 'subscribe') {
    if (typeof unsubscribe !== 'boolean') throw new Error(`${where}: a subscription says whether it can be removed`);
    return { name, kind, channel, unsubscribe, ...only };
  }
  if (unsubscribe !== undefined) throw new Error(`${where}: only a subscription has "unsubscribe"`);
  return { name, kind, channel, ...only };
}

/**
 * Checks a description read from JSON and returns it typed. Throws on the first
 * thing that is not a well-formed contract: an unknown bridge or kind, a
 * missing channel, a member name used twice, a channel that two calls of one
 * bridge would both send on, or one that two subscriptions would both listen
 * to. One channel may carry a call and an event, as `keybind-portal-status`
 * does.
 */
export function parseBridgeContract(value: unknown): BridgeContract {
  if (!isRecord(value)) throw new Error('the contract is not an object');
  const unknown = Object.keys(value).filter((key) => !(BRIDGE_NAMES as readonly string[]).includes(key));
  if (unknown.length > 0) throw new Error(`unknown bridge ${unknown.join(', ')}`);

  const parsed = {} as Record<BridgeName, readonly BridgeMember[]>;
  for (const bridge of BRIDGE_NAMES) {
    const members = value[bridge];
    if (!Array.isArray(members)) throw new Error(`${bridge}: no member list`);
    const list = members.map((member) => parseMember(bridge, member));

    const names = new Set<string>();
    const callChannels = new Set<string>();
    const eventChannels = new Set<string>();
    for (const member of list) {
      if (names.has(member.name)) throw new Error(`${bridge}.${member.name}: declared twice`);
      names.add(member.name);
      if (member.kind === 'value') continue;
      const taken = member.kind === 'subscribe' ? eventChannels : callChannels;
      if (taken.has(member.channel)) throw new Error(`${bridge}.${member.name}: channel ${member.channel} is already used`);
      taken.add(member.channel);
    }
    parsed[bridge] = list;
  }
  return parsed;
}

export const BRIDGE_CONTRACT: BridgeContract = parseBridgeContract(contract);
