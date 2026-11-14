import { contextBridge, ipcRenderer } from 'electron';

// The update window's bridge (resources/update.html). Channel names mirror
// UPDATE_WINDOW_CHANNELS in updateWindow.ts; a sandboxed preload cannot
// require a local module, so they are spelled out here.
contextBridge.exposeInMainWorld('bspaceUpdate', {
  getState: () => ipcRenderer.invoke('update-window:get'),
  onState: (callback: (state: unknown) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, state: unknown) => callback(state);
    ipcRenderer.on('update-window:status', handler);
    return () => { ipcRenderer.removeListener('update-window:status', handler); };
  },
  check: () => ipcRenderer.send('update-window:check'),
  install: () => ipcRenderer.send('update-window:install'),
  openReleases: () => ipcRenderer.send('update-window:releases'),
  close: () => ipcRenderer.send('update-window:close'),
});
