// Dev-only workbench for the viewer's side of a stream participant: the
// second LiveKit participant a native client publishes its screen share
// through (docs/systems/voice.md, "The stream participant"). Nothing in the
// app imports this file; `dev-stream-viewer.html` is its only entry.
//
// It joins a real LiveKit room as a viewer, with no account and no server of
// ours: the address is typed in, the viewer's token is pasted in or read from
// `public/dev-stream-viewer.local.token` (a file that is never committed).
// The publisher is the native package's `StreamProbe`, or a real native
// client. The page then shows what the client's own code makes of the room —
// who is a stream participant, whose share it carries, what
// `setStreamSubscription` subscribes to by the owner's identity — and what
// the browser is given: the codec, the decoder, the size, the frame rate, the
// sound's source. That is the check that this engine decodes what a native
// client publishes (H.265, and the H.264 kept for viewers that cannot).
//
// `window.streamViewerWorkbench.report` is the same report as an object, for
// a check driven from outside.
import { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Room, RoomEvent, Track, type RemoteParticipant, type RemoteTrack } from 'livekit-client';
import { Button } from '../components/ui/Button';
import { setStreamSubscription } from '../hooks/useLiveKit';
import { isStreamParticipant, shareCarriersOf, sharerIdentityOf } from '../utils/streamParticipant';
import '../styles/globals.css';

interface PublicationLine {
  source: string;
  kind: string;
  mimeType: string;
  subscribed: boolean;
}

interface ParticipantLine {
  identity: string;
  stream: boolean;
  sharer: string;
  publications: PublicationLine[];
}

interface Received {
  kind: string;
  source: string;
  codec: string;
  decoder: string;
  size: string;
  framesPerSecond: number;
  kilobitsPerSecond: number;
  framesDecoded: number;
  packetsLost: number;
  audioLevel: number | null;
}

interface Report {
  phase: string;
  error: string | null;
  participants: ParticipantLine[];
  /** The identities whose share this page asked for, each with who carries it. */
  watched: { sharer: string; carriers: string[] }[];
  received: Received[];
  /** Whether this engine says it can decode H.265 over WebRTC at all. */
  decodesH265: boolean;
}

declare global {
  interface Window {
    streamViewerWorkbench?: { report: Report };
  }
}

const TOKEN_FILE = '/dev-stream-viewer.local.token';

function decodesH265(): boolean {
  const codecs = typeof RTCRtpReceiver !== 'undefined' ? RTCRtpReceiver.getCapabilities?.('video')?.codecs ?? [] : [];
  return codecs.some((codec) => codec.mimeType.toLowerCase() === 'video/h265');
}

function linesOf(room: Room): ParticipantLine[] {
  return [...room.remoteParticipants.values()].map((participant: RemoteParticipant) => ({
    identity: participant.identity,
    stream: isStreamParticipant(participant),
    sharer: sharerIdentityOf(participant),
    publications: [...participant.trackPublications.values()].map((publication) => ({
      source: publication.source,
      kind: publication.kind,
      mimeType: publication.mimeType ?? '',
      subscribed: publication.isSubscribed,
    })),
  }));
}

interface InboundStats {
  type?: string;
  codecId?: string;
  decoderImplementation?: string;
  frameWidth?: number;
  frameHeight?: number;
  framesPerSecond?: number;
  framesDecoded?: number;
  bytesReceived?: number;
  packetsLost?: number;
  audioLevel?: number;
  mimeType?: string;
}

