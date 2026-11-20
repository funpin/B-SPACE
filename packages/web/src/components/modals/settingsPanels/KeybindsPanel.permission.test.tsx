import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { KeybindsPanel } from './KeybindsPanel';

vi.mock('../../../hooks/useKeybindPortalStatus', () => ({ useKeybindPortalStatus: () => null }));
vi.mock('../../../platform/platform', () => ({ isElectron: () => true, isElectronMac: () => true }));

type StatusListener = (status: { trusted: boolean }) => void;

/** A macOS desktop bridge that says the permission is missing. */
function bridge(extra: Partial<BackspaceElectronAPI> = {}) {
  let listener: StatusListener | undefined;
  const api = {
    checkAccessibility: vi.fn(() => Promise.resolve(false)),
    onAccessibilityStatus: vi.fn((callback: StatusListener) => { listener = callback; return () => {}; }),
    ...extra,
  };
  window.backspace = api as unknown as BackspaceElectronAPI;
  return { api, tell: (trusted: boolean) => listener?.({ trusted }) };
}

async function renderPanel(): Promise<void> {
  render(<KeybindsPanel />);
  // The permission is asked about on mount; let the answer land.
  await act(async () => { await Promise.resolve(); });
}

afterEach(() => { cleanup(); delete window.backspace; });

describe('the permission warning of the keybinds panel on macOS', () => {
  it('names Accessibility in the Electron build and checks again on the button', async () => {
    const { api } = bridge();
    await renderPanel();
    expect(screen.getByText('Accessibility Permission Required')).toBeInTheDocument();
    expect(api.checkAccessibility).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole('button', { name: 'Grant Permission' }));
    expect(api.checkAccessibility).toHaveBeenCalledTimes(2);
  });

  it('names Input Monitoring in the native shell and opens its settings on the button', async () => {
    const openKeybindPermissionSettings = vi.fn();
    const { api } = bridge({ openKeybindPermissionSettings });
    await renderPanel();
    expect(screen.getByText('Input Monitoring Permission Required')).toBeInTheDocument();
    expect(screen.queryByText('Accessibility Permission Required')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Open System Settings' }));
    expect(openKeybindPermissionSettings).toHaveBeenCalledTimes(1);
    expect(api.checkAccessibility).toHaveBeenCalledTimes(1);
  });

  it('goes away when the shell says the permission is there', async () => {
    const { tell } = bridge({ openKeybindPermissionSettings: vi.fn() });
    await renderPanel();
    expect(screen.getByText('Input Monitoring Permission Required')).toBeInTheDocument();
    act(() => tell(true));
    expect(screen.queryByText('Input Monitoring Permission Required')).not.toBeInTheDocument();
  });

  it('shows no warning while the permission is given', async () => {
    bridge({ checkAccessibility: vi.fn(() => Promise.resolve(true)), openKeybindPermissionSettings: vi.fn() });
    await renderPanel();
    expect(screen.queryByText('Input Monitoring Permission Required')).not.toBeInTheDocument();
    expect(screen.queryByText('Accessibility Permission Required')).not.toBeInTheDocument();
  });
});
