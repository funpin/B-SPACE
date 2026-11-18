/**
 * The worker that reads a native capture's sound from the shell's local media
 * channel and passes the samples on to the audio thread.
 *
 * An audio worklet cannot open a socket, and the page's own thread is busy
 * with everything else: sound that waited for it would crackle whenever the
 * page worked. So the socket lives here and the samples go to the worklet on
 * a port of their own.
 *
 * Messages from the page:
 *   { type: 'connect', url, token, port }   connect; samples go to `port`
 *   { type: 'close' }                       stop
 * Messages to the page:
 *   { type: 'closed' }                      the channel closed without being asked to
 */
import { soundOf } from './pcmBuffer';

interface WorkerScope {
  onmessage: ((event: MessageEvent<SoundReaderRequest>) => void) | null;
  postMessage(message: SoundReaderEvent): void;
}

export type SoundReaderRequest =
  | { type: 'connect'; url: string; token: string; port: MessagePort }
  | { type: 'close' };

export type SoundReaderEvent = { type: 'closed' };

const scope = self as unknown as WorkerScope;

let socket: WebSocket | null = null;

function connect(url: string, token: string, port: MessagePort): void {
  release();
  const opened = new WebSocket(url);
  opened.binaryType = 'arraybuffer';
  socket = opened;
  // The token is the first thing said; the shell closes a connection that
  // says anything else.
  opened.onopen = () => opened.send(token);
  opened.onmessage = (event) => {
    // The text message announces the format, which the page already has
    // from the answer that started the capture.
    if (socket !== opened || typeof event.data === 'string') return;
    const sound = soundOf(event.data as ArrayBuffer);
    if (sound) port.postMessage(sound, [sound]);
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
  if (previous) {
    previous.onopen = null;
    previous.onmessage = null;
    previous.onclose = null;
    previous.close();
  }
}

scope.onmessage = (event) => {
  const request = event.data;
  if (request.type === 'connect') connect(request.url, request.token, request.port);
  else if (request.type === 'close') release();
};
