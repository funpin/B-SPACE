import { describe, expect, it, vi } from 'vitest';
import { createUpdateReadyGate } from './updateReadyGate';

describe('createUpdateReadyGate', () => {
  it('is ready on download on Windows and Linux', () => {
    for (const platform of ['win32', 'linux'] as const) {
      const onReady = vi.fn();
      const gate = createUpdateReadyGate(platform, onReady);
      gate.downloaded('2.3.2');
      expect(onReady).toHaveBeenCalledWith('2.3.2');
      expect(gate.preparing).toBe(false);
    }
  });

  it('waits on macOS until Squirrel has staged the download', () => {
    const onReady = vi.fn();
    const gate = createUpdateReadyGate('darwin', onReady);
    gate.downloaded('2.3.2');
    expect(onReady).not.toHaveBeenCalled();
    expect(gate.preparing).toBe(true);

    gate.staged();
    expect(onReady).toHaveBeenCalledOnce();
    expect(onReady).toHaveBeenCalledWith('2.3.2');
    expect(gate.preparing).toBe(false);
  });

  it('accepts the two events in either order, and fires once', () => {
    const onReady = vi.fn();
    const gate = createUpdateReadyGate('darwin', onReady);
    gate.staged();
    expect(onReady).not.toHaveBeenCalled();
    gate.downloaded('2.3.2');
    gate.downloaded('2.3.2');
    gate.staged();
    expect(onReady).toHaveBeenCalledOnce();
  });

  it('starts over with a new check cycle', () => {
    const onReady = vi.fn();
    const gate = createUpdateReadyGate('darwin', onReady);
    gate.downloaded('2.3.2');
    gate.staged();
    gate.reset();
    expect(gate.preparing).toBe(false);

    gate.downloaded('2.3.3');
    expect(onReady).toHaveBeenCalledTimes(1);
    expect(gate.preparing).toBe(true);
    gate.staged();
    expect(onReady).toHaveBeenLastCalledWith('2.3.3');
  });
});