function StreamViewerWorkbench() {
  const [url, setUrl] = useState('');
  const [token, setToken] = useState('');
  const [report, setReport] = useState<Report>({
    phase: 'idle', error: null, participants: [], watched: [], received: [], decodesH265: decodesH265(),
  });
  const roomRef = useRef<Room | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const bytesRef = useRef(new Map<string, number>());

  useEffect(() => {
    window.streamViewerWorkbench = { report };
  }, [report]);

  useEffect(() => {
    // The token of a local run, when the file is there. A missing file is the usual case.
    fetch(TOKEN_FILE)
      .then((response) => (response.ok ? response.text() : ''))
      .then((text) => {
        const candidate = text.trim();
        // Vite answers a missing file with the app's own HTML.
        if (candidate && !candidate.startsWith('<')) setToken(candidate);
      })
      .catch(() => { });
    return () => { void roomRef.current?.disconnect(); };
  }, []);

  const refresh = (room: Room, patch: Partial<Report> = {}) => {
    setReport((current) => ({ ...current, participants: linesOf(room), ...patch }));
  };

  const watchEveryShare = (room: Room) => {
    const sharers = new Set<string>();
    room.remoteParticipants.forEach((participant) => {
      const sharing = [...participant.trackPublications.values()].some((publication) => publication.source === Track.Source.ScreenShare);
      if (sharing) sharers.add(sharerIdentityOf(participant));
    });
    const watched = [...sharers].map((sharer) => {
      // The app's own call: by the owner's identity, never the stream participant's.
      setStreamSubscription(room, sharer, true);
      return { sharer, carriers: shareCarriersOf(room.remoteParticipants.values(), sharer).map((carrier) => carrier.identity) };
    });
    refresh(room, { watched });
  };

  const join = async () => {
    await roomRef.current?.disconnect();
    const room = new Room({ adaptiveStream: false, dynacast: false });
    roomRef.current = room;
    const update = () => refresh(room);
    room.on(RoomEvent.ParticipantConnected, update);
    room.on(RoomEvent.ParticipantDisconnected, update);
    room.on(RoomEvent.TrackUnpublished, update);
    room.on(RoomEvent.TrackPublished, () => watchEveryShare(room));
    room.on(RoomEvent.TrackSubscribed, (track: RemoteTrack) => {
      if (track.kind === Track.Kind.Video && videoRef.current) track.attach(videoRef.current);
      update();
    });
    room.on(RoomEvent.Disconnected, () => setReport((current) => ({ ...current, phase: 'left' })));
    setReport((current) => ({ ...current, phase: 'joining', error: null }));
    try {
      await room.connect(url.trim(), token.trim(), { autoSubscribe: false });
      refresh(room, { phase: 'joined' });
      watchEveryShare(room);
    } catch (error) {
      setReport((current) => ({ ...current, phase: 'failed', error: error instanceof Error ? error.message : String(error) }));
    }
  };

  // Once a second: what arrives, as the engine's own statistics say it.
  useEffect(() => {
    const timer = window.setInterval(async () => {
      const room = roomRef.current;
      if (!room || room.state !== 'connected') return;
      const received: Received[] = [];
      for (const participant of room.remoteParticipants.values()) {
        for (const publication of participant.trackPublications.values()) {
          const track = publication.track;
          if (!track) continue;
          const stats = await track.getRTCStatsReport();
          if (!stats) continue;
          const entries = [...stats.values()] as InboundStats[];
          const inbound = entries.find((entry) => entry.type === 'inbound-rtp');
          if (!inbound) continue;
          const codec = [...stats.entries()].find(([id]) => id === inbound.codecId)?.[1] as InboundStats | undefined;
          const before = bytesRef.current.get(publication.trackSid) ?? inbound.bytesReceived ?? 0;
          bytesRef.current.set(publication.trackSid, inbound.bytesReceived ?? 0);
          received.push({
            kind: publication.kind,
            source: publication.source,
            codec: codec?.mimeType ?? publication.mimeType ?? '',
            decoder: inbound.decoderImplementation ?? '',
            size: inbound.frameWidth ? `${inbound.frameWidth}x${inbound.frameHeight}` : '',
            framesPerSecond: inbound.framesPerSecond ?? 0,
            kilobitsPerSecond: Math.round(((inbound.bytesReceived ?? 0) - before) * 8 / 1000),
            framesDecoded: inbound.framesDecoded ?? 0,
            packetsLost: inbound.packetsLost ?? 0,
            audioLevel: inbound.audioLevel ?? null,
          });
        }
      }
      setReport((current) => ({ ...current, participants: linesOf(room), received }));
    }, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return (
    <div className="mx-auto flex max-w-4xl flex-col gap-4 p-6 text-sm">
      <h1 className="text-xl">Stream viewer workbench</h1>
      <p className="text-txt-secondary">
        Joins a LiveKit room as a viewer and shows how the client folds a stream participant into its owner, and what
        this engine is given. This engine {report.decodesH265 ? 'says it decodes H.265' : 'does not decode H.265'} over WebRTC.
      </p>
      <label className="flex flex-col gap-1">
        LiveKit address
        <input className="input-standard" value={url} onChange={(event) => setUrl(event.target.value)} placeholder="wss://…" />
      </label>
      <label className="flex flex-col gap-1">
        Viewer's token {token ? '(set)' : '(empty)'}
        <input className="input-standard" type="password" value={token} onChange={(event) => setToken(event.target.value)} />
      </label>
      <div>
        <Button onClick={() => { void join(); }} disabled={!url.trim() || !token.trim()}>Join and watch</Button>
      </div>
      <video ref={videoRef} autoPlay muted playsInline className="w-full rounded-lg bg-black" />
      <pre id="report" className="whitespace-pre-wrap rounded-lg bg-surface-input p-3 text-xs">{JSON.stringify(report, null, 2)}</pre>
    </div>
  );
}

createRoot(document.getElementById('root')!).render(<StreamViewerWorkbench />);
