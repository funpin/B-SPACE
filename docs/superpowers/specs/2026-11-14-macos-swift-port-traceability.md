# Матрица трассируемости: Electron-оболочка → Swift-оболочка (macOS)

Фаза 0 задания `2026-11-14-macos-swift-port-prompt.md`. Базовый коммит `7c7fd2a6` (`1.11.0-f.1.1`).
Построена по коду `packages/desktop/src/**`, а не по документации; где они расходятся, матрица следует коду, а расхождение вынесено в §8.

Обозначения:

- **Тип** — `fire` (`ipcRenderer.send`, возвращает `undefined`), `invoke` (`ipcRenderer.invoke`, возвращает `Promise`), `sub` (подписка), `prop` (значение).
- **Отписка** — возвращает ли метод подписки функцию отписки (`да`) или `undefined` (`нет`).
- **Guard** — проверяет ли обработчик `event.sender === mainWindow.webContents`.
- **Модуль Swift** — имя модуля из §4.1 задания.
- **Тест** — `U` юнит-тест чистой логики, `C` тест соответствия контракта (харнесс §4.5 задания), `S` пункт ручного smoke-чеклиста.

Колонка «Модуль Swift» описывает намерение. Ни одной строки Swift в фазе 0 не написано.

**Обновление от 2026-11-16.** Разделы 1–8 описывают базовый коммит `7c7fd2a6`. Всё, что появилось в `packages/desktop` после него и до 2.3.2 (8 членов моста, 2 события, второй мост окна обновления, файл состояния, 81 тест-кейс), собрано в §9. Актуальные итоги: **59 членов моста, 17 каналов событий, 289 тест-кейсов в 24 файлах**. Номера строк `main.ts` в разделах 1–8 относятся к базовому коммиту и в текущем коде сдвинуты.

**Обновление от 2026-11-14.** Минимальная macOS поднята до 27, движок и схема захвата экрана выбраны — см. «Решения после гейта» в `2026-11-14-macos-swift-port-webkit-audit.md`. Для матрицы это означает:

- `getSystemAudioCapability` на поддерживаемых версиях всегда отвечает `'excluded'`. Ветки `'included'` (13.0–14.1) и `'unavailable'` (<13) остаются в чистой функции и её тестах, но в работающем приложении недостижимы. Ответ `'excluded'` обязывает оболочку действительно исключать собственный звук — это открытый пункт 1 аудита.
- Каналы 23–31 (демонстрация экрана) сохраняют контракт: `getScreenSharePickerMode` отвечает `'app'`, перечисление и предвыбор работают как в Electron. Меняется только то, что стоит за `getDisplayMedia`: шим подменяет его и возвращает поток из нативного захвата.
- Рекомендации из §8 приняты как решения.

---

## 1. Мост `window.backspace`: 51 член

Источник: `preload.ts` (весь файл), обработчики в `main.ts:637–970`, `main.ts:1467`, `main.ts:1485`.

### 1.1. Окно, уведомления, бейдж

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 1 | `platform` | — | prop | — | `process.platform` → строго `'darwin'` | Bridge | C |
| 2 | `minimize()` | `minimize-window` | fire | нет | `mainWindow.minimize()` | Bridge → Window | C, S |
| 3 | `maximize()` | `maximize-window` | fire | нет | `isMaximized() ? unmaximize() : maximize()` (на macOS это zoom) | Bridge → Window | C, S |
| 4 | `close()` | `close-window` | fire | нет | `mainWindow.close()` → обработчик `close` сохраняет состояние и прячет окно, если не идёт выход | Bridge → Window | C, S |
| 5 | `showNotification(title, body, options?)` | `show-notification` | fire | **да** | Запоминает origin страницы на момент вызова. Клик: `restore()` если свёрнуто, `show()`, `focus()`, затем `notification-click` с `options` — только если отправитель всё ещё главное окно, origin не изменился и `options` задан. `silent: false` | Notifications | U (правило origin), S |
| 6 | `onNotificationClick(cb)` | `notification-click` | sub | — | отписка: **да** | Bridge | C |
| 7 | `setBadgeCount(n)` | `set-badge-count` | fire | нет | `app.setBadgeCount(n)`; тип `n` не проверяется | Notifications (Dock) | C, S |

### 1.2. Обновления

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 8 | `onUpdateAvailable(cb)` | `update-available` | sub | — | отписка: **нет**. Legacy, но обязателен: старые инстансы вызывают его в `useEffect` | Bridge | C |
| 9 | `onUpdateDownloaded(cb)` | `update-downloaded` | sub | — | отписка: **нет** | Bridge | C |
| 10 | `onUpdateError(cb)` | `update-error` | sub | — | отписка: **нет** | Bridge | C |
| 11 | `installUpdate()` | `install-update` | fire | нет | `external` → ничего; `manual` → открыть `RELEASES_URL`; `auto` → `quitAndInstall()` + watchdog 4 с (если фаза всё ещё `ready` → `failed` «Restarting to install the update did not start.»); исключение при загрузке updater → `failed` «The updater is not available in this build.» | Updater | U, S |
| 12 | `checkForUpdates()` | `check-for-updates` | fire | нет | `external` → ничего; иначе `autoUpdater.checkForUpdates()`, ошибки проглатываются | Updater | U, S |
| 13 | `getVersion()` | `get-app-version` | invoke | нет | `app.getVersion()` | Bridge | C |
| 14 | `getUpdateStatus()` | `get-update-status` | invoke | нет | `UpdateSnapshot { capability, dismissedVersion, status }` (замороженный) | UpdateStatus | U, C |
| 15 | `isSandboxed()` | `is-sandboxed` | invoke | нет | `Boolean(FLATPAK_ID)` → на macOS `false` | UpdateCapability | C |
| 16 | `onUpdateStatusChanged(cb)` | `update-status-changed` | sub | — | отписка: **да**. Событие на каждый `commit` стора | Bridge | C |
| 17 | `dismissUpdate(version)` | `dismiss-update` | fire | нет | payload `{ version }`; берётся только строка, `trim`, пустая → игнор; запись в `update-state.json`, затем **перечитывание с диска** и обновление стора | UpdateDismissal | U, C |
| 18 | `openReleasePage()` | `open-release-page` | fire | нет | `shell.openExternal(RELEASES_URL)` | Updater | C |

