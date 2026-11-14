/**
 * The names the desktop app goes by, in one place.
 *
 * The product is called B:SPACE. A colon cannot appear in a macOS file name
 * (Finder shows it as "/"), so files and bundles are named B-SPACE
 * (`productName` in electron-builder.yml) and the colon spelling is used
 * wherever the name is only displayed.
 *
 * Two names stay "Backspace" on purpose, because they are keys into state an
 * installed copy already has, and renaming them would orphan that state:
 * the userData folder (sign-in, settings, window state) and the Windows
 * Run-key entry that starts the app at login. The bundle identifier
 * (`appId: com.backspace.desktop`) is kept for the same reason: the updater,
 * the macOS permission grants and the Windows uninstall entry are keyed by it.
 */

/** Shown in menus, the About panel, the window title, the tray tooltip and notifications. */
export const APP_DISPLAY_NAME = 'B:SPACE';

/** `<appData>/<this>` holds userData; it predates the rename and must not move. */
export const USER_DATA_DIR_NAME = 'Backspace';

/**
 * The Windows login item's Run-key value name. A new name would add a second
 * entry beside the one an earlier build registered, and the app would start twice.
 */
export const LOGIN_ITEM_NAME = 'Backspace';
