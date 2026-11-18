import { describe, it, expect, vi } from 'vitest';
import { OutputRouter, outputRoutingFor, type OutputRouterEnvironment } from './outputRouter';

function notAllowed(): Error {
  return Object.assign(new Error('A user gesture is required'), { name: 'NotAllowedError' });
}

/** A context without `setSinkId`, as WebKit's, and the node that carries the mix. */
function webKitContext() {
  const destination = { name: 'destination' };
  const bridge = { name: 'bridge', stream: { name: 'mix' } };
  const outputs = new Set<object>();
  const source = {
    connect: vi.fn((node: object) => { outputs.add(node); }),
    disconnect: vi.fn((node: object) => { outputs.delete(node); }),
  };
  const ctx = { destination, createMediaStreamDestination: vi.fn(() => bridge) };
  return { ctx: ctx as unknown as AudioContext, source: source as unknown as AudioNode, destination, bridge, outputs };
}

function fakeElement() {
  return {
    dataset: {} as Record<string, string>,
    srcObject: null as unknown,
    setSinkId: vi.fn<(sinkId: string) => Promise<void>>(async () => {}),
    play: vi.fn<() => Promise<void>>(async () => {}),
    pause: vi.fn(),
  };
}

function environment(element = fakeElement()) {
  let pending: (() => void) | null = null;
  const stop = vi.fn(() => { pending = null; });
  const env: OutputRouterEnvironment = {
    createElement: vi.fn(() => element as unknown as HTMLAudioElement),
    onNextGesture: vi.fn((retry: () => void) => {
      pending = retry;
      return stop;
    }),
  };
  return { env, element, stop, gesture: () => pending?.(), isWaiting: () => pending !== null };
}

describe('outputRoutingFor', () => {
  it('points the context at the device where the engine can', () => {
    expect(outputRoutingFor({ setSinkId: async () => {} }, { setSinkId: async () => {} })).toBe('context');
  });

  it('plays through an element where only an element can be pointed', () => {
    expect(outputRoutingFor({}, { setSinkId: async () => {} })).toBe('element');
  });

  it('routes nothing where the engine can do neither', () => {
    expect(outputRoutingFor({}, {})).toBe('none');
    expect(outputRoutingFor({}, undefined)).toBe('none');
  });
});

describe('OutputRouter where the context can be pointed at a device', () => {
  it('points the context, with an empty id for the system default', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const setSinkId = vi.fn(async () => {});
    Object.assign(ctx, { setSinkId });
    const { env } = environment();
    const router = new OutputRouter(ctx, source, env, 'context');

    await router.setDevice('speakers');
    await router.setDevice('default');
    expect(setSinkId.mock.calls).toEqual([['speakers'], ['']]);
    expect([...outputs]).toEqual([destination]);
    expect(env.createElement).not.toHaveBeenCalled();
  });

  it('reports a device the context refuses', async () => {
    const { ctx, source } = webKitContext();
    Object.assign(ctx, { setSinkId: vi.fn(async () => { throw new Error('gone'); }) });
    await expect(new OutputRouter(ctx, source, environment().env, 'context').setDevice('speakers')).rejects.toThrow('gone');
  });
});