### 1.3. Фокус, deep links, маршрутизация

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 19 | `onWindowFocusChange(cb)` | `window-focus-changed` | sub | — | отписка: **нет**. `true` на `focus`, `false` на `blur` | Bridge | C, S |
| 20 | `onDeepLink(cb)` | `deep-link` | sub | — | отписка: **нет** | Bridge | C, S |
| 21 | `setConnectedOrigins(origins)` | `set-connected-origins` | fire | нет | Не массив → игнор. Иначе набор **очищается** и заполняется только непустыми строками | NavigationPolicy | U, C |
| 22 | `onOpenInternalRoute(cb)` | `open-internal-route` | sub | — | отписка: **да**. Аргумент — `pathname + search` | Bridge | C, S |

### 1.4. Демонстрация экрана и системный звук

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 23 | `onScreenShareSources(cb)` | `screen-share-sources` | sub | — | отписка: **нет**. Prompted-flow для старых веб-клиентов | Bridge | C |
| 24 | `selectScreenSource(id, shareAudio)` | `screen-share-selected` | fire | нет | preload подставляет `shareAudio ?? true`. Ответ на prompted-flow (`ipcMain.once`); постоянный обработчик — пустая страховка | ScreenCapture | C, S |
| 25 | `getScreenSources()` | `get-screen-sources` | invoke | **да** | `screenEnumerationDecision`: чужой отправитель → `[]`; окно не в фокусе или кеш моложе 1 с → последняя отданная выборка; иначе перечисление (`screen`+`window`, миниатюры 320×180, иконки окон). Элемент: `{ id, name, thumbnailDataUrl, appIconDataUrl \| null, isScreen }`, `isScreen = id.startsWith('screen:')` | ScreenSharePolicy + ScreenCapture | U, C, S |
| 26 | `preselectScreenSource(id, shareAudio)` | `screen-share-preselect` | invoke | **да** | preload подставляет `shareAudio ?? true`, main хранит `shareAudio === true`. Нестроковый или пустой `id` → игнор. Одноразовая запись с TTL 30 с | ScreenSharePolicy | U, C |
| 27 | `getScreenSharePickerMode()` | `get-screen-share-picker-mode` | invoke | **да** | Чужой отправитель → `'app'`. На не-Linux всегда `'app'` | ScreenSharePolicy | U, C |
| 28 | `getSystemAudioCapability(usesAppSource)` | `get-system-audio-capability` | invoke | **да** | preload передаёт `usesAppSource === true`. Чужой отправитель → `'unknown'`. На macOS источник venmic недоступен, поэтому ответ = `ownAudioInSystemAudio('darwin', версия ОС)`: ≥14.2 `'excluded'`, 13.0–14.1 `'included'`, <13 `'unavailable'`, нечитаемая версия `'unknown'` | SystemAudioCapability | U, C |
| 29 | `startSystemAudio()` | `system-audio-start` | invoke | **да** | На не-Linux → `{ ok: false, reason: 'unsupported-platform' }` | SystemAudioCapability | U, C |
| 30 | `stopSystemAudio()` | `system-audio-stop` | invoke | **да** | no-op, резолвится `undefined` | SystemAudioCapability | C |
| 31 | `setScreenShareAudioPreference(b)` | `screen-share-audio-preference` | fire | **да** | Хранит `b === true`; используется только веткой системного пикера | ScreenSharePolicy | C |

### 1.5. Инстанс, язык, автозапуск

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 32 | `getInstanceUrl()` | `get-instance-url` | invoke | нет | `instance-url.json` → `url` если строка, иначе `null` | InstanceURL | U, C |
| 33 | `setInstanceUrl(url)` | `set-instance-url` | invoke | нет | Запись `{ url }` **без валидации**, `loadURL(url)`, после `did-finish-load` — хак +1 px для пересчёта drag-регионов. Резолвится `undefined` | InstanceURL + Window | C, S |
| 34 | `clearInstanceUrl()` | `clear-instance-url` | invoke | нет | Удаление файла (ошибка проглатывается), загрузка picker с `?lang=`, тот же хак +1 px | InstanceURL + Window | C, S |
| 35 | `setLanguage(lang)` | `set-language` | fire | нет | Не из `en/ru/de/pt/zh` → игнор. Запись `language.json` (ошибка → предупреждение в лог, продолжение), перестройка трея и меню | L10n + Tray + AppMenu | U, C, S |
| 36 | `getAutoLaunchSettings()` | `get-auto-launch-settings` | invoke | нет | `{ openAtLogin: <ОС>, startMinimized: <auto-launch.json, по умолчанию true> }` | AutoLaunch | U, C |
| 37 | `setAutoLaunchSettings(partial)` | `set-auto-launch-settings` | invoke | нет | Отсутствующие поля берутся из текущего состояния (ОС для `openAtLogin`, диск для `startMinimized`); применение к login item (`openAsHidden`, `args: ['--hidden']`); запись обоих полей на диск; возвращает итоговую пару | AutoLaunch | U, C, S |

