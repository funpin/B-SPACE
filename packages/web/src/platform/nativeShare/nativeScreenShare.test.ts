import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * What the setup screen holds of a source the shell previews: whether the
 * system draws it now. A window in another of Stage Manager's sets is not
 * drawn, and the shell says so in its answer or a moment before or after it.
 */

type Listener = (event: NativeScreenShareEvent) => void;

function shell(answer: NativeSharePreviewResult = { ok: true, width: 1280, height: 800 }) {
  const listeners: Listener[] = [];
  const api = {
    platform: 'darwin',
    onNativeScreenShareEvent: vi.fn((cb: Listener) => { listeners.push(cb); return () => { }; }),
    startNativeSharePreview: vi.fn(async () => answer),
    setNativeSharePreviewFrame: vi.fn(),
    stopNativeSharePreview: vi.fn(),
  };
  (window as unknown as { backspace: unknown }).backspace = api;
  return { api, say: (event: NativeScreenShareEvent) => listeners.forEach((cb) => cb(event)) };
}

// The module keeps one subscription for the page's life: each test loads it anew.
async function load() {
  vi.resetModules();
  return import('./nativeScreenShare');
}

beforeEach(() => {
  vi.clearAllMocks();
});
afterEach(() => {
  delete (window as unknown as { backspace?: unknown }).backspace;
});

describe('a staged source the system does not draw', () => {
  it('is known from the shell\'s answer', async () => {
    shell({ ok: true, width: 1280, height: 800, hidden: true });
    const { stageNativeShare, useNativeStageStore } = await load();

    const staged = await stageNativeShare('window:7:0');

    expect(staged).toMatchObject({ kind: 'native-share', sourceId: 'window:7:0' });
    expect(useNativeStageStore.getState().hidden).toBe(true);
  });

  it('is known when the shell says it before it answers, and when it is drawn again', async () => {
    const { api, say } = shell();
    api.startNativeSharePreview.mockImplementationOnce(async () => {
      say({ type: 'preview-hidden', hidden: true });
      return { ok: true, width: 1280, height: 800 };
    });
    const { stageNativeShare, useNativeStageStore } = await load();

    await stageNativeShare('window:7:0');
    expect(useNativeStageStore.getState().hidden).toBe(true);

    say({ type: 'preview-hidden', hidden: false });
    expect(useNativeStageStore.getState().hidden).toBe(false);
  });

  it('is forgotten with the stage, and by the next source', async () => {
    const { say } = shell();
    const { stageNativeShare, dropNativeStage, useNativeStageStore } = await load();

    await stageNativeShare('window:7:0');
    say({ type: 'preview-hidden', hidden: true });
    dropNativeStage();
    expect(useNativeStageStore.getState().hidden).toBe(false);

    await stageNativeShare('window:7:0');
    say({ type: 'preview-hidden', hidden: true });
    await stageNativeShare('screen:1:0');
    expect(useNativeStageStore.getState().hidden).toBe(false);
  });

  it('is not what a share\'s own events say', async () => {
    const { say } = shell();
    const { stageNativeShare, useNativeStageStore } = await load();

    await stageNativeShare('window:7:0');
    say({ type: 'source-hidden', hidden: true });

    expect(useNativeStageStore.getState().hidden).toBe(false);
  });

  it('listens to the shell once, however many sources are staged', async () => {
    const { api } = shell();
    const { stageNativeShare } = await load();

    await stageNativeShare('window:7:0');
    await stageNativeShare('screen:1:0');

    expect(api.onNativeScreenShareEvent).toHaveBeenCalledTimes(1);
  });
});
