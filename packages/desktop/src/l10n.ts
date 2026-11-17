/**
 * The few strings the main process shows on its own: tray and application
 * menu items, update actions, and the recovery and instance-picker pages.
 *
 * The renderer owns the language choice and reports it over the
 * `set-language` IPC channel; main remembers it in userData so the tray is
 * right from the first paint on the next launch. Before the renderer has
 * ever said anything, the OS locale decides.
 *
 * This is deliberately not i18next: the main process has under thirty
 * strings and no React, and pulling the library into the Electron bundle
 * for that would be weight without benefit. Keys mirror the web's
 * `desktop` namespace conventions so the two are easy to compare.
 *
 * The strings are in `desktopStrings.json`, next to this file.
 */
import { app } from 'electron';
import fs from 'fs';
import path from 'path';
import catalogs from './desktopStrings.json';

/**
 * The strings themselves, by language. One file for both desktop shells: the
 * native macOS client (packages/desktop-macos) reads it too. Keys under
 * `mac.` are that client's own (the standard menu items Electron fills in
 * from its roles, and the texts of the system's permission prompts); they sit
 * here so that a language is added in one place.
 */
export type DesktopLanguage = keyof typeof catalogs;

const DESKTOP_LANGUAGES = Object.keys(catalogs) as DesktopLanguage[];

export type DesktopStringKey = keyof typeof catalogs.en;

type Catalog = Record<DesktopStringKey, string>;

/** Typed so that a language missing a key does not compile. */
export const DESKTOP_CATALOGS: Record<DesktopLanguage, Catalog> = catalogs;

export function isDesktopLanguage(value: unknown): value is DesktopLanguage {
  return typeof value === 'string' && (DESKTOP_LANGUAGES as readonly string[]).includes(value);
}

/** `de-AT` → `de`; anything not shipped → null. Same rule as the web client. */
function baseLanguage(tag: string): DesktopLanguage | null {
  const base = tag.trim().toLowerCase().split('-')[0] ?? '';
  return isDesktopLanguage(base) ? base : null;
}

/**
 * Stored renderer choice first, then the OS locale, then English.
 */
export function resolveDesktopLanguage(stored: string | null, appLocale: string): DesktopLanguage {
  if (isDesktopLanguage(stored)) return stored;
  return baseLanguage(appLocale) ?? 'en';
}

export function translateDesktop(
  language: DesktopLanguage,
  key: DesktopStringKey,
  values?: Record<string, string>,
): string {
  const text = DESKTOP_CATALOGS[language][key];
  if (!values) return text;
  return text.replace(/\{(\w+)\}/g, (match, name: string) => values[name] ?? match);
}

// ---------------------------------------------------------------------------
// Persistence: one JSON file next to instance-url.json.
// ---------------------------------------------------------------------------

export function getLanguagePath(): string {
  return path.join(app.getPath('userData'), 'language.json');
}

export function loadStoredLanguage(): DesktopLanguage | null {
  try {
    const data = JSON.parse(fs.readFileSync(getLanguagePath(), 'utf-8')) as { language?: unknown };
    return isDesktopLanguage(data.language) ? data.language : null;
  } catch {
    return null;
  }
}

export function saveStoredLanguage(language: DesktopLanguage): void {
  fs.writeFileSync(getLanguagePath(), JSON.stringify({ language }));
}

/** The language for the current process: stored choice, else OS locale, else English. */
export function getDesktopLanguage(): DesktopLanguage {
  return resolveDesktopLanguage(loadStoredLanguage(), app.getLocale());
}