### 1.6. Активность, кейбинды, recovery

| # | Член | Канал | Тип | Guard | Поведение main на darwin | Модуль Swift | Тест |
|---|------|-------|-----|-------|--------------------------|--------------|------|
| 38 | `onActivityDetected(cb)` | `activity-detected` | sub | — | отписка: **да**. Аргумент — `Activity` или `null` | Bridge | C, S |
| 39 | `getCurrentActivity()` | `get-current-activity` | invoke | нет | Текущая `Activity` или `null`. Обработчик регистрируется после создания окна | ActivityDetector | C |
| 40 | `getKeybindPortalStatus()` | `keybind-portal-status` | invoke | нет | На macOS `null` (портал только на Wayland) | KeybindManager | C |
| 41 | `retryKeybindPortal()` | `keybind-portal-retry` | fire | нет | На macOS no-op | KeybindManager | C |
| 42 | `onKeybindPortalStatus(cb)` | `keybind-portal-status` | sub | — | отписка: **да**. На macOS событие не приходит никогда | Bridge | C |
| 43 | `syncKeybinds(list)` | `keybinds-sync` | invoke | нет | `updateKeybinds(list)`, возвращает `isHookRunning()` | KeybindManager | U, C, S |
| 44 | `onKeybindAction(cb)` | `keybind-action` | sub | — | отписка: **да**. `{ actionId, pressed }` | Bridge | C, S |
| 45 | `onAccessibilityStatus(cb)` | `accessibility-status` | sub | — | отписка: **да**. `{ trusted }`; отправляется при **каждой** попытке запуска хука | Bridge | C, S |
| 46 | `onKeybindHookError(cb)` | `keybind-hook-error` | sub | — | отписка: **да**. `{ message }` | Bridge | C |
| 47 | `checkAccessibility()` | `check-accessibility` | invoke | нет | `isTrustedAccessibilityClient(false)` — без системного запроса | KeybindManager | C, S |
| 48 | `rendererReady()` | `renderer-ready` | fire | нет | `pingReceivedThisNav = true`; снимает boot-таймер, если взведён | Recovery | U, S |
| 49 | `getRecoveryState()` | `get-recovery-state` | invoke | нет | Замороженный `RecoveryState` | Recovery | U, C |
| 50 | `onRecoveryStateChanged(cb)` | `recovery-state-changed` | sub | — | отписка: **да**. Отправляется только при `mode === 'recovery'` | Bridge | C |
| 51 | `recoveryAction(action)` | `recovery-action` | fire | нет | Вне allowlist (`reload`, `check-update`, `install-update`, `change-instance`, `open-releases`, `quit`) → предупреждение `[recovery] ignored unknown action:` и игнор | Recovery | U, C |

Общие свойства моста для теста контракта: объект определён до первого скрипта страницы, заморожен, свойство `window.backspace` неперезаписываемо, присутствует только в главном фрейме (включая `instance-picker.html` и `recovery.html`), ошибка обработчика `invoke` реджектит `Promise` объектом `Error`, событие до подписки теряется.

---

## 2. События main → renderer: 15 каналов

| Канал | Где отправляется | Условие | Payload | Модуль Swift | Тест |
|-------|------------------|---------|---------|--------------|------|
| `deep-link` | `main.ts:427` | `ready-to-show`, если есть отложенная ссылка | строка URL | DeepLink | S |
| `deep-link` | `main.ts:1206` | окно существует: событие, затем `show()` + `focus()` | строка URL | DeepLink | S |
| `window-focus-changed` | `main.ts:483,486` | `focus` / `blur` окна | `true` / `false` | Window | S |
| `open-internal-route` | `main.ts:499` | `window.open` на http(s) URL известного origin с путём `/join/` | `pathname + search` | NavigationPolicy | U, S |
| `notification-click` | `main.ts:649` | см. член 5 | `options` | Notifications | U, S |
| `update-status-changed` | `main.ts:1001` | любой `commit` стора статуса | `UpdateSnapshot` | UpdateStatus | U |
| `update-available` | `main.ts:1106` | updater нашёл версию (обрезка до 32 символов) | `{ version }` | Updater | U |
| `update-downloaded` | `main.ts:1148` | только режим `auto` | `{ version }` | Updater | U |
| `update-error` | `main.ts:1169` | ошибка при `updateConfirmed` (только `auto`) | `{ message, releaseUrl }` | Updater | U |
| `screen-share-sources` | `main.ts:1364` | `getDisplayMedia` без свежего предвыбора и не системный пикер | массив источников | ScreenCapture | S |
| `recovery-state-changed` | `main.ts:1457` | изменение `RecoveryState` при `mode === 'recovery'` | `RecoveryState` | Recovery | U |
| `activity-detected` | `main.ts:1482` | смена обнаруженной игры | `Activity \| null` | ActivityDetector | U, S |
| `keybind-action` | `keybindManager.ts:289` | срабатывание или отпускание кейбинда | `{ actionId, pressed }` | KeybindManager | U, S |
| `accessibility-status` | `keybindManager.ts:294` | каждая попытка запуска хука на darwin | `{ trusted }` | KeybindManager | S |
| `keybind-hook-error` | `keybindManager.ts:185` | исключение при запуске хука | `{ message }` | KeybindManager | S |
| `keybind-portal-status` | `keybindManager.ts:107` | только Wayland; на macOS не отправляется | — | — | C (отсутствие) |

