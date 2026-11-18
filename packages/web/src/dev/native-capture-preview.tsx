// Dev-only workbench for the native macOS shell's screen capture. Nothing in
// the app imports this file; `dev-native-capture.html` is its only entry. It
// runs the real `platform/nativeCapture` code (the worker included) against
// whatever shell the page is opened in, without a server, an account or a
// call: pick a source the shell lists, start, watch the track, change the
// limits, stop. In a browser or in Electron it only says that there is no
// native capture here.
//
// `window.nativeCaptureWorkbench` drives the same actions from outside, for
// the shell's own check (`ContractCheck --check capture-web`).
import { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Button } from '../components/ui/Button';
import { getElectronAPI } from '../platform/platform';
import {
  acquireNativeScreenCapture, canCaptureNatively, isNativeScreenCapture, reconfigureNativeScreenCapture,
  type NativeCaptureLimits,
} from '../platform/nativeCapture/nativeScreenCapture';
import '../styles/globals.css';

interface WorkbenchState {
  available: boolean;
  /** `idle`, `starting`, `running`, `ended` (by itself), `stopped` or `failed`. */
  phase: string;
  error: string | null;
  videoWidth: number;
  videoHeight: number;
  /** Seconds of video the element has played: it moves while frames arrive. */
  played: number;
  trackState: string | null;
  native: boolean;
}

interface Workbench {
  start(sourceId: string, limits: NativeCaptureLimits): Promise<WorkbenchState>;
  reconfigure(limits: NativeCaptureLimits): Promise<WorkbenchState>;
  stop(): WorkbenchState;
  state(): WorkbenchState;
}

declare global {
  interface Window {
    nativeCaptureWorkbench?: Workbench;
  }
}

const SIZES: Array<{ label: string; limits: Pick<NativeCaptureLimits, 'maxWidth' | 'maxHeight'> }> = [
  { label: '720p', limits: { maxWidth: 1280, maxHeight: 720 } },
  { label: '1080p', limits: { maxWidth: 1920, maxHeight: 1080 } },
  { label: '1440p', limits: { maxWidth: 2560, maxHeight: 1440 } },
  { label: 'Source size', limits: {} },
];

function App() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const phaseRef = useRef('idle');
  const errorRef = useRef<string | null>(null);
  const [, redraw] = useState(0);
  const [sources, setSources] = useState<ElectronScreenSource[]>([]);
  const [sourceId, setSourceId] = useState('');
  const [size, setSize] = useState(1);
  const [frameRate, setFrameRate] = useState(60);

  const available = canCaptureNatively();
  const limits = (): NativeCaptureLimits => ({ ...SIZES[size]!.limits, frameRate });

  const read = (): WorkbenchState => {
    const video = videoRef.current;
    const track = streamRef.current?.getVideoTracks()[0] ?? null;
    return {
      available,
      phase: phaseRef.current,
      error: errorRef.current,
      videoWidth: video?.videoWidth ?? 0,
      videoHeight: video?.videoHeight ?? 0,
      played: video?.currentTime ?? 0,
      trackState: track?.readyState ?? null,
      native: track ? isNativeScreenCapture(track) : false,
    };
  };

  const setPhase = (phase: string, error: string | null = null) => {
    phaseRef.current = phase;
    errorRef.current = error;
    redraw((n) => n + 1);
  };

  const stop = (): WorkbenchState => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    if (phaseRef.current === 'running' || phaseRef.current === 'starting') setPhase('stopped');
    return read();
  };

  const start = async (id: string, wanted: NativeCaptureLimits): Promise<WorkbenchState> => {
    stop();
    setPhase('starting');
    try {
      const stream = await acquireNativeScreenCapture(id, wanted);
      streamRef.current = stream;
      const track = stream.getVideoTracks()[0];
      track?.addEventListener('ended', () => {
        if (streamRef.current === stream) setPhase('ended');
      });
      const video = videoRef.current;
      if (video) {
        video.srcObject = stream;
        await video.play().catch(() => {});
      }
      setPhase('running');
    } catch (err) {
      setPhase('failed', err instanceof Error ? `${err.name}: ${err.message}` : String(err));
    }
    return read();
  };

  const reconfigure = async (wanted: NativeCaptureLimits): Promise<WorkbenchState> => {
    const track = streamRef.current?.getVideoTracks()[0];
    if (!track) return read();
    try {
      await reconfigureNativeScreenCapture(track, wanted);
      errorRef.current = null;
    } catch (err) {
      errorRef.current = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    }
    redraw((n) => n + 1);
    return read();
  };

  // The handle is the latest closures, set again after every render.
  useEffect(() => {
    window.nativeCaptureWorkbench = { start, reconfigure, stop, state: read };
  });

  useEffect(() => {
    if (!available) return;
    getElectronAPI()?.getScreenSources?.()
      .then((list) => {
        setSources(list);
        setSourceId((current) => current || list[0]?.id || '');
      })
      .catch(() => setSources([]));
  }, [available]);

  // What the element shows changes without React hearing of it.
  useEffect(() => {
    const timer = setInterval(() => redraw((n) => n + 1), 500);
    return () => clearInterval(timer);
  }, []);

  const state = read();
  return (
    <main className="mx-auto max-w-3xl space-y-4 p-6">
      <h1 className="text-xl font-semibold">Native capture workbench</h1>
      {!available ? (
        <p className="text-sm text-txt-secondary">
          This shell has no native screen capture. Open the page in the native macOS client.
        </p>
      ) : (
        <>
          <div className="flex flex-wrap items-end gap-3">
            <label className="flex min-w-0 flex-1 flex-col gap-1 text-xs text-txt-secondary">
              Source
              <select className="input-standard" value={sourceId} onChange={(e) => setSourceId(e.target.value)}>
                {sources.length === 0 && <option value="">No sources listed</option>}
                {sources.map((source) => (
                  <option key={source.id} value={source.id}>{source.name}</option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-xs text-txt-secondary">
              Size
              <select className="input-standard" value={size} onChange={(e) => setSize(Number(e.target.value))}>
                {SIZES.map((option, index) => <option key={option.label} value={index}>{option.label}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-xs text-txt-secondary">
              Frames a second
              <select className="input-standard" value={frameRate} onChange={(e) => setFrameRate(Number(e.target.value))}>
                {[15, 30, 60].map((rate) => <option key={rate} value={rate}>{rate}</option>)}
              </select>
            </label>
          </div>
          <div className="flex gap-2">
            <Button variant="primary" disabled={!sourceId} onClick={() => { void start(sourceId, limits()); }}>Start</Button>
            <Button variant="secondary" disabled={!streamRef.current} onClick={() => { void reconfigure(limits()); }}>Apply size and rate</Button>
            <Button variant="secondary" disabled={!streamRef.current} onClick={() => { stop(); }}>Stop</Button>
          </div>
        </>
      )}
      <video ref={videoRef} muted playsInline className="w-full rounded-lg bg-surface-input" />
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-compact tabular-nums">
        <dt className="text-txt-secondary">State</dt><dd>{state.phase}</dd>
        <dt className="text-txt-secondary">Picture</dt><dd>{state.videoWidth} × {state.videoHeight}</dd>
        <dt className="text-txt-secondary">Played</dt><dd>{state.played.toFixed(1)} s</dd>
        <dt className="text-txt-secondary">Track</dt><dd>{state.trackState ?? 'none'}</dd>
        {state.error && (<><dt className="text-status-danger">Error</dt><dd>{state.error}</dd></>)}
      </dl>
    </main>
  );
}

const host = document.getElementById('root');
if (host) createRoot(host).render(<App />);
