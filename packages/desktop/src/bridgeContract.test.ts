import { describe, it, expect } from 'vitest';
import fs from 'fs';
import path from 'path';
import ts from 'typescript';
import { BRIDGE_CONTRACT, parseBridgeContract, type BridgeMember, type BridgeName } from './bridgeContract';

const PRELOADS: Record<BridgeName, string> = {
  backspace: 'preload.ts',
  bspaceUpdate: 'updatePreload.ts',
};

/** The sources that are neither a preload, nor the contract, nor a test. */
function mainProcessSources(): string {
  const skip = new Set([...Object.values(PRELOADS), 'bridgeContract.ts']);
  return fs.readdirSync(__dirname)
    .filter((file) => file.endsWith('.ts') && !file.endsWith('.test.ts') && !skip.has(file))
    .map((file) => fs.readFileSync(path.join(__dirname, file), 'utf-8'))
    .join('\n');
}

interface IpcUse {
  method: string;
  channel: string;
}

function ipcUses(node: ts.Node): IpcUse[] {
  const uses: IpcUse[] = [];
  const visit = (child: ts.Node): void => {
    if (
      ts.isCallExpression(child) &&
      ts.isPropertyAccessExpression(child.expression) &&
      ts.isIdentifier(child.expression.expression) &&
      child.expression.expression.text === 'ipcRenderer'
    ) {
      const channel = child.arguments[0];
      if (channel === undefined || !ts.isStringLiteral(channel)) {
        throw new Error('an ipcRenderer call names its channel with something other than a string literal');
      }
      uses.push({ method: child.expression.name.text, channel: channel.text });
    }
    ts.forEachChild(child, visit);
  };
  visit(node);
  return uses;
}

function channelsOf(uses: IpcUse[], method: string): string[] {
  return [...new Set(uses.filter((use) => use.method === method).map((use) => use.channel))];
}

function describeMember(name: string, initializer: ts.Expression): BridgeMember {
  if (!ts.isArrowFunction(initializer) && !ts.isFunctionExpression(initializer)) {
    return { name, kind: 'value' };
  }
  const uses = ipcUses(initializer);
  const listened = channelsOf(uses, 'on');
  const invoked = channelsOf(uses, 'invoke');
  const sent = channelsOf(uses, 'send');
  const [channel, ...others] = [...listened, ...invoked, ...sent];
  if (channel === undefined || others.length > 0) {
    throw new Error(`${name}: expected exactly one channel, found ${[channel, ...others].join(', ') || 'none'}`);
  }
  if (listened.length > 0) {
    return { name, kind: 'subscribe', channel, unsubscribe: channelsOf(uses, 'removeListener').includes(channel) };
  }
  return { name, kind: invoked.length > 0 ? 'invoke' : 'fire', channel };
}

