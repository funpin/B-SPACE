import { describe, it, expect } from 'vitest';
import {
  deriveStartMinimizedFromArgs,
  parseExecPathFromDesktopFile,
  shouldReapplyAppImage,
  staleWindowsLoginItem,
} from './autoLaunch';

describe('deriveStartMinimizedFromArgs', () => {
  it('returns true when --hidden is present', () => {
    expect(deriveStartMinimizedFromArgs(['--hidden'])).toBe(true);
    expect(deriveStartMinimizedFromArgs(['--foo', '--hidden', '--bar'])).toBe(true);
  });
  it('returns false when --hidden is absent', () => {
    expect(deriveStartMinimizedFromArgs([])).toBe(false);
    expect(deriveStartMinimizedFromArgs(['--other'])).toBe(false);
  });
  it('handles undefined safely', () => {
    expect(deriveStartMinimizedFromArgs(undefined)).toBe(false);
  });
});

describe('parseExecPathFromDesktopFile', () => {
  it('extracts an unquoted path', () => {
    const content = [
      '[Desktop Entry]',
      'Type=Application',
      'Name=Backspace',
      'Exec=/opt/Backspace/backspace --hidden',
      'X-GNOME-Autostart-enabled=true',
    ].join('\n');
    expect(parseExecPathFromDesktopFile(content)).toBe('/opt/Backspace/backspace');
  });

  it('extracts a double-quoted path (handles spaces in path)', () => {
    const content = 'Exec="/home/user/Apps/Backspace 1.0.AppImage" --hidden\n';
    expect(parseExecPathFromDesktopFile(content)).toBe('/home/user/Apps/Backspace 1.0.AppImage');
  });

  it('returns null when no Exec= line is present', () => {
    expect(parseExecPathFromDesktopFile('[Desktop Entry]\nName=X\n')).toBeNull();
  });

  it('ignores commented Exec lines', () => {
    expect(parseExecPathFromDesktopFile('#Exec=/wrong\nExec=/right\n')).toBe('/right');
  });

  it('returns null on empty input', () => {
    expect(parseExecPathFromDesktopFile('')).toBeNull();
  });

  it('returns null on an empty quoted Exec= path', () => {
    expect(parseExecPathFromDesktopFile('Exec=""\n')).toBeNull();
  });

  it('handles CRLF line endings', () => {
    const content = '[Desktop Entry]\r\nExec=/opt/Backspace/backspace --hidden\r\n';
    expect(parseExecPathFromDesktopFile(content)).toBe('/opt/Backspace/backspace');
  });
});

describe('shouldReapplyAppImage', () => {
  it('returns true when AppImage path differs from recorded path', () => {
    expect(shouldReapplyAppImage('/home/u/Backspace-2.0.AppImage', '/home/u/Backspace-1.0.AppImage')).toBe(true);
  });
  it('returns false when paths match', () => {
    expect(shouldReapplyAppImage('/home/u/Backspace-2.0.AppImage', '/home/u/Backspace-2.0.AppImage')).toBe(false);
  });
  it('returns false when no recorded path exists — treat missing autostart entry as user-disabled', () => {
    // A missing .desktop file is a user signal (they disabled via their DE's startup manager
    // or removed it manually), not a stale-path-needs-refresh signal. The OS-authoritative
    // architecture must treat this as "OS state changed, do not override".
    expect(shouldReapplyAppImage('/home/u/Backspace.AppImage', null)).toBe(false);
  });
  it('returns false when there is no current AppImage env (not in AppImage runtime)', () => {
    expect(shouldReapplyAppImage(null, '/anything')).toBe(false);
    expect(shouldReapplyAppImage(null, null)).toBe(false);
  });
});

describe('staleWindowsLoginItem', () => {
  const now = 'C:\\Users\\a\\AppData\\Local\\Programs\\backspace\\B-SPACE.exe';
  const old = 'C:\\Users\\a\\AppData\\Local\\Programs\\backspace\\Backspace.exe';

  it('returns the enabled entry that still points at the old executable', () => {
    const item = { name: 'Backspace', path: old, args: ['--hidden'], enabled: true };
    expect(staleWindowsLoginItem([item], 'Backspace', now)).toBe(item);
  });

  it('leaves an entry that already points here, whatever the case of the path', () => {
    expect(staleWindowsLoginItem([{ name: 'Backspace', path: now.toUpperCase(), enabled: true }], 'Backspace', now)).toBeNull();
  });

  it('leaves an entry the user disabled in Task Manager', () => {
    expect(staleWindowsLoginItem([{ name: 'Backspace', path: old, enabled: false }], 'Backspace', now)).toBeNull();
  });

  it('ignores entries of other apps and the absence of ours', () => {
    expect(staleWindowsLoginItem([{ name: 'Other', path: old, enabled: true }], 'Backspace', now)).toBeNull();
    expect(staleWindowsLoginItem([], 'Backspace', now)).toBeNull();
  });
});