---

## 3. Меню и трей

Источник: `recovery.ts:117–260`, `main.ts:528–544`, `main.ts:1424–1462`, `l10n.ts`.

### 3.1. Трей (`buildTrayMenuTemplate`)

| Позиция | Пункт (ключ l10n) | Условие | Действие |
|---------|-------------------|---------|----------|
| 1 | `tray.show` | всегда | `show()` + `focus()` |
| 2 | `tray.hide` | всегда | `hide()` |
| — | разделитель + пункт проверки | `updateState !== 'external'` | см. 3.3 |
| — | пункт действия | `downloaded` или `available-manual` | см. 3.4 |
| — | разделитель | всегда | |
| | `tray.changeInstance` | всегда | `handleRecoveryAction('change-instance')` |
| | `tray.sourceCode` | всегда | `openSourceCode()` |
| — | разделитель | всегда | |
| | `tray.quit` | всегда | `requestQuit()` |

Иконка — `resources/tray-iconTemplate.png` (+`@2x`) как template image, tooltip `Backspace`. Резервная иконка (лавандовый круг 16×16) нужна только при отсутствии файла.

### 3.2. Меню приложения (`buildAppMenuTemplate`)

| Меню | Пункты по порядку |
|------|-------------------|
| `Backspace` | About · `tray.sourceCode` · [разделитель + пункт проверки] · [пункт действия] · разделитель · `tray.changeInstance` · разделитель · Hide · Hide Others · Show All · разделитель · Quit |
| `menu.edit` | Undo · Redo · разделитель · Cut · Copy · Paste · Select All |
| `menu.window` | Minimize · Zoom · разделитель · Bring All to Front |

Больше пунктов нет: ни Cmd+W, ни View, ни Reload, ни зума страницы.

### 3.3. Пункт проверки (`checkForUpdatesItem`)

| `updateState` | Подпись | Активен |
|---------------|---------|---------|
| `idle` и прочие | `update.check` | да |
| `checking` | `update.checking` | нет |
| `downloading` | `update.downloading` | нет |
| `downloaded` | `update.ready` | нет |
| `available-manual` | `update.available` | нет |
| `error` | `update.checkAfterFailure` | да |
| `external` | пункта нет | — |

### 3.4. Пункт действия (`updateActionItem`)

| `updateState` | Подпись | Действие |
|---------------|---------|----------|
| `downloaded` | `update.restartToInstall` | `install-update` |
| `available-manual` | `update.downloadVersion` с `{version}`, без версии — `update.download` | `open-releases` |
| прочие | пункта нет | — |

### 3.5. About и «Исходный код»

- About: `applicationName: 'Backspace'`, `applicationVersion: app.getVersion()`, `copyright: 'AGPL-3.0-only · Source: https://github.com/funpin/backspace'`, `website` тот же URL.
- «Исходный код»: база = `BACKSPACE_URL` ?? сохранённый URL ?? текущий http(s) URL окна. `GET <origin>/api/instance/info`, таймаут 5 с; `sourceCodeUrl` принимается только если строка и начинается с `http://` или `https://`; иначе и при любой ошибке — URL форка.

### 3.6. Перестройка

Трей и меню приложения перестраиваются на каждое изменение `RecoveryState` и на каждый валидный `set-language`. Модули Swift: Tray, AppMenu. Тесты: все 13 кейсов `buildTrayMenuTemplate` / `buildAppMenuTemplate` и 6 кейсов «manual-download» из `recovery.test.ts` переносятся в `U`; пять языков — `S`.

---

## 4. Константы времени

