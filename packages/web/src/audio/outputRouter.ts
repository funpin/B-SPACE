/**
 * How the app's sound reaches the output device the user picked.
 *
 * Everything the app plays is mixed in one AudioContext. Chromium can point a
 * context at a device (`AudioContext.setSinkId`). WebKit and Firefox cannot,
 * but they can point a media element at one (`HTMLMediaElement.setSinkId`).
 * There the mix is handed to an `<audio>` element as a live stream, and the
 * element plays it on the chosen device.
 *
 * The element is used only for a device other than the system default: the
 * extra hop costs a few tens of milliseconds, and the default device needs no
 * routing at all.
 */

/** `context`: the AudioContext is pointed at the device. `element`: the mix
 * plays through a media element that is. `none`: the engine can do neither,
 * and the system decides where sound goes. */
export type OutputRouting = 'context' | 'element' | 'none';

type SinkTarget = { setSinkId(sinkId: string): Promise<void> };

function hasSetSinkId(target: unknown): target is SinkTarget {
  return typeof target === 'object' && target !== null && 'setSinkId' in target;
}

export function outputRoutingFor(
  ctx: object,
  elementPrototype: object | undefined = typeof HTMLMediaElement === 'undefined' ? undefined : HTMLMediaElement.prototype,
): OutputRouting {
  if (hasSetSinkId(ctx)) return 'context';
  if (hasSetSinkId(elementPrototype)) return 'element';
  return 'none';
}

/** Whether this engine can send the app's sound to a chosen device at all.
 * Answered from the prototypes, so it is known before any context exists. */
export function platformSupportsOutputSelection(): boolean {
  if (typeof window === 'undefined') return false;
  const contextPrototype = typeof AudioContext === 'undefined' ? undefined : AudioContext.prototype;
  const elementPrototype = typeof HTMLMediaElement === 'undefined' ? undefined : HTMLMediaElement.prototype;
  return hasSetSinkId(contextPrototype) || hasSetSinkId(elementPrototype);
}

/** The parts of the page the router uses; a test replaces them. */
export interface OutputRouterEnvironment {
  createElement(): HTMLAudioElement;
  /** Calls `retry` once, inside the user's next press or key. Returns what
   * stops waiting. */
  onNextGesture(retry: () => void): () => void;
}

const pageEnvironment: OutputRouterEnvironment = {
  createElement: () => new Audio(),
  onNextGesture(retry) {
    const events = ['pointerdown', 'keydown'] as const;
    const stop = () => events.forEach((name) => window.removeEventListener(name, listener, true));
    const listener = () => {
      stop();
      retry();
    };
    events.forEach((name) => window.addEventListener(name, listener, true));
    return stop;
  },
};

function isNotAllowed(error: unknown): boolean {
  return typeof error === 'object' && error !== null && (error as { name?: unknown }).name === 'NotAllowedError';
}

export class OutputRouter {
  private wanted = 'default';
  private bridge: MediaStreamAudioDestinationNode | null = null;
  private element: HTMLAudioElement | null = null;
  private playsDirectly = false;
  private playsThroughElement = false;
  // The device the element is pointed at, from the moment it is asked for.
  private elementDevice: string | null = null;
  private lastRequest: Promise<void> = Promise.resolve();
  // Each call to setDevice supersedes the ones before it: an answer that
  // arrives late must not undo a newer choice.
  private generation = 0;
  private stopWaitingForGesture: (() => void) | null = null;

  /**
   * @param source the node that carries the whole mix. The router owns its
   *   connection to an output; nothing else may connect it to
   *   `ctx.destination`.
   * @param routing what this engine can do; a test states it.
   */
  constructor(
    private readonly ctx: AudioContext,
    private readonly source: AudioNode,
    private readonly environment: OutputRouterEnvironment = pageEnvironment,
    readonly routing: OutputRouting = outputRoutingFor(ctx),
  ) {
    this.playDirectly();
  }

  /**
   * Sends the mix to a device; `'default'` is the system's.
   *
   * An engine may take a choice of speaker, or start an element, only while
   * the page handles a user's gesture (WebKit has a setting for the first,
   * on by default). So this reaches `setSinkId` before its first `await`:
   * called from a click, the call counts as the click's. A saved choice
   * applied at start has no gesture; if it is refused for that, sound plays
   * on the default device and the choice is applied on the user's next
   * press or key.
   *
   * Rejects when the device cannot be used for another reason (it is gone);
   * sound stays on the default device.
   */
  setDevice(deviceId: string): Promise<void> {
    // The same choice often arrives twice: from the click, and again from the
    // effect that follows the saved setting. The second has no gesture; an
    // engine that refuses it for that would undo the first.
    if (this.routing === 'element' && deviceId === this.elementDevice) return this.lastRequest;
    this.lastRequest = this.apply(deviceId);
    return this.lastRequest;
  }

  private async apply(deviceId: string): Promise<void> {
    this.wanted = deviceId;
    this.stopWaitingForGesture?.();
    this.stopWaitingForGesture = null;
    const generation = ++this.generation;
    const sinkId = deviceId === 'default' ? '' : deviceId;

    if (this.routing === 'none') return;
    if (this.routing === 'context') {
      await (this.ctx as unknown as SinkTarget).setSinkId(sinkId);
      return;
    }
    if (sinkId === '') {
      this.playDirectly();
      return;
    }

    const element = this.elementForMix();
    this.elementDevice = deviceId;
    try {
      await (element as unknown as SinkTarget).setSinkId(sinkId);
      if (generation !== this.generation) return;
      this.source.connect(this.bridgeNode());
      this.playsThroughElement = true;
      await element.play();
    } catch (error) {
      if (generation !== this.generation) return;
      this.playDirectly();
      if (!isNotAllowed(error)) throw error;
      this.stopWaitingForGesture = this.environment.onNextGesture(() => {
        this.stopWaitingForGesture = null;
        this.setDevice(this.wanted).catch(() => {});
      });
      return;
    }
    if (generation !== this.generation) return;
    // Only now: the mix was on both devices for a moment, never on none.
    if (this.playsDirectly) {
      this.source.disconnect(this.ctx.destination);
      this.playsDirectly = false;
    }
  }

  private playDirectly(): void {
    if (!this.playsDirectly) {
      this.source.connect(this.ctx.destination);
      this.playsDirectly = true;
    }
    if (this.playsThroughElement && this.bridge) {
      this.source.disconnect(this.bridge);
      this.playsThroughElement = false;
    }
    this.elementDevice = null;
    this.element?.pause();
  }

  private bridgeNode(): MediaStreamAudioDestinationNode {
    this.bridge ??= this.ctx.createMediaStreamDestination();
    return this.bridge;
  }

  private elementForMix(): HTMLAudioElement {
    if (!this.element) {
      const element = this.environment.createElement();
      // AppLayout silences every <audio> that is not the app's own.
      element.dataset.backspace = 'output';
      element.srcObject = this.bridgeNode().stream;
      this.element = element;
    }
    return this.element;
  }
}