/** What a preload script really exposes, read from its source. */
function readPreload(bridge: BridgeName): BridgeMember[] {
  const file = path.join(__dirname, PRELOADS[bridge]);
  const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf-8'), ts.ScriptTarget.ES2022, true);
  const exposed: ts.ObjectLiteralExpression[] = [];
  const visit = (node: ts.Node): void => {
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === 'exposeInMainWorld'
    ) {
      const [name, api] = node.arguments;
      if (name !== undefined && ts.isStringLiteral(name) && name.text === bridge && api !== undefined && ts.isObjectLiteralExpression(api)) {
        exposed.push(api);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  const [api, ...more] = exposed;
  if (api === undefined || more.length > 0) throw new Error(`${PRELOADS[bridge]} must expose ${bridge} exactly once`);

  return api.properties.map((property) => {
    if (!ts.isPropertyAssignment(property) || !ts.isIdentifier(property.name)) {
      throw new Error(`${PRELOADS[bridge]}: every member must be a plain "name: value" property`);
    }
    return describeMember(property.name.text, property.initializer);
  });
}

describe('bridge contract', () => {
  it.each(Object.keys(PRELOADS) as BridgeName[])('%s: the preload exposes exactly what the contract describes for it', (bridge) => {
    expect(readPreload(bridge)).toEqual(BRIDGE_CONTRACT[bridge].filter((member) => !member.nativeOnly));
  });

  it('counts what the native macOS shell has to carry', () => {
    const members = BRIDGE_CONTRACT.backspace;
    expect(members).toHaveLength(74);
    expect(members.filter((member) => member.kind === 'subscribe')).toHaveLength(20);
  });

  it('keeps the members only the native macOS shell has out of Electron', () => {
    const nativeOnly = Object.values(BRIDGE_CONTRACT).flat().filter((member) => member.nativeOnly);
    expect(nativeOnly.map((member) => member.name)).toEqual([
      'setDragRegions', 'openKeybindPermissionSettings',
      'startNativeScreenCapture', 'stopNativeScreenCapture', 'onNativeScreenCaptureEnded',
      'startNativeSystemAudio', 'stopNativeSystemAudio', 'onNativeSystemAudioEnded',
      'startNativeScreenShare', 'updateNativeScreenShare', 'stopNativeScreenShare', 'onNativeScreenShareEvent',
      'startNativeSharePreview', 'setNativeSharePreviewFrame', 'stopNativeSharePreview',
    ]);
    const everywhere = [mainProcessSources(), ...Object.values(PRELOADS).map((file) => fs.readFileSync(path.join(__dirname, file), 'utf-8'))].join('\n');
    for (const member of nativeOnly) {
      expect(everywhere).not.toContain(member.name);
      if (member.kind !== 'value') expect(everywhere).not.toContain(`'${member.channel}'`);
    }
  });

  it('names no channel the main process does not know', () => {
    const sources = mainProcessSources();
    const unknown = Object.values(BRIDGE_CONTRACT)
      .flat()
      .filter((member) => !member.nativeOnly)
      .flatMap((member) => (member.kind === 'value' ? [] : [member.channel]))
      .filter((channel) => !sources.includes(`'${channel}'`));
    expect(unknown).toEqual([]);
  });

  it('covers every channel the main window handles', () => {
    const described = new Set(
      BRIDGE_CONTRACT.backspace.flatMap((member) => (member.kind === 'fire' || member.kind === 'invoke' ? [member.channel] : [])),
    );
    const handled = [...mainProcessSources().matchAll(/ipcMain\.(?:on|once|handle)\('([^']+)'/g)].map((match) => match[1]);
    expect(handled.length).toBeGreaterThan(0);
    expect([...new Set(handled)].filter((channel) => channel !== undefined && !described.has(channel))).toEqual([]);
  });
});

describe('parseBridgeContract', () => {
  const valid = (): Record<string, unknown[]> => ({
    backspace: [{ name: 'getVersion', kind: 'invoke', channel: 'get-app-version' }],
    bspaceUpdate: [],
  });

  it('accepts a well-formed description', () => {
    expect(parseBridgeContract(valid()).backspace).toEqual([{ name: 'getVersion', kind: 'invoke', channel: 'get-app-version' }]);
  });

  it('reads a member only the native macOS shell has', () => {
    const contract = valid();
    contract.backspace = [{ name: 'setDragRegions', kind: 'fire', channel: 'set-drag-regions', nativeOnly: true }];
    expect(parseBridgeContract(contract).backspace).toEqual([
      { name: 'setDragRegions', kind: 'fire', channel: 'set-drag-regions', nativeOnly: true },
    ]);
    expect(parseBridgeContract(valid()).backspace[0]).not.toHaveProperty('nativeOnly');
  });

  it('lets one channel carry a call and an event', () => {
    const contract = valid();
    contract.backspace = [
      { name: 'getStatus', kind: 'invoke', channel: 'status' },
      { name: 'onStatus', kind: 'subscribe', channel: 'status', unsubscribe: true },
    ];
    expect(parseBridgeContract(contract).backspace).toHaveLength(2);
  });

  it.each([
    ['an unknown bridge', { ...valid(), other: [] }],
    ['a missing bridge', { backspace: [] }],
    ['an unknown kind', { ...valid(), backspace: [{ name: 'a', kind: 'stream', channel: 'a' }] }],
    ['a call without a channel', { ...valid(), backspace: [{ name: 'a', kind: 'fire' }] }],
    ['a value with a channel', { ...valid(), backspace: [{ name: 'a', kind: 'value', channel: 'a' }] }],
    ['a subscription that does not say whether it can be removed', { ...valid(), backspace: [{ name: 'a', kind: 'subscribe', channel: 'a' }] }],
    ['"unsubscribe" on a call', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a', unsubscribe: true }] }],
    ['an unknown field', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a', stage: 2 }] }],
    ['"nativeOnly" that is not true', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a', nativeOnly: false }] }],
    ['"nativeOnly" that is not a boolean', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a', nativeOnly: 'yes' }] }],
    ['a name declared twice', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a' }, { name: 'a', kind: 'fire', channel: 'b' }] }],
    ['two calls on one channel', { ...valid(), backspace: [{ name: 'a', kind: 'fire', channel: 'a' }, { name: 'b', kind: 'invoke', channel: 'a' }] }],
    ['two events on one channel', { ...valid(), backspace: [{ name: 'a', kind: 'subscribe', channel: 'a', unsubscribe: true }, { name: 'b', kind: 'subscribe', channel: 'a', unsubscribe: false }] }],
  ])('rejects %s', (_label, contract) => {
    expect(() => parseBridgeContract(contract)).toThrow();
  });
});