| Константа | Значение | Источник | Модуль Swift | Тест |
|-----------|----------|----------|--------------|------|
| Debounce сохранения окна | 300 мс | `main.ts:436–440` | WindowState | U |
| Первая проверка обновлений | 10 с после старта | `main.ts:1183` | Updater | U (инъекция часов) |
| Периодическая проверка | 4 ч | `main.ts:1189` | Updater | U |
| Watchdog установки | 4 с | `INSTALL_WATCHDOG_MS`, `main.ts:985` | Updater | U |
| Распад `lastCheckResult` и фазы `up-to-date` | 5 с | `main.ts:1120`, `main.ts:1160` | Updater | U |
| Обрезка версии из updater | 32 символа | `main.ts:1092`, `main.ts:1144` | Updater | U |
| Boot-таймер | 20 с, только упакованная сборка и только http(s) | `BOOT_TIMEOUT_MS`, `recovery.ts:270` | Recovery | U |
| Unresponsive | 10 с | `UNRESPONSIVE_GRACE_MS`, `recovery.ts:517` | Recovery | U |
| TTL предвыбора источника | 30 с (включительно) | `screenSharePolicy.ts:42` | ScreenSharePolicy | U |
| Кеш перечисления источников | 1 с (строго меньше) | `screenSharePolicy.ts:57` | ScreenSharePolicy | U |
| Опрос процессов | 15 с, первый сразу | `activityDetector.ts:37` | ActivityDetector | U |
| Таймаут синхронизации словаря | 10 с | `activityDetector.ts` (`fetchRemote`) | ActivityDetector | U |
| Таймаут `/api/instance/info` | 5 с | `main.ts:116` | AppMenu | U |
| Таймаут `codesign -d -r-` | 5 с | `updateCapability.ts` | UpdateCapability | U |
| Максимальная длина отложенной версии | 64 символа | `updateDismissal.ts` | UpdateDismissal | U |
| Лимит вывода `ps` | 1 МБ | `activityDetector.ts` (`maxBuffer`) | ActivityDetector | U |

---

## 5. Файлы в `~/Library/Application Support/Backspace/`

| Файл | Формат | Чтение повреждённого | Запись | Источник |
|------|--------|----------------------|--------|----------|
| `instance-url.json` | `{"url": string}` | `null` | `writeFileSync`, **не атомарно** | `instanceUrl.ts` |
| `window-state.json` | `{"width","height","x","y","isMaximized"}` | значения по умолчанию по каждому полю (1280×800, без позиции, не развёрнуто) | не атомарно, ошибки проглатываются | `main.ts:155–209` |
| `auto-launch.json` | `{"openAtLogin": bool, "startMinimized": bool}` | `openAtLogin: false`, `startMinimized: true` | не атомарно | `main.ts:227–242` |
| `update-state.json` | `{"dismissedVersion": string}` | `null` | не атомарно, ошибка → лог | `updateDismissal.ts` |
| `language.json` | `{"language": "en"\|"ru"\|"de"\|"pt"\|"zh"}` | `null` → локаль ОС → `en` | не атомарно | `l10n.ts` |
| `games-cache.json` | массив (версия 0) или `{"version": number, "games": [...]}` | переход на встроенный `games.json` | **атомарно** (`.tmp` + rename) | `activityDetector.ts` |
| `games-cache-etag.txt` | строка ETag | `null` | не атомарно, ошибки проглатываются | `activityDetector.ts` |
| `global-shortcuts.json` | `{"registered": true}` | — | — | `keybindManager.ts`: читается и пишется только при активном Wayland-портале; **на macOS не читается и не создаётся** |

Дополнительно: одноразовая миграция `~/Library/Application Support/@backspace/desktop` → `…/Backspace` (`userDataMigration.ts`, 6 тест-кейсов) и очистка `~/Library/Caches/@backspacedesktop-updater` в режиме `manual` (`updaterCache.ts`, имя берётся из `app-update.yml` в ресурсах Electron-бандла).

Координаты в `window-state.json` — в системе Electron (начало в верхнем левом углу основного дисплея, Y вниз). Проверка видимости — пересечение с `workArea` дисплея, выбранного `getDisplayMatching`; при невидимости позиция отбрасывается, размер сохраняется.

---

## 6. Жизненный цикл

### 6.1. До `whenReady` (верхний уровень `main.ts`)

| Шаг | Поведение | Модуль Swift |
|-----|-----------|--------------|
| 1 | `app.setName('Backspace')` | Info.plist |
| 2 | Миграция userData; лог `[userData] migrated … → …` или `[userData] migration failed:` | UserDataMigration |
| 3 | `setAsDefaultProtocolClient('backspace')` при каждом запуске | DeepLink |
| 4 | Обработчик `open-url`: до создания окна ссылка откладывается | DeepLink |
| 5 | Блокировка единственного экземпляра; второй экземпляр завершается, первый получает ссылку из аргументов, `restore()`, `show()`, `focus()` | DeepLink |

### 6.2. `whenReady` — порядок по коду

| Шаг | Поведение | Модуль Swift |
|-----|-----------|--------------|
| 1 | Очистка service workers и HTTP-кеша (`await`, до создания окна) | Bridge / WebView |
| 2 | Регистрация обработчика `getDisplayMedia` | ScreenCapture |
| 3 | Регистрация IPC-обработчиков | Bridge |
| 4 | `setOnQuitRequested(requestQuit)` — **до** создания окна | Recovery |
| 5 | Создание окна: восстановление состояния, выбор URL (`BACKSPACE_URL` → сохранённый → picker с `?lang=`), обработчики recovery, навигации, фокуса | Window, InstanceURL, NavigationPolicy |
| 6 | Создание трея | Tray |
| 7 | Настройка About | AppMenu |
| 8 | Подписка меню и трея на `RecoveryState` + первый вызов вручную | Tray, AppMenu |
| 9 | Обработчик `set-language` | L10n |
| 10 | `initAutoUpdater()`: capability, для `manual` — очистка кеша updater, подписки, таймеры 10 с и 4 ч | UpdateCapability, Updater |
| 11 | Запуск определения активности, обработчик `get-current-activity` | ActivityDetector |
| 12 | Проверка deep link в аргументах запуска | DeepLink |

