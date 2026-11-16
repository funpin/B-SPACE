import { create } from 'zustand';

/**
 * A composer that can take files dropped anywhere in the window.
 *
 * `MessageInput` registers one while it is mounted; the window-level drop
 * handler (`useWindowFileDrop`) hands a dropped `DataTransfer` to the most
 * recently registered target. The target carries its own channel id, so the
 * upload is routed by that channel's origin exactly as a paste or a pick is.
 */
export interface FileDropTarget {
  /** Unique per registration; used to unregister the right entry. */
  key: string;
  channelId: string;
  /** What the overlay names as the destination: `#general`, `@alice`, a group name. */
  label: string;
  /** False when the user lacks ATTACH_FILES there: the overlay says so and the drop is refused. */
  canAttach: boolean;
  /** Reads the files out of the drop. Must run synchronously inside the `drop` event. */
  accept: (dataTransfer: DataTransfer) => void;
}

interface FileDropStore {
  /** Registration order; the last entry is the active target. */
  targets: FileDropTarget[];
  register: (target: FileDropTarget) => () => void;
}

export const useFileDropStore = create<FileDropStore>((set) => ({
  targets: [],
  register: (target) => {
    set((s) => ({ targets: [...s.targets.filter((t) => t.key !== target.key), target] }));
    return () => set((s) => ({ targets: s.targets.filter((t) => t.key !== target.key) }));
  },
}));

/** The target a drop goes to right now, or null when no conversation is open. */
export function activeFileDropTarget(): FileDropTarget | null {
  const { targets } = useFileDropStore.getState();
  return targets[targets.length - 1] ?? null;
}
