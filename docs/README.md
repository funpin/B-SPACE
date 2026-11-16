# Документация B:SPACE

Здесь всё, что не поместилось на [главную страницу](../README.md): как проект устроен, как его запускать для разработки, как ведётся форк и где что лежит.

## Как устроено

- **Сервер** — Node.js, Fastify, SQLite через Drizzle; один контейнер, данные в `data/`.
- **Клиент** — React, Vite, Tailwind, Zustand; интерфейс «Камень»: графитовые матовые панели для содержимого и плотное стекло для всего, что всплывает поверх.
- **Голос и видео** — LiveKit; сервер только выдаёт токены, медиа идёт через SFU.
- **Приложение** — Electron: глобальные сочетания клавиш, запуск при входе в систему, значок-персонаж в трее, определение запущенной игры. Интерфейс приложение не носит с собой: оно открывает веб-клиент, который отдаёт сервер.
- **Федерация** — запросы между серверами подписаны HMAC, события доставляются через очередь с повторами.

## Разработка

Node.js 22.12 или новее (в `.nvmrc` — 24) и pnpm 10:

```bash
pnpm install
cp deploy/.env.example .env    # задайте JWT_SECRET: openssl rand -hex 32
pnpm dev                       # сервер на :3005, клиент на :5173
pnpm typecheck && pnpm test
```

Экраны можно смотреть без сервера и без звонка: страницы `packages/web/dev-*.html` открываются с того же dev-сервера, например `http://localhost:5173/dev-voice-grid.html`.

Требования к изменениям и порядок pull request — в [CONTRIBUTING.md](../.github/CONTRIBUTING.md). Правила для агента — в [.claude/CLAUDE.md](../.claude/CLAUDE.md).

## Как ведётся форк

- `origin` — этот репозиторий, `upstream` — оригинал. Работа идёт в ветках `feat/…`, `fix/…`, `chore/…` от `main` и попадает в `main` через pull request.
- Оригинал целиком не подтягивается. Нужное исправление оттуда переносится отдельным pull request (`git cherry-pick` из `upstream`), с проверкой, что оно ложится на наш код.
- Версии свои, обычный semver: `2.0.0`, `2.1.0`, `2.0.1`. Поднимаются командой `node scripts/bump-version.mjs 2.1.0`. Релизы до 2.0.0 назывались по оригиналу (`1.11.0-f.1.1` — «ревизия 1.1 поверх оригинального 1.11.0»).
- Релиз — тег `v<версия>` на `main`: [workflow](../.github/workflows/release.yml) собирает обе сборки приложения и создаёт черновик релиза с таблицей загрузок.

## Карта документации

| Где | Что |
|---|---|
| [systems/](systems) | Описание каждой подсистемы: база данных, API, WebSocket, федерация, права, голос, приложение, развёртывание и остальные. Полный список с пояснениями — в таблице «Subsystem Documentation» в [.claude/CLAUDE.md](../.claude/CLAUDE.md). На английском. |
| [systems/deployment.md](systems/deployment.md) | Установка сервера, режимы, резервные копии, обновление, раскладка `deploy/`. |
| [brand/](brand) | Брендбук ([brandbook.md](brand/brandbook.md)), макеты экранов и порядок внедрения дизайна. |
| [decisions/](decisions) | Записи архитектурных решений (ADR). |
| [superpowers/specs/](superpowers/specs), [superpowers/plans/](superpowers/plans) | Проектные документы и планы реализации крупных изменений, по одному файлу `ГГГГ-ММ-ДД-<тема>.md`. |
| [comparison.md](comparison.md) | Сравнение с Discord, Revolt, Spacebar, Matrix и Mumble. На английском. |
| [legal/](legal) | [NOTICE](legal/NOTICE) — сторонние компоненты и их лицензии; [LICENSE-COMMERCIAL.md](legal/LICENSE-COMMERCIAL.md) — коммерческая лицензия оригинального проекта. Сама лицензия AGPL-3.0 лежит в корне: [LICENSE](../LICENSE). |
| [README.en.md](README.en.md) | Главная страница на английском. |
| [screenshots/](screenshots) | Снимки экрана для главной страницы. |

## Структура репозитория

В корне лежит только то, что инструменты ищут именно там. Всё остальное разложено по папкам.

| Папка | Что внутри |
|---|---|
| `packages/` | Код: `shared` (типы, права, константы), `server` (Fastify), `web` (React-клиент), `desktop` (Electron), `desktop-macos` (нативный клиент для macOS на Swift; пока в нём только измерительный стенд). Здесь же общее для всех пакетов: `tsconfig.base.json` и патчи зависимостей в `patches/`. |
| `deploy/` | Всё для сервера: `Dockerfile`, файлы Compose, `Caddyfile`, `.env.example` и скрипты `install.sh`, `update.sh`, `backup.sh`, `restore.sh`, `migrate-layout.sh`, `deploy.sh`. |
| `scripts/` | Скрипты разработки и сборки (версия, иконки, проверка переводов) и отдельные небольшие пакеты: `metrics`, `telemetry-receiver`, `pr-triage`, `directory-hub`. |
| `docs/` | Документация (см. карту выше). |
| `assets/` | Исходники бренда: логотип, персонаж, значки трея, картинка для соцсетей. |
| `site/` | Лендинг и страница статистики (GitHub Pages). |
| `.github/` | Workflows, шаблоны issue и pull request, `CONTRIBUTING.md`, `SECURITY.md`, настройки сканеров в `.github/security/`. |
| `.claude/` | `CLAUDE.md` — правила для агента. |

Файлы в корне и почему они там:

| Файл | Почему в корне |
|---|---|
| `README.md`, `LICENSE` | GitHub показывает README и определяет лицензию по этим путям. |
| `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` | Корень рабочего пространства pnpm. |
| `eslint.config.js`, `eslint-suppressions.json` | ESLint ищет конфигурацию и список подавлений от корня. |
| `.gitignore`, `.nvmrc` | Git и nvm читают их из корня. |

Локально в корне появляются ещё `.env`, `data/` и `livekit.yaml` — это состояние вашей установки или dev-сервера, в git они не попадают.
