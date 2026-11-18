# Меню трея нативного клиента macOS: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** В меню под значком в строке меню микрофон, звук, указки зрителей, камера, демонстрация и выход из звонка становятся рядом круглых кнопок; строки сервера, исходного кода и статусов уходят.

**Architecture:** Содержимое меню по-прежнему решает веб-клиент: он шлёт контекст по `set-tray-context` и исполняет действия из `tray-action`. Контекст получает три необязательных поля, действий становится на три больше. `BSpaceCore` строит из контекста чистую модель меню, `BSpaceShell` рисует её: ряд кнопок это один `NSMenuItem` с собственным видом, который обновляется на месте.

**Tech Stack:** TypeScript (веб-клиент, Vitest), Swift 6.1 в режиме языка 5 (SwiftPM, Swift Testing), AppKit.

**Spec:** [docs/superpowers/specs/2026-11-18-macos-tray-menu-design.md](../specs/2026-11-18-macos-tray-menu-design.md)

## Global Constraints

- Меню Electron-сборки не меняется; `packages/desktop/src/trayContext.ts` и `recovery.ts` не трогаются.
- Новые поля контекста необязательны: без них (сервер со старым веб-клиентом) кнопок «Указки», «Выключить камеру», «Остановить демонстрацию» нет, остальное работает.
- Контекст принимается целиком или не принимается вовсе: поле неверного типа отвергает весь контекст.
- Включить камеру или начать демонстрацию из трея нельзя.
- Значки системные (SF Symbols); строки на пяти языках в `packages/desktop/src/desktopStrings.json`, ключи `mac.tray.*`.
- Без новых зависимостей. Код, комментарии и коммиты на английском.

## Review Focus

1. Сервер со старым веб-клиентом: контекст без трёх новых полей принят, трёх кнопок нет (Task 2, `readsAContextOfAnOlderWebClient`).
2. Контекст меняется при открытом меню: кнопки обновляются на месте, меню не закрывается (Task 3, проверка на собранном приложении).
3. Новое поле неверного типа (`cameraOn: "yes"`): весь контекст отвергнут, меню прежнее (Task 2, `refusesANewFieldOfTheWrongType`).
4. Статус «Нет на месте» и «Не беспокоить»: строка «Не беспокоить» без галочки включает `dnd`, с галочкой возвращает `online`; без статуса строки нет (Task 2, `doNotDisturbTogglesBetweenDndAndOnline`).
5. `stopCamera` и `stopScreenShare`, пришедшие, когда камера или демонстрация уже выключены: ничего не делают, окно настройки демонстрации не открывается (Task 1, `aStopActionDoesNothingWhenThereIsNothingToStop`).

---

### Task 1: Веб-клиент сообщает три новых состояния и исполняет три новых действия

**Files:**
- Modify: `packages/web/src/utils/trayState.ts` (типы `TrayContext`, `TrayAction`, `sameTrayContext`)
- Modify: `packages/web/src/hooks/useTrayBridge.ts` (`readTrayContext`, `runTrayAction`)
- Test: `packages/web/src/hooks/useTrayBridge.test.tsx`, `packages/web/src/utils/trayState.test.ts`
- Test: `packages/desktop/src/trayContext.test.ts` (Electron не замечает новых полей)

**Interfaces:**
- Produces: поля контекста `cameraOn: boolean`, `screenSharing: boolean`, `showPointers: boolean`; действия `{ type: 'toggleShowPointers' }`, `{ type: 'stopCamera' }`, `{ type: 'stopScreenShare' }`.

