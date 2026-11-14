import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  TRAY_ANIMATIONS,
  TRAY_FRAMES,
  TRAY_STATES,
  TrayAnimator,
  isTrayState,
  trayIconFile,
  type TrayFrame,
} from './trayState';

const resources = join(__dirname, '..', 'resources');

describe('isTrayState', () => {
  it('accepts every tray state', () => {
    for (const state of TRAY_STATES) expect(isTrayState(state)).toBe(true);
  });

  it('rejects anything else the renderer might send', () => {
    for (const value of ['', 'Idle', 'unread', 'idle ', 'blink', null, undefined, 1, {}, ['idle']]) {
      expect(isTrayState(value)).toBe(false);
    }
  });
});

describe('trayIconFile', () => {
  it('names the template on macOS, the .ico on Windows and the PNG on Linux', () => {
    expect(trayIconFile('notify-up', 'darwin')).toBe('tray-notify-upTemplate.png');
    expect(trayIconFile('notify-up', 'win32')).toBe('tray-notify-up.ico');
    expect(trayIconFile('notify-up', 'linux')).toBe('tray-notify-up.png');
  });

  it('points at a generated file for every frame and platform', () => {
    for (const frame of TRAY_FRAMES) {
      for (const platform of ['darwin', 'win32', 'linux'] as const) {
        expect(existsSync(join(resources, trayIconFile(frame, platform)))).toBe(true);
      }
      expect(existsSync(join(resources, `tray-${frame}Template@2x.png`))).toBe(true);
    }
  });

  it('ships no frame image that nothing plays', () => {
    const shipped = readdirSync(resources)
      .filter((name) => name.startsWith('tray-'))
      .map((name) => name.replace(/^tray-/, '').replace(/(Template)?(@2x)?\.(png|ico)$/, ''));
    const played = new Set<string>(Object.values(TRAY_ANIMATIONS).flatMap((loop) => loop.map((step) => step.frame)));
    expect(new Set(shipped)).toEqual(played);
    expect(new Set<string>(TRAY_FRAMES)).toEqual(played);
  });
});

describe('TRAY_ANIMATIONS', () => {
  it('gives every frame of a moving loop a duration', () => {
    for (const loop of Object.values(TRAY_ANIMATIONS)) {
      if (loop.length < 2) continue;
      for (const step of loop) expect(step.ms).toBeGreaterThan(0);
    }
  });

  it('blinks while idle once every 3 to 4 seconds', () => {
    const total = TRAY_ANIMATIONS.idle.reduce((sum, step) => sum + step.ms, 0);
    expect(total).toBeGreaterThanOrEqual(3000);
    expect(total).toBeLessThanOrEqual(4000);
    expect(TRAY_ANIMATIONS.idle.map((step) => step.frame)).toContain('blink');
  });
});

function harness(reducedMotion = false) {
  const shown: TrayFrame[] = [];
  const timers = new Map<number, { callback: () => void; ms: number }>();
  let next = 1;
  const animator = new TrayAnimator({
    show: (frame) => shown.push(frame),
    setTimer: (callback, ms) => {
      const id = next++;
      timers.set(id, { callback, ms });
      return id;
    },
    clearTimer: (handle) => timers.delete(handle as number),
    prefersReducedMotion: () => reducedMotion,
  });
  const tick = () => {
    const [id, timer] = [...timers.entries()][0]!;
    timers.delete(id);
    timer.callback();
    return timer.ms;
  };
  return { animator, shown, timers, tick };
}

describe('TrayAnimator', () => {
  it('plays a state’s loop frame by frame and starts over', () => {
    const { animator, shown, tick } = harness();
    animator.set('typing');
    expect(tick()).toBe(300);
    expect(tick()).toBe(300);
    expect(tick()).toBe(600);
    expect(shown).toEqual(['typing-a', 'typing-b', 'typing', 'typing-a']);
  });

  it('keeps its place when the same state is reported again', () => {
    const { animator, shown, tick } = harness();
    animator.set('notify');
    tick();
    animator.set('notify');
    expect(shown).toEqual(['notify', 'notify-up']);
  });

  it('drops the old loop’s timer when the state changes', () => {
    const { animator, shown, timers } = harness();
    animator.set('screen');
    animator.set('offline');
    expect(shown).toEqual(['screen', 'offline']);
    expect(timers.size).toBe(0);
  });

  it('skips a frame that is already on screen', () => {
    const { animator, shown, tick } = harness();
    animator.set('voice');
    tick(); // voice -> idle
    animator.set('idle');
    expect(shown).toEqual(['voice', 'idle']);
  });

  it('shows only the still frame under reduced motion', () => {
    const { animator, shown, timers } = harness(true);
    animator.set('look');
    expect(shown).toEqual(['look-left']);
    expect(timers.size).toBe(0);
  });

  it('stops without forgetting the state', () => {
    const { animator, timers } = harness();
    animator.set('idle');
    animator.stop();
    expect(timers.size).toBe(0);
    expect(animator.current).toBe('idle');
  });
});
