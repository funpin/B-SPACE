import { app } from 'electron';
import path from 'path';
import fs from 'fs';

/**
 * Remembers that Windows refused the capture that leaves B:SPACE's own
 * playback out of a System Audio share (process loopback,
 * systemAudioCapability.ts), so later shares on this machine go straight to
 * the plain loopback instead of failing first.
 *
 * The memory is tied to the OS version it was recorded on: a Windows update
 * can bring the API in, and the next share then tries again.
 */

export function getProcessLoopbackStatePath(): string {
  return path.join(app.getPath('userData'), 'system-audio-state.json');
}

/** The OS version a refusal was recorded on, or null. Anything malformed reads as no refusal. */
export function parseProcessLoopbackState(raw: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) return null;
  const value = (parsed as { processLoopbackFailedOn?: unknown }).processLoopbackFailedOn;
  return typeof value === 'string' && value.length > 0 && value.length <= 64 ? value : null;
}

/** Whether process loopback has failed on `systemVersion` before. */
export function processLoopbackFailedOn(systemVersion: string, filePath?: string): boolean {
  try {
    return parseProcessLoopbackState(fs.readFileSync(filePath ?? getProcessLoopbackStatePath(), 'utf-8')) === systemVersion;
  } catch {
    return false;
  }
}

export function recordProcessLoopbackFailure(systemVersion: string, filePath?: string): void {
  const target = filePath ?? getProcessLoopbackStatePath();
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, JSON.stringify({ processLoopbackFailedOn: systemVersion.slice(0, 64) }));
  } catch (err) {
    // Not remembering only costs the next share one failed attempt.
    console.warn('[Main:SystemAudio] Could not record the process loopback failure:', err);
  }
}
