/**
 * The audio-thread end of a native capture's sound.
 *
 * Samples come straight from the worker that reads the channel, on a port the
 * page hands over once (`{ type: 'source', port }`), so they never wait for
 * the page's own work. `PcmBuffer` keeps a small reserve and this processor
 * plays it out, one block at a time.
 *
 * The page may ask how it is going (`{ type: 'stats' }`) and is answered on
 * the node's port.
 */
import { PcmBuffer, SOUND_PROCESSOR } from './pcmBuffer';

// The audio worklet's globals, which TypeScript's DOM library leaves out.
declare const sampleRate: number;
declare const currentTime: number;
declare abstract class AudioWorkletProcessor {
  readonly port: MessagePort;
}
declare function registerProcessor(
  name: string,
  processor: new (options: ProcessorOptions) => AudioWorkletProcessor,
): void;

interface ProcessorOptions {
  processorOptions?: { channels?: number };
}

export type SoundProcessorRequest =
  | { type: 'source'; port: MessagePort }
  | { type: 'stats' };

export interface SoundProcessorStats {
  type: 'stats';
  /** Frames taken in, played out, skipped because too many waited, and waiting now. */
  received: number;
  played: number;
  skipped: number;
  waiting: number;
  /** The audio thread's clock, in seconds, and the wall clock at that moment, in milliseconds. */
  clock: number;
  wall: number;
  /** Times the buffer ran dry while playing. */
  ranDry: number;
}

class SoundProcessor extends AudioWorkletProcessor {
  private readonly buffer: PcmBuffer;

  constructor(options: ProcessorOptions) {
    super();
    this.buffer = new PcmBuffer(options.processorOptions?.channels ?? 2, sampleRate);
    this.port.onmessage = (event: MessageEvent<SoundProcessorRequest>) => {
      const request = event.data;
      if (request.type === 'source') {
        request.port.onmessage = (sound: MessageEvent<ArrayBuffer>) => {
          this.buffer.push(new Float32Array(sound.data));
        };
      } else if (request.type === 'stats') {
        const stats: SoundProcessorStats = {
          type: 'stats',
          received: this.buffer.received,
          played: this.buffer.played,
          clock: currentTime,
          wall: Date.now(),
          skipped: this.buffer.skipped,
          waiting: this.buffer.waiting,
          ranDry: this.buffer.ranDry,
        };
        this.port.postMessage(stats);
      }
    };
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const output = outputs[0];
    if (output) this.buffer.pull(output);
    return true;
  }
}

registerProcessor(SOUND_PROCESSOR, SoundProcessor);
