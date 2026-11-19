/**
 * The worker that turns a native capture into a video track.
 *
 * It connects to the shell's local media channel, decodes what arrives
 * (`ChannelReader` decides what to decode and when to start again) and writes
 * the frames into a track it hands to the page. It runs in a worker because
 * that is where WebKit has `VideoTrackGenerator`, and so that decoding sixty
 * frames a second never waits for the page's own work.
 *
 * Messages from the page:
 *   { type: 'connect', url, token }   connect to a channel; a second one moves
 *                                     the same track to another channel
 *   { type: 'close' }                 stop
 * Messages to the page:
 *   { type: 'track', track }          once, with the track transferred
 *   { type: 'format', width, height } the size of the video, at the start and
 *                                     whenever it changes (a window resized)
 *   { type: 'failed', reason }        the worker cannot do its work here
 *   { type: 'closed' }                the channel closed without being asked to
 */
import { ChannelReader, KEY_FRAME_REQUEST, type EncodedFrame, type FrameDecoder, type VideoFormat } from './channelReader';

/** Not in TypeScript's libraries yet: the worker-side source of a video track. */
declare class VideoTrackGenerator {
  readonly writable: WritableStream<VideoFrame>;
  readonly track: MediaStreamTrack;
}

interface WorkerScope {
  onmessage: ((event: MessageEvent<ReaderRequest>) => void) | null;
  postMessage(message: ReaderEvent, transfer?: Transferable[]): void;
}

export type ReaderRequest =
  | { type: 'connect'; url: string; token: string }
  | { type: 'close' };

export type ReaderEvent =
  | { type: 'track'; track: MediaStreamTrack }
  | { type: 'format'; width: number; height: number }
  | { type: 'failed'; reason: string }
  | { type: 'closed' };

const scope = self as unknown as WorkerScope;

let writer: WritableStreamDefaultWriter<VideoFrame> | null = null;
let decoder: VideoDecoder | null = null;
let reader: ChannelReader | null = null;
let socket: WebSocket | null = null;

/** The one decoder, as the reader sees it. It outlives a move to another channel. */
const frames: FrameDecoder = {
  get waiting() {
    return decoder?.decodeQueueSize ?? 0;
  },
  configure(format: VideoFormat) {
    decoder?.configure({
      codec: format.codec,
      codedWidth: format.width,
      codedHeight: format.height,
      description: format.description,
      optimizeForLatency: true,
    });
    scope.postMessage({ type: 'format', width: format.width, height: format.height });
  },
  decode(frame: EncodedFrame) {
    decoder?.decode(new EncodedVideoChunk({
      type: frame.key ? 'key' : 'delta',
      timestamp: frame.timestamp,
      data: frame.data,
    }));
  },
  reset() {
    decoder?.reset();
  },
};

function start(): boolean {
  if (writer) return true;
  if (typeof VideoTrackGenerator === 'undefined' || typeof VideoDecoder === 'undefined') {
    scope.postMessage({ type: 'failed', reason: 'This engine has no VideoTrackGenerator or VideoDecoder in workers' });
    return false;
  }
  const generator = new VideoTrackGenerator();
  const made = generator.writable.getWriter();
  writer = made;
  decoder = new VideoDecoder({
    output: (frame) => {
      // The generator takes the frame; closing it again is harmless, and
      // frees it when the track is gone and the write was refused.
      made.write(frame).then(() => frame.close(), () => frame.close());
    },
    error: () => reader?.decoderFailed(),
  });
  scope.postMessage({ type: 'track', track: generator.track }, [generator.track]);
  return true;
}

function connect(url: string, token: string): void {
  if (!start()) return;
  // A channel the worker leaves is closed quietly: only the newest one may
  // report that it closed.
  release();
  const opened = new WebSocket(url);
  opened.binaryType = 'arraybuffer';
  const reading = new ChannelReader(frames, () => {
    if (opened.readyState === WebSocket.OPEN) opened.send(KEY_FRAME_REQUEST);
  });
  socket = opened;
  reader = reading;
  // The token is the first thing said; the shell closes a connection that
  // says anything else.
  opened.onopen = () => opened.send(token);
  opened.onmessage = (event) => {
    if (socket !== opened) return;
    if (typeof event.data === 'string') reading.text(event.data);
    else reading.binary(event.data as ArrayBuffer);
  };
  opened.onclose = () => {
    if (socket !== opened) return;
    socket = null;
    scope.postMessage({ type: 'closed' });
  };
}

function release(): void {
  const previous = socket;
  socket = null;
  reader = null;
  if (previous) {
    previous.onopen = null;
    previous.onmessage = null;
    previous.onclose = null;
    previous.close();
  }
}

scope.onmessage = (event) => {
  const request = event.data;
  if (request.type === 'connect') {
    connect(request.url, request.token);
  } else if (request.type === 'close') {
    release();
    if (decoder && decoder.state !== 'closed') decoder.close();
    decoder = null;
    writer?.close().catch(() => {});
    writer = null;
  }
};