`ready-to-show`: окно показывается, если запуск не скрытый (`--hidden` в аргументах или `wasOpenedAsHidden`); затем отправляется отложенная ссылка.

### 6.3. Окно

| Событие | Поведение |
|---------|-----------|
| `resize`, `move` | сохранение состояния с debounce 300 мс |
| `close` | немедленное сохранение; если не выход — отмена закрытия и `hide()` |
| `closed` | сброс recovery (`markRecoveryExited`, `mode: 'normal'`, `reason: null`) |
| `activate` (клик по Dock) | окна нет → создать; есть → `show()` без `focus()` |
| `will-navigate` | `isNavigationAllowed`; запрет → `[main] Blocked will-navigate to disallowed target: <url>` |
| `window.open` | см. канал `open-internal-route`; прочие http(s) → системный браузер; новое окно не создаётся никогда |

### 6.4. Recovery

| Триггер Electron | Условие | Код причины | Detail |
|------------------|---------|-------------|--------|
| `did-fail-load` | главный фрейм, код ≠ −3 | `load-failed` | `<код> <описание> @ <url>` |
| `render-process-gone` | причина ≠ `clean-exit` | `render-gone` | причина |
| `unresponsive` → 10 с без `responsive` | — | `unresponsive` | `main thread blocked >10000ms` |
| boot-таймер 20 с | упакованная сборка, http(s), пинг не пришёл | `renderer-stalled` | `no rendererReady within 20000ms` |

Вход: обновление стора, лог `[recovery] entered: <code> — <detail>` (пишется и при повторном входе), защита от петли (`inRecoveryMode`), загрузка `recovery.html?lang=`, принудительные `show()` + `focus()`.
Boot-таймер: `did-navigate` сбрасывает таймер и флаг пинга и ставит `pendingArm`; `did-finish-load` взводит таймер, если пинг ещё не пришёл. SPA-навигации (`did-navigate-in-page`) не участвуют.
Действия: `reload` берёт URL из `instance-url.json` (переменная `BACKSPACE_URL` **не учитывается**), лог `[recovery] exited (reload)`; `change-instance` — лог `[recovery] exited (change-instance)`, picker, `show()`, `focus()`; `check-update` ставит `checking` и запускает проверку; `install-update` работает только при `downloaded`; `open-releases`; `quit`.

### 6.5. Завершение (`before-quit`)

`isQuitting = true` → остановка определения активности → остановка менеджера кейбиндов (отпускание всех активных действий, остановка хука).

---

## 7. Тесты TypeScript → Swift

Всего 208 тест-кейсов в 16 файлах. Переносятся все, что относятся к macOS или общей логике.

| Файл | Кейсов | Переносится | Комментарий |
|------|--------|-------------|-------------|
| `recovery.test.ts` | 42 | 42 | стор, `extractErrorCode`, оба меню, boot-таймер, manual-download |
| `updateCapability.test.ts` | 20 | 16 | не переносятся 4 кейса: Flatpak (2), Windows, Linux |
| `updateStatus.test.ts` | 18 | 18 | |
| `updaterCache.test.ts` | 18 | 18 | нужны для очистки кеша, оставшегося от Electron-версии |
| `updateDismissal.test.ts` | 15 | 15 | |
| `systemAudioCapability.test.ts` | 7 | 4 | три кейса macOS + нечитаемая версия; Windows и Linux остаются в TS |
| `systemAudio.test.ts` | 15 | 2 | «is unavailable off Linux» и «gives a client that does not use the source the OS verdict»; остальное — venmic |
| `screenSharePolicy.test.ts` | 11 | 9 | не переносятся два Wayland/X11-кейса |
| `navigationPolicy.test.ts` | 9 | 9 | |
| `l10n.test.ts` | 7 | 7 | плюс проверка побайтового совпадения каталогов с `l10n.ts` |
| `notificationRetention.test.ts` | 7 | 0 | обход сборки мусора Electron; `UNUserNotificationCenter` не требует удержания объектов — обоснование в журнале отклонений |
| `userDataMigration.test.ts` | 6 | 6 | |
| `autoLaunch.test.ts` | 14 | 0 | `--hidden` из Windows-реестра и AppImage; на macOS эти функции не вызываются |
| `keybindManager.test.ts` | 6 | 0 | только Wayland-портал |
| `globalShortcutsPortal.test.ts`, `portalShortcut.test.ts` | 13 | 0 | только Linux |

Итого переносится 146. Новые тесты, которых в TS нет, потому что логика жила в Electron или uiohook: конвертация координат окна, импорт `localStorage` из LevelDB, таблица `kVK_* → DOM code` и совпадение djb2-хешей с TS для всех 113 кодов, логика нажатий и отпусканий кейбиндов (в TS покрыта только Wayland-ветка), сравнение версий и разбор `latest-mac.yml`, правило origin для клика по уведомлению, частичное обновление автозапуска.

---

## 8. Расхождения между заданием, документацией и кодом

Каждый пункт требует решения до фазы 1. Моя рекомендация указана, но выбор за автором задания.

