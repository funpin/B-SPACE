import { describe, it, expect, vi } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

vi.mock('electron', () => ({ app: { getPath: () => os.tmpdir() } }));

import { parseProcessLoopbackState, processLoopbackFailedOn, recordProcessLoopbackFailure } from './processLoopbackMemory';

describe('processLoopbackMemory', () => {
  it('remembers a refusal for the OS version it happened on only', () => {
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bspace-')), 'state.json');
    expect(processLoopbackFailedOn('10.0.19045', file)).toBe(false);
    recordProcessLoopbackFailure('10.0.19045', file);
    expect(processLoopbackFailedOn('10.0.19045', file)).toBe(true);
    // An OS update may bring the API in: the next share tries again.
    expect(processLoopbackFailedOn('10.0.19046', file)).toBe(false);
  });

  it('reads anything malformed as no refusal', () => {
    expect(parseProcessLoopbackState('not json')).toBeNull();
    expect(parseProcessLoopbackState('{"processLoopbackFailedOn": 3}')).toBeNull();
    expect(parseProcessLoopbackState('null')).toBeNull();
  });
});