- [ ] **Step 1: Тесты.** В `trayState.test.ts`: `sameTrayContext` различает контексты, отличающиеся только `cameraOn`, только `screenSharing`, только `showPointers`. В `useTrayBridge.test.tsx`: контекст берёт `cameraOn` из `voiceStore.isCameraOn`, `screenSharing` из `isScreenSharing`, `showPointers` из `showStreamPointers`; `runTrayAction({ type: 'toggleShowPointers' })` переворачивает `showStreamPointers`; тест `aStopActionDoesNothingWhenThereIsNothingToStop`: `stopCamera` при `isCameraOn === false` и `stopScreenShare` при `isScreenSharing === false` не вызывают `handleCameraAction` и `handleScreenShareAction`, при `true` вызывают по одному разу. В `trayContext.test.ts`: `parseTrayContext` принимает контекст с тремя лишними полями и возвращает прежние пять.
- [ ] **Step 2:** `npx vitest run src/utils/trayState.test.ts src/hooks/useTrayBridge.test.tsx` в `packages/web`. Expected: новые тесты падают.
- [ ] **Step 3: Реализация.** Комментарий у `TrayContext` и `TrayAction` в `trayState.ts` меняется: три поля и три действия читает только нативная оболочка macOS, Electron их пропускает.
- [ ] **Step 4:** те же команды плюс `npx vitest run src/trayContext.test.ts` в `packages/desktop`, `npx tsc --noEmit -p .` в `packages/web`, `npx eslint` по изменённым файлам с `--max-warnings 0`. Expected: PASS, чисто.

### Task 2: Ядро строит новую модель меню

**Files:**
- Modify: `packages/desktop-macos/Sources/BSpaceCore/Tray.swift`
- Modify: `packages/desktop-macos/Sources/BSpaceCore/Localization.swift` (ключи)
- Modify: `packages/desktop/src/desktopStrings.json` (пять языков)
- Test: `packages/desktop-macos/Tests/BSpaceCoreTests/TrayTests.swift`

**Interfaces:**
- Consumes: поля и действия Task 1.
- Produces:
  - `TrayContext` получает `cameraOn: Bool?`, `screenSharing: Bool?`, `showPointers: Bool?` (nil, когда поля нет).
  - `TrayAction` получает `.toggleShowPointers`, `.stopCamera`, `.stopScreenShare` (`bridgeValue` с `type` того же имени).
  - `TrayMenuCommand`: `.control(TrayAction)`, `.show`, `.quit`. Остальные случаи удаляются.
  - `public struct TrayControl: Equatable { kind: Kind; tone: Tone; title: String; command: TrayMenuCommand; closesMenu: Bool }`, `Kind`: `.microphone(isOn: Bool)`, `.sound(isOn: Bool)`, `.pointers(isOn: Bool)`, `.stopCamera`, `.stopScreenShare`, `.disconnect`; `Tone`: `.plain`, `.danger`, `.accent`.
  - `TrayMenuItem`: `.separator`, `.label(String)`, `.controls([TrayControl])`, `.toggle(title:isOn:command:)`, `.action(title:command:)`. `.choice` удаляется.
  - Ключи строк: `mac.tray.microphoneOn`, `mac.tray.microphoneOff`, `mac.tray.soundOn`, `mac.tray.soundOff`, `mac.tray.pointersOn`, `mac.tray.pointersOff`, `mac.tray.stopCamera`, `mac.tray.stopScreenShare`. Прежние `tray.disconnect`, `tray.status.dnd`, `tray.show`, `tray.quit`, `tray.inVoice` используются как есть.

Правила модели (из спецификации):

| Кнопка | Когда есть | Тон | Закрывает меню |
|---|---|---|---|
| микрофон | `signedIn` | `.danger`, когда выключен, иначе `.plain` | нет |
| звук | `signedIn` | `.danger`, когда выключен, иначе `.plain` | нет |
| указки | в звонке и `showPointers != nil` | `.accent`, когда включены, иначе `.plain` | нет |
| выключить камеру | `cameraOn == true` | `.danger` | да |
| остановить демонстрацию | `screenSharing == true` | `.danger` | да |
| отключиться | в звонке | `.plain` | да |

Порядок пунктов: подпись звонка (в звонке), ряд кнопок, разделитель, «Не беспокоить» (когда `status != nil`; `isOn` при `.dnd`; команда `.setStatus(.online)` при включённом и `.setStatus(.dnd)` иначе), «Открыть B:SPACE», разделитель, «Выйти». До входа: «Открыть B:SPACE», разделитель, «Выйти».