| # | Расхождение | Рекомендация |
|---|-------------|--------------|
| 1 | Задание (§2.2) говорит «запись атомарная, как `atomicWrite()`». В коде атомарно пишется только `games-cache.json`; остальные шесть файлов — обычный `writeFileSync` | Писать атомарно все файлы. Формат и чтение не меняются, откат на Electron не затрагивается. Запись в журнал отклонений |
| 2 | Sender guard стоит только на 8 обработчиках из 36. Остальные защищены тем, что preload существует лишь в главном фрейме | В Swift отклонять сообщения не из главного фрейма для всех каналов на уровне маршрутизатора. Наблюдаемое поведение то же |
| 3 | Electron-трей: `tray.on('click')` переключает видимость окна, но на macOS установлено контекстное меню. Документация говорит «клик переключает окно». Что реально происходит при левом клике, из кода не следует | Проверить на собранном Electron-приложении. Собранной копии на этой машине нет; нужен либо запуск `pnpm build:desktop`, либо разрешение скачать DMG релиза |
| 4 | `will-navigate` в Electron не срабатывает на серверные редиректы (для них отдельное событие `will-redirect`, обработчика нет). `WKNavigationDelegate` получает редиректы в том же `decidePolicyFor` | Применять политику и к редиректам. Это строже Electron; запись в журнал отклонений |
| 5 | Порядок запуска в `desktop.md` (12 шагов) отличается от кода: `setOnQuitRequested` вызывается до создания окна, подписка меню — до updater | Следовать коду (§6.2). Документацию поправить в фазе 1 |
| 6 | Тексты уведомлений об обновлении зашиты на английском в `main.ts:1029–1040` и не проходят через `l10n.ts` | Перенести дословно на английском. Локализация — отдельное изменение для обеих оболочек |
| 7 | Обработчики `set-language` и `get-current-activity` регистрируются после создания окна; теоретически ранний вызов упадёт с «No handler registered» | В Swift регистрировать все каналы до загрузки страницы. На практике ненаблюдаемо |
| 8 | Очистка кеша updater опирается на `app-update.yml` внутри Electron-бандла. В Swift-бандле этого файла не будет | Зашить имя `@backspacedesktop-updater` константой и прогонять через тот же `isSafeUpdaterCacheDirName` |
| 9 | Точный алгоритм выбора релиза в `electron-updater` (GitHub-провайдер, `allowPrerelease`, канал `f`) в коде проекта не описан — он внутри зависимости | В фазе 1 переписать по исходнику закреплённой версии `electron-updater` с тестами на фикстурах ленты релизов. До этого пункт §4.7 задания считается неуточнённым |
| 10 | `setInstanceUrl` сохраняет и загружает любую строку без проверки | Перенести как есть; поведение на невалидной строке зафиксировать тестом контракта на Electron |
| 11 | `accessibility-status` отправляется и системный запрос Accessibility вызывается при каждом `syncKeybinds`, пока доверия нет | Перенести как есть |

---

## 9. Что добавилось после базового коммита (состояние 2.3.2)

Построено по `packages/desktop/src/**` на коммите `7377524f` (2026-11-16). Обозначения те же, что в начале документа.

### 9.1. Мост `window.backspace`: ещё 8 членов (всего 59)

| # | Член | Канал | Тип | Guard | Семантика в Electron | Модуль Swift | Тест |
|---|------|-------|-----|-------|----------------------|--------------|------|
| 52 | `setTrayState(state)` | `set-tray-state` | fire | нет | Принимается только одно из девяти состояний (`isTrayState`): `idle`, `look`, `notify`, `typing`, `voice`, `screen`, `joy`, `dnd`, `offline`; остальное игнорируется. Аниматор переключает цикл кадров | TrayState | U, C, S |
| 53 | `setTrayContext(context)` | `set-tray-context` | fire | нет | `parseTrayContext`: некорректный объект отбрасывается, меню остаётся с последним корректным. Равный текущему (`sameTrayContext`) не перестраивает меню | TrayContext | U, C, S |
| 54 | `onTrayAction(cb)` | `tray-action` | sub | — | отписка: **да**. Аргумент — `TrayAction`: пункт быстрого управления, нажатый в меню трея; действие выполняет страница | Bridge | C, S |
| 55 | `setStreamPointerOverlay(pointers)` | `stream-pointer-overlay` | fire | **да** | Список указателей зрителей; очищается (`sanitizePointers`: границы, цвет только простой `rgb`, длина имён, число указателей). Окно-оверлей создаётся на дисплее, который показывает источник | PointerOverlay | U, C, S |
| 56 | `endStreamPointerOverlay()` | `stream-pointer-overlay-end` | fire | **да** | Закрывает оверлей; дисплей запоминается до следующей выдачи источника | PointerOverlay | C, S |
| 57 | `onStreamPointerOverlayCaptured(cb)` | `stream-pointer-overlay-captured` | sub | — | отписка: **да**. `true`, если оверлей попал в захват (Windows может проигнорировать исключение); на macOS исключение работает, событие приходит с `false` или не приходит | PointerOverlay | C |
| 58 | `getAudioRouters()` | `get-audio-routers` | invoke | **да** | Чужой отправитель → `[]`. На macOS — список запущенных перехватчиков звука по списку процессов (сейчас один: SoundSource, точное совпадение имени исполняемого файла); на остальных платформах `[]` без чтения процессов | AudioRouters | U, C |
| 59 | `reportSystemAudioExclusionFailed()` | `system-audio-exclusion-failed` | invoke | **да** | На не-Windows всегда `false`. Ветка Windows (откат с process loopback) в Swift не переносится | Bridge | C |