describe('OutputRouter where only an element can be pointed at a device', () => {
  it('plays on the default device until another one is chosen', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env } = environment();
    const router = new OutputRouter(ctx, source, env, 'element');
    expect([...outputs]).toEqual([destination]);

    await router.setDevice('default');
    expect([...outputs]).toEqual([destination]);
    expect(env.createElement).not.toHaveBeenCalled();
  });

  it('hands the mix to an element pointed at the chosen device', async () => {
    const { ctx, source, bridge, outputs } = webKitContext();
    const { env, element } = environment();
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    expect(element.setSinkId).toHaveBeenCalledWith('headphones');
    expect(element.srcObject).toBe(bridge.stream);
    expect(element.dataset.backspace).toBe('output');
    expect(element.play).toHaveBeenCalledTimes(1);
    expect([...outputs]).toEqual([bridge]);
  });

  it('asks for the device before it waits for anything', () => {
    // An engine may take the choice only inside the gesture that made it.
    const { ctx, source } = webKitContext();
    const { env, element } = environment();
    void new OutputRouter(ctx, source, env, 'element').setDevice('headphones');
    expect(element.setSinkId).toHaveBeenCalledWith('headphones');
  });

  it('keeps the default device playing until the element does', async () => {
    const { ctx, source, destination, bridge, outputs } = webKitContext();
    const { env, element } = environment();
    let started: () => void = () => {};
    element.play.mockImplementation(() => new Promise<void>((resolve) => { started = resolve; }));
    const router = new OutputRouter(ctx, source, env, 'element');

    const done = router.setDevice('headphones');
    await vi.waitFor(() => expect(element.play).toHaveBeenCalled());
    expect(new Set(outputs)).toEqual(new Set([destination, bridge]));
    started();
    await done;
    expect([...outputs]).toEqual([bridge]);
  });

  it('goes back to the default device', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env, element } = environment();
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    await router.setDevice('default');
    expect([...outputs]).toEqual([destination]);
    expect(element.pause).toHaveBeenCalled();
  });

  it('moves from one chosen device to another on the same element', async () => {
    const { ctx, source, bridge, outputs } = webKitContext();
    const { env, element } = environment();
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    await router.setDevice('monitor');
    expect(element.setSinkId.mock.calls).toEqual([['headphones'], ['monitor']]);
    expect(env.createElement).toHaveBeenCalledTimes(1);
    expect([...outputs]).toEqual([bridge]);
  });

  it('asks once when the same choice arrives again', async () => {
    // The click, then the effect that follows the saved setting: the second
    // has no gesture, and an engine that asks for one refuses it.
    const { ctx, source, bridge, outputs } = webKitContext();
    const { env, element } = environment();
    element.setSinkId.mockResolvedValueOnce(undefined).mockRejectedValue(notAllowed());
    const router = new OutputRouter(ctx, source, env, 'element');

    const fromTheClick = router.setDevice('headphones');
    const fromTheEffect = router.setDevice('headphones');
    await Promise.all([fromTheClick, fromTheEffect]);
    await router.setDevice('headphones');
    expect(element.setSinkId).toHaveBeenCalledTimes(1);
    expect([...outputs]).toEqual([bridge]);
  });

  it('applies a choice made without a gesture on the next one', async () => {
    const { ctx, source, destination, bridge, outputs } = webKitContext();
    const { env, element, gesture, isWaiting } = environment();
    element.setSinkId.mockRejectedValueOnce(notAllowed());
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    expect([...outputs]).toEqual([destination]);
    expect(isWaiting()).toBe(true);

    gesture();
    await vi.waitFor(() => expect([...outputs]).toEqual([bridge]));
    expect(element.setSinkId).toHaveBeenCalledTimes(2);
  });

  it('waits for a gesture when the element may not start playing yet', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env, element, isWaiting } = environment();
    element.play.mockRejectedValueOnce(notAllowed());
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    expect([...outputs]).toEqual([destination]);
    expect(isWaiting()).toBe(true);
  });

  it('stops waiting for a gesture once another device is chosen', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env, element, stop, isWaiting } = environment();
    element.setSinkId.mockRejectedValueOnce(notAllowed());
    const router = new OutputRouter(ctx, source, env, 'element');

    await router.setDevice('headphones');
    await router.setDevice('default');
    expect(stop).toHaveBeenCalledTimes(1);
    expect(isWaiting()).toBe(false);
    expect([...outputs]).toEqual([destination]);
  });

  it('stays on the default device and says so when the device is gone', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env, element, isWaiting } = environment();
    element.setSinkId.mockRejectedValueOnce(Object.assign(new Error('no such device'), { name: 'NotFoundError' }));
    const router = new OutputRouter(ctx, source, env, 'element');

    await expect(router.setDevice('unplugged')).rejects.toThrow('no such device');
    expect([...outputs]).toEqual([destination]);
    expect(isWaiting()).toBe(false);
  });

  it('lets a newer choice win over an answer that comes late', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env, element } = environment();
    let answer: () => void = () => {};
    element.setSinkId.mockImplementationOnce(() => new Promise<void>((resolve) => { answer = resolve; }));
    const router = new OutputRouter(ctx, source, env, 'element');

    const first = router.setDevice('headphones');
    await router.setDevice('default');
    answer();
    await first;
    expect([...outputs]).toEqual([destination]);
    expect(element.play).not.toHaveBeenCalled();
  });
});

describe('OutputRouter where nothing can be pointed at a device', () => {
  it('plays on the default device and ignores the choice', async () => {
    const { ctx, source, destination, outputs } = webKitContext();
    const { env } = environment();
    const router = new OutputRouter(ctx, source, env, 'none');
    await router.setDevice('headphones');
    expect([...outputs]).toEqual([destination]);
    expect(env.createElement).not.toHaveBeenCalled();
  });
});