- [ ] **Step 1: Тесты** (заменяют нынешний `TrayMenuTests` и дополняют `TrayContextTests`): `readsAContextOfAnOlderWebClient` (три поля nil, кнопок три: нет, две: микрофон и звук плюс «Отключиться» в звонке); `readsTheNewFields`; `refusesANewFieldOfTheWrongType` (`cameraOn: "yes"`, `screenSharing: 1`, `showPointers: NSNull()` дают nil); `offersOnlyOpenAndQuitBeforeSignIn`; `showsTheRowOfControlsInACall` (виды, тона, `closesMenu`, порядок по таблице); `leavesOutWhatIsNotGoingOn` (нет камеры и демонстрации: этих кнопок нет; вне звонка нет указок и «Отключиться»); `doNotDisturbTogglesBetweenDndAndOnline`; `everyControlSaysWhatItIsInEveryLanguage` (ни одного пустого заголовка и ни одной фигурной скобки на пяти языках); `saysWhatThePageIsSent` дополняется тремя действиями.
- [ ] **Step 2:** `swift test --filter Tray` в `packages/desktop-macos`. Expected: не компилируется или падает.
- [ ] **Step 3: Реализация** и строки на пяти языках.
- [ ] **Step 4:** `swift test`. Expected: всё проходит. `node scripts/check-i18n.mjs` из корня, `npx vitest run` в `packages/desktop` (каталог строк общий). Expected: чисто.

### Task 3: Оболочка рисует ряд кнопок

**Files:**
- Modify: `packages/desktop-macos/Sources/BSpaceShell/Tray.swift` (`SystemTrayPresenter`, новый `TrayControlsView`)
- Modify: `packages/desktop-macos/Sources/BSpaceShell/MainWindowController.swift` (`trayItemChosen`: остаются `.control`, `.show`, `.quit`)
- Modify: `packages/desktop-macos/Sources/ContractCheck/main.swift` (`CheckTrayPresenter`, `checkTray`)

**Interfaces:**
- Consumes: модель Task 2.
- Produces: `TrayPresenter` без изменений (`show`, `setMenu`, `onCommand`).

- [ ] **Step 1:** обновить `checkTray`: ожидаемые пункты меню до входа, в звонке с камерой и демонстрацией и вне звонка; выбор каждой кнопки ряда доходит до страницы как `tray-action`; «Сменить сервер» и «Исходный код» из проверки уходят; смена языка и сброс при смене страницы остаются. Запустить `--check tray`. Expected: падает.
- [ ] **Step 2: Реализация.** `TrayControlsView` это `NSView` с кнопками 30 pt, шаг 8 pt, поля 14 pt; значок SF Symbols по виду кнопки (`mic.fill`/`mic.slash.fill`, `speaker.wave.2.fill`/`speaker.slash.fill`, `cursorarrow.rays`/`cursorarrow`, `video.slash.fill`, `rectangle.on.rectangle.slash.fill`, `phone.down.fill`), круг цвета тона (`.danger` — `systemRed`, `.accent` — `controlAccentColor`, `.plain` — `quaternaryLabelColor`), `toolTip` и подпись доступности из `title`. Нажатие шлёт команду; при `closesMenu` вызывает `menu.cancelTracking()`. `setMenu`, когда меню открыто и пункты отличаются только содержимым ряда, обновляет вид на месте; иначе собирает меню заново.
- [ ] **Step 3:** `swift build`, `--check tray`, `./scripts/contract-check.sh`. Expected: всё проходит.
- [ ] **Step 4: На собранном приложении** (`./scripts/bundle.sh`, тестовая страница на 127.0.0.1): снимок открытого меню до входа, в звонке с камерой и демонстрацией, вне звонка; нажатие каждой кнопки через системные события и ответ страницы; обновление кнопки микрофона без закрытия меню.

### Task 4: Документы

**Files:**
- Modify: `packages/desktop-macos/README.md` (раздел «The tray», абзац про `--check tray`)
- Modify: `docs/superpowers/plans/2026-11-16-macos-native-client.md` (состояние этапа 3, отклонение 31 «меню трея отличается от Electron-сборки по решению владельца от 2026-11-18»)
- Modify: `docs/systems/desktop.md` (поля `TrayContext` и действия `TrayAction`: какие читает только нативная оболочка)

- [ ] **Step 1:** обновить три документа по сделанному, с тем, что проверено на экране и что нет.