### 9.2. События main → renderer: ещё 2 канала (всего 17)

| Канал | Условие | Payload | Модуль Swift | Тест |
|-------|---------|---------|--------------|------|
| `tray-action` | нажат пункт быстрого управления в меню трея, окно существует | `TrayAction` | Tray | S |
| `stream-pointer-overlay-captured` | один раз на окно оверлея, после проверки захвата | `boolean` | PointerOverlay | S |

### 9.3. Второй мост: `window.bspaceUpdate` (окно обновления)

Отдельный preload (`updatePreload.ts`) для `update.html`. Каналы отвечают только своему окну (`updateWindow.test.ts`: «answers only its own window»).

| Член | Канал | Тип | Семантика |
|------|-------|-----|-----------|
| `getState()` | `update-window:get` | invoke | Текущее состояние: статус обновления и установленная версия |
| `onState(cb)` | `update-window:status` | sub | отписка: **да**. Каждое изменение статуса, пока окно открыто |
| `check()` | `update-window:check` | fire | Проверка из окна; не трогает идущую проверку, загрузку и ожидание перезапуска |
| `install()` | `update-window:install` | fire | Перезапуск в обновление |
| `openReleases()` | `update-window:releases` | fire | Страница релизов в браузере |
| `close()` | `update-window:close` | fire | Закрыть окно |

### 9.4. Трей

- Значок анимированный: 9 состояний, 16 кадров (`TRAY_FRAMES`), длительности в `TRAY_ANIMATIONS`. На macOS кадр — шаблонное изображение `tray-<кадр>Template.png` с `@2x`.
- В простое персонаж моргает раз в 3–4 с. При «Уменьшить движение» показывается только неподвижный кадр.
- Вверху меню — быстрое управление из `TrayContext` (`buildTrayControlItems`): до входа ничего; после входа статус; в звонке — название канала (длинное обрезается), микрофон, звук, отключение. Тексты на пяти языках.
- Остальные пункты меню — как в §3.1.

### 9.5. Файлы в `~/Library/Application Support/Backspace/`

| Файл | Назначение | Для macOS |
|------|-----------|-----------|
| `system-audio-state.json` | `processLoopbackMemory.ts`: версия Windows, на которой process loopback был отклонён | не пишется и не читается; переносить не нужно, чужой файл не трогать |

Имена: `APP_DISPLAY_NAME = 'B:SPACE'`, каталог данных `Backspace`, имя элемента входа `Backspace` (`appIdentity.ts`). Бандл — `B-SPACE.app`.

### 9.6. Обновления

- `updateReadyGate.ts`: на macOS состояние «готово к перезапуску» наступает только после того, как Squirrel.Mac подготовил загруженный архив; два события принимаются в любом порядке, срабатывание одно на цикл проверки. В Swift-оболочке Squirrel нет, второе условие заменяется на «архив загружен и подпись нового бандла проверена» (план, §5.4).
- Перезапуск в обновление завершает приложение полностью (исправление 2.3.1/2.3.2).
- `macSign.js` и `macSign.test.ts`: подпись сборки своим сертификатом; требование подписи обязано называть хеш сертификата, ad-hoc отклоняется. Логика переезжает в `bundle.sh`.

### 9.7. Тесты: 289 кейсов в 24 файлах

Новые файлы:

| Файл | Кейсов | Переносится | Комментарий |
|------|--------|-------------|-------------|
| `trayState.test.ts` | 13 | 13 | кейс про имена файлов по платформам переносится в части macOS |
| `trayContext.test.ts` | 9 | 9 | |
| `updateWindow.test.ts` | 9 | 9 | |
| `updateReadyGate.test.ts` | 4 | 3 | не переносится «ready on download on Windows and Linux»; условие готовности меняется (§9.6) |
| `pointerOverlay.test.ts` | 14 | 11 | не переносятся: тип окна на Windows/Linux, панель задач Windows, поиск контрольного цвета в захвате (Windows) |
| `audioRouters.test.ts` | 9 | 8 | не переносится «does not list processes on other platforms» |
| `macSign.test.ts` | 5 | 5 | как проверки `bundle.sh`, не как тесты `BSpaceCore` |
| `processLoopbackMemory.test.ts` | 2 | 0 | только Windows |

Изменившиеся файлы (было → стало):

| Файл | Кейсов | Переносится | Что добавилось |
|------|--------|-------------|----------------|
| `updateCapability.test.ts` | 20 → 21 | 16 → 17 | требование подписи с хешем своего сертификата считается опознанным |
| `systemAudioCapability.test.ts` | 7 → 10 | 4 → 4 | Windows 10 2004+ и `systemAudioDeviceId`; для macOS ничего нового |
| `autoLaunch.test.ts` | 14 → 18 | 0 → 0 | устаревший элемент входа Windows |
| `keybindManager.test.ts` | 6 → 8 | 0 → 0 | Wayland |
| `globalShortcutsPortal.test.ts`, `portalShortcut.test.ts` | 13 → 18 | 0 → 0 | Linux |
| `notificationRetention.test.ts` | 7 → 8 | 0 → 0 | обход сборки мусора Electron |

Итого переносится 146 + 1 + 58 = **205** кейсов из 289 (из них 5 — в проверки скрипта сборки). Остальные 84 относятся к Windows, Linux или к обходам самого Electron и остаются в TypeScript.
