import { describe, expect, it } from 'vitest';
import { overlayPointersFor, resolveCssColor, sameOverlay } from './streamPointerOverlay';
import { STREAM_POINTER_IDLE_MS } from '../stores/streamPointerStore';
import type { ParticipantInfo } from '../hooks/useLiveKit';

const person = (identity: string, isLocal = false) => ({ identity, isLocal } as ParticipantInfo);
const describeAs = (p: ParticipantInfo) => ({ name: p.identity.toUpperCase(), color: 'rgb(1 2 3)' });

describe('overlayPointersFor', () => {
  it('lists the pointers of people in the call, fading the still ones', () => {
    const pointers = new Map([
      ['bob', { point: { x: 0.1, y: 0.2 }, movedAt: 1000, pingAt: 990 }],
      ['eve', { point: { x: 0.5, y: 0.5 }, movedAt: 1000 - STREAM_POINTER_IDLE_MS, pingAt: 0 }],
      ['gone', { point: { x: 0.5, y: 0.5 }, movedAt: 1000, pingAt: 0 }],
    ]);
    const list = overlayPointersFor(pointers, [person('me', true), person('bob'), person('eve')], 1000, describeAs);
    expect(list).toEqual([
      { id: 'bob', name: 'BOB', color: 'rgb(1 2 3)', x: 0.1, y: 0.2, idle: false, ping: 990 },
      { id: 'eve', name: 'EVE', color: 'rgb(1 2 3)', x: 0.5, y: 0.5, idle: true, ping: 0 },
    ]);
  });

  it('drops a pointer once its fade has played out', () => {
    const pointers = new Map([['bob', { point: { x: 0, y: 0 }, movedAt: 0, pingAt: 0 }]]);
    expect(overlayPointersFor(pointers, [person('bob')], 60_000, describeAs)).toEqual([]);
    expect(overlayPointersFor(undefined, [person('bob')], 0, describeAs)).toEqual([]);
  });
});

describe('resolveCssColor', () => {
  it('turns a variable colour into a concrete one and leaves others alone', () => {
    document.documentElement.style.setProperty('--accent-test', '10 20 30');
    expect(resolveCssColor('rgb(var(--accent-test))')).toBe('rgb(10 20 30)');
    expect(resolveCssColor('rgb(1 2 3)')).toBe('rgb(1 2 3)');
  });
});

describe('sameOverlay', () => {
  it('notices any drawn difference', () => {
    const a = [{ id: 'b', name: 'B', color: 'rgb(1 2 3)', x: 0, y: 0, idle: false, ping: 0 }];
    expect(sameOverlay(a, [{ ...a[0]! }])).toBe(true);
    expect(sameOverlay(a, [{ ...a[0]!, x: 0.1 }])).toBe(false);
    expect(sameOverlay(a, [])).toBe(false);
  });
});
