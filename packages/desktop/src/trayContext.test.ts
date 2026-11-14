import { describe, expect, it, vi } from 'vitest';

vi.mock('electron', () => ({ app: { getPath: () => '/tmp', getLocale: () => 'en' } }));

import {
  buildTrayControlItems,
  EMPTY_TRAY_CONTEXT,
  parseTrayContext,
  sameTrayContext,
  type TrayAction,
  type TrayContext,
} from './trayContext';

const inVoice: TrayContext = {
  signedIn: true,
  voice: { channelName: 'General' },
  muted: true,
  deafened: false,
  status: 'online',
};

describe('parseTrayContext', () => {
  it('accepts a well-formed context', () => {
    expect(parseTrayContext(inVoice)).toEqual(inVoice);
    expect(parseTrayContext({ ...inVoice, voice: null, status: null })).toEqual({ ...inVoice, voice: null, status: null });
  });

  it('rejects anything malformed', () => {
    for (const value of [
      null,
      'online',
      [],
      { ...inVoice, muted: 'yes' },
      { ...inVoice, status: 'invisible' },
      { ...inVoice, voice: { channelName: 3 } },
      { ...inVoice, voice: 'General' },
      { voice: null, muted: false, deafened: false, status: null },
    ]) {
      expect(parseTrayContext(value)).toBeNull();
    }
  });

  it('shortens a long channel name for the menu', () => {
    const parsed = parseTrayContext({ ...inVoice, voice: { channelName: `  ${'x'.repeat(60)}  ` } });
    expect(parsed?.voice?.channelName).toHaveLength(40);
    expect(parsed?.voice?.channelName.endsWith('…')).toBe(true);
  });
});

describe('sameTrayContext', () => {
  it('compares by value', () => {
    expect(sameTrayContext(inVoice, { ...inVoice, voice: { channelName: 'General' } })).toBe(true);
    expect(sameTrayContext(inVoice, { ...inVoice, deafened: true })).toBe(false);
    expect(sameTrayContext(inVoice, { ...inVoice, voice: null })).toBe(false);
  });
});

describe('buildTrayControlItems', () => {
  it('offers nothing before sign-in', () => {
    expect(buildTrayControlItems(EMPTY_TRAY_CONTEXT, vi.fn(), 'en')).toEqual([]);
  });

  it('names the call and offers mute, deafen, disconnect and the status', () => {
    const items = buildTrayControlItems(inVoice, vi.fn(), 'en');
    expect(items.map((item) => item.label ?? item.type)).toEqual([
      'In voice: General',
      'Mute Microphone',
      'Deafen',
      'Disconnect',
      'Status',
      'separator',
    ]);
    expect(items[0]!.enabled).toBe(false);
    expect(items[1]!.checked).toBe(true);
    expect(items[2]!.checked).toBe(false);
  });

  it('leaves out the call and Disconnect outside a call', () => {
    const labels = buildTrayControlItems({ ...inVoice, voice: null }, vi.fn(), 'en').map((item) => item.label);
    expect(labels).not.toContain('Disconnect');
    expect(labels.some((label) => label?.startsWith('In voice'))).toBe(false);
    expect(labels).toContain('Mute Microphone');
  });

  it('sends the clicked control back as an action', () => {
    const actions: TrayAction[] = [];
    const items = buildTrayControlItems(inVoice, (action) => actions.push(action), 'en');
    const click = (label: string) => (items.find((item) => item.label === label)!.click as () => void)();
    click('Mute Microphone');
    click('Deafen');
    click('Disconnect');
    const status = items.find((item) => item.label === 'Status')!.submenu as { label: string; checked: boolean; click: () => void }[];
    expect(status.map((item) => [item.label, item.checked])).toEqual([['Online', true], ['Idle', false], ['Do Not Disturb', false]]);
    status[2]!.click();
    status[0]!.click(); // already the status: nothing to send
    expect(actions).toEqual([
      { type: 'toggleMute' },
      { type: 'toggleDeafen' },
      { type: 'disconnect' },
      { type: 'setStatus', status: 'dnd' },
    ]);
  });

  it('speaks the selected language', () => {
    const labels = buildTrayControlItems(inVoice, vi.fn(), 'ru').map((item) => item.label);
    expect(labels).toContain('В голосовом: General');
    expect(labels).toContain('Отключить микрофон');
  });
});
