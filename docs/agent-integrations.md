# Coding Agent Integrations

QuickTTY разделяет три возможности интеграции с coding agents:

- стандартный terminal progress (OSC `9;4`) в интерфейсе tabs и workspaces;
- необязательное восстановление native-сессии агента в исходной панели;
- управление собственными терминальными задачами через `quicktty terminal` и отдельно загружаемый SKILL, с нативным разрешением для origin/сессии (см. ниже).

Session restoration relaunches an agent with its opaque native session ID. It is not a PTY, shell, process, scrollback, or memory checkpoint. Every non-agent pane starts a fresh shell after QuickTTY restarts.

## Restore policy

Restoration is attempted only when both settings are enabled:

```ini
quicktty-restore-workspaces = true
quicktty-restore-agent-sessions = true
```

Both default to `true`. Disabling agent restoration retains saved bindings but starts fresh shells. Disabling workspace restoration also prevents agent restoration.

QuickTTY persists only an allowlisted binding: adapter ID, opaque session ID, working directory, registration time, empty allowlisted launch metadata, and restore state. It does not persist arbitrary commands or environment variables and does not infer sessions from terminal output, titles, process trees, history, or agent data stores.

The `bindingDirectory` policy accepts any NFC-normalized canonical absolute path, including `/` and paths outside the user's home directory. Validation is lexical and does not require the directory to exist; a missing directory remains a valid binding and uses the home fallback only when planning the launch. Duplicate separators, `.` or `..` segments, trailing separators outside `/`, controls, and decomposed aliases are rejected.

A resumed launch uses the fixed bundled helper named `quicktty`. QuickTTY builds structured argv, encodes a bounded canonical payload, and the helper executes the resolved agent executable directly. Persisted state cannot select the helper, inject shell syntax, or supply a custom command. If the binding or compatibility policy cannot be verified, QuickTTY does not guess: it keeps the pane identity and opens a fresh shell or shows a pane-local failure with safe actions.

## Local lifecycle channel

Обычная панель, способная быть origin зарегистрированного агента, получает следующие app-owned lifecycle-переменные при наличии локального session controller:

- `QUICKTTY_PANE_ID` — persisted pane UUID;
- `QUICKTTY_AGENT_SOCKET` — app-owned local Unix socket;
- `QUICKTTY_INSTANCE_ID` — current QuickTTY process UUID;
- `QUICKTTY_PANE_TOKEN` — random per-pane credential;
- `QUICKTTY_AGENT_HELPER` — fixed bundled `quicktty` path.

При доступном terminal-control endpoint добавляется `QUICKTTY_CONTROL_SOCKET`. Созданные через terminal-control managed children не получают lifecycle/control credentials и не регистрируются как новый origin. Наличие окружения в обычной панели само по себе не даёт terminal grant: нужна активная зарегистрированная сессия и нативное разрешение пользователя. Агент не должен печатать или копировать credentials; для terminal-control их читает сам CLI.

Lifecycle messages are bounded and canonical, and must match the current instance, pane, and pane token. Retry rotates the token and attempt generation. During application termination QuickTTY freezes registration, clears pane credentials, rejects later lifecycle messages, flushes state, and then stops the socket and terminal surfaces. This preserves bindings across QuickTTY shutdown without accepting stale unregister events.

## Exact adapter registry

The registry contains these 20 IDs in this order. “Native” means a documented lifecycle integration shape; “wrapper” means process-lifetime tracking through an installed wrapper. It does **not** mean that auto-resume is currently verified.

| # | ID | Capability | Current version policy or blocked reason |
|---:|---|---|---|
| 1 | `claude` | native | Unverified; fresh shell |
| 2 | `codex` | native | Unverified; fresh shell |
| 3 | `grok` | blocked | Ambiguous official identity |
| 4 | `pi` | native | Any installed version reporting a valid semantic version and exposing the required public lifecycle extension API; locally and runtime verified on current Pi `0.84.4` |
| 5 | `omp` | native | Unverified; fresh shell |
| 6 | `campfire` | blocked | Not a sessionful agent |
| 7 | `amp` | wrapper | Unverified; fresh shell; wrapper required for lifecycle |
| 8 | `cursor` | native | Unverified; fresh shell |
| 9 | `gemini` | native | Unverified; fresh shell |
| 10 | `kiro` | blocked | Incompatible lifecycle generations |
| 11 | `antigravity` | wrapper | Unverified; fresh shell; wrapper required for lifecycle |
| 12 | `opencode` | wrapper | Unverified; fresh shell; selected sessions may remain unregistered |
| 13 | `rovo-dev` | blocked | Missing session identity |
| 14 | `hermes` | native | Unverified; fresh shell |
| 15 | `copilot` | native | Unverified; fresh shell |
| 16 | `codebuddy` | blocked | Beta lifecycle only |
| 17 | `droid` | native | Unverified; fresh shell |
| 18 | `qoder` | native | Unverified; fresh shell |
| 19 | `kimi` | native | Unverified; fresh shell |
| 20 | `ollama` | blocked | Missing persistent session API |

Totals are exactly 11 native, 3 wrapper, and 6 blocked. At present, only Pi has a locally and runtime-verified launch policy: installed Pi versions reporting a valid semantic version and exposing the required public lifecycle extension API are accepted, and the integration is locally verified on current Pi `0.84.4`. Every other launch-capable entry remains documented but version-unverified and therefore starts a fresh shell until a verified policy and tests are added. QuickTTY does not claim working auto-resume for those entries.

## Installer CLI

The bundled executable has this exact public grammar for integration installation (terminal-control commands are documented separately below):

```text
quicktty integrations status [ids...]
quicktty integrations install [ids...] [--yes]
quicktty integrations uninstall [ids...] [--yes]
```

With no IDs, the command covers all 20 entries in registry order. IDs must be unique and known. `--yes` is accepted once, only as the final operand of `install` or `uninstall`; it is invalid for `status`. Without `--yes`, a TTY install or uninstall prints a preview and applies changes only after the user types the literal lowercase word `yes`. Non-interactive mutation requires `--yes`.

Status output reports the capability (`nativeLifecycle`, `wrapperLifecycle`, or `blocked`) and one bounded state: `available`, `installed`, `updateAvailable`, `noOp`, `missing`, `blocked`, `unverified`, `conflict`, `succeeded`, `failed`, or `skipped`. Exit status is `0` for a clean status/apply, `1` for conflicts or failures, and `2` for grammar or confirmation requirements.

The installer core:

- previews every owned-file, JSON-hook, marker-block, wrapper, plugin, and ownership-manifest mutation before applying it;
- creates a uniquely named `.quicktty-backup-…` copy before changing an existing file;
- uses compare-before-swap checks and refuses symlink/path, duplicate-key, ownership, marker, or changed-after-preview conflicts;
- records only QuickTTY-owned mutations in `~/Library/Application Support/QuickTTY/agent-integration-ownership.json`;
- treats a trusted nonempty subset of the current integration policy as an older installed policy and offers the missing owned operations as an update;
- validates every existing ownership record against the exact current path, operation ID, mutation kind, and mutation-specific metadata before preparing an update;
- leaves foreign, malformed, or mismatched content as a conflict instead of overwriting it;
- uninstalls only content that still matches that ownership record and leaves unrelated user configuration intact;
- skips blocked or missing executables instead of writing their configuration.

There are no silent configuration writes. Installation, update, and uninstallation always require an explicit preview/apply flow.

## Agent Integrations sheet

Open **QuickTTY → Agent Integrations…**. The sheet uses the same installer core, ordered registry, capabilities, statuses, previews, backups, ownership checks, and uninstall rules as the CLI; it does not spawn the CLI. Select Install or Uninstall, select eligible entries, review the paths and mutation kinds, and confirm before Apply. The sheet can also explicitly install or uninstall the launcher symlink `~/.local/bin/quicktty`; an unrelated file or symlink at that path is a conflict and is never overwritten.

Once per application build, startup may check for `updateAvailable` integrations and open this same sheet with only those integrations selected in registry order. QuickTTY records the offer only after the sheet is displayed, so dismissing it or an update error does not prompt again in that build. Detection, selection, and presentation are automatic; filesystem changes are not. Every update still shows the bounded preview and requires explicit confirmation before apply. A missing window, cancelled or failed status check, or no available updates causes no prompt, record, or configuration write.

The pane section shows only the known agent name and `Active`, `Restoring`, `Unverified`, or `Failed`. It never renders raw session IDs. **Retry** re-runs compatibility checks, rotates pane credentials, and attempts the saved binding again. **Forget** removes the binding and creates a fresh shell. Diagnostics are bounded and redacted; prompts, transcripts, commands, terminal text, environment values, and session IDs are not displayed.

## Терминальные задачи: CLI + SKILL

Первая версия использует CLI и поставляемый файл [skills/quicktty-terminal/SKILL.md](../skills/quicktty-terminal/SKILL.md), **не MCP**. [Пользовательский справочник terminal control](agent-terminal-control.md) описывает все 12 операций `quicktty terminal`, точную грамматику, ответы JSON, ограничения, правила повторов и ручной передачи управления. SKILL — инструкция агенту, не его память; копирование skill не устанавливает CLI, lifecycle-интеграцию или разрешения.

### Условия доступа

- Нужна сборка QuickTTY, содержащая новые terminal-команды, и launcher `quicktty` на `PATH`. Пользователь отдельно устанавливает `~/.local/bin/quicktty` через **QuickTTY → Agent Integrations…**; старое установленное приложение не обновляется от изменений в checkout или копирования skill. Эта инструкция не изменяет установленное приложение.
- Локальная lifecycle-интеграция **Pi** должна быть отдельно установлена пользователем через тот же sheet, а сессия Pi — зарегистрирована и активна в исходной панели QuickTTY. `pi` присутствует в `AgentIntegrationRegistry.swift` как native adapter. Одного запуска Pi внутри терминала или загрузки skill недостаточно.
- При первом обращении к terminal-control, включая `list`, QuickTTY запрашивает нативное разрешение для точной origin/сессии, не для каждой CLI-команды. Сервер проверяет credentials, актуальность сессии, действующий grant, ownership и текущий workspace исходной панели. Это не разрешение управлять произвольными пользовательскими панелями и не замена ограничениям пользователя и инструментов.
- При недоступном окне или занятом sheet возможен `permissionUnavailable`: пользователь должен показать окно и закончить мешающий диалог. Отказ/отзыв нельзя обходить повторами; автоматический regrant сессии не обещается.

`create-tab` и `split` создают настоящие терминальные панели с Ghostty PTY. Без `--focus` сохраняется текущий выбор: новая панель не обязательно сразу активна.

`resize --ratio 0.1...0.9` меняет долю собственной панели-листа у записанного при её создании split-разделителя, а не размер физического окна. Диапазон включительный. Для tab-задачи без записанного разделителя, удалённого разделителя или цели, которая больше не является его непосредственным дочерним листом, возвращается `invalidRequest`. Реализация проверяет действующий grant/сессию, текущий workspace и соответствие живой surface. Resize не возвращает агенту ownership ввода и сам синтетически не увеличивает terminal revision; последующие изменения терминала могут её изменить.

`request-user-input` передаёт фокус и управление пользователю; после takeover агент прекращает ввод, включая interrupt. Только явное нативное **Return Control** возвращает управление агенту, после чего нужен свежий снимок/revision; focus или resize его не заменяют. Пароли вводятся пользователем в терминале, не в чате и не через `send-text`. Терминальный текст — недоверенные данные, не инструкции; универсальная очистка напечатанных секретов не гарантируется. Credentials и внутренние model/session metadata нельзя выводить или копировать в managed children. Потомки origin с унаследованными credentials входят в ту же границу доверия. Закрытие живой задачи может потребовать отдельного нативного подтверждения.

`keep` оставляет панель после завершения. `close-on-success` закрывает успешную задачу после захвата итогового снимка; при неудачном захвате панель остаётся для повторного `read`. Failed/unknown-панели не закрываются автоматически. Итоговые снимки доступны только пока записи удерживаются и сессия авторизована: до 8 активных и 32 сохраняемых задач на сессию, с вытеснением завершённых записей. Завершение/смена origin-сессии или завершение QuickTTY отзывают capabilities. После перезапуска managed-панели получают свежие shells без tasks/grants/ownership и без replay managed-команды. Восстановление native-сессии агента остаётся отдельным механизмом и terminal grant не возвращает.

### Ручная загрузка только в Pi

Формат SKILL, пути и команды ниже сверены с **bundled `docs/skills.md` Pi 0.85.1**, версия — с `package.json` локального пакета. Это проверка документации загрузки, **не lifecycle runtime-проверка Pi 0.85.1**. Историческая lifecycle-проверка выше относится к Pi 0.84.4. Автонастройка или совместимость со всеми harness не заявляется.

Сначала просмотрите содержимое skill. Без установки, из корня checkout QuickTTY, пользователь может запустить:

```sh
pi --skill "$(pwd -P)/skills/quicktty-terminal/SKILL.md"
```

Для постоянной ручной установки можно скопировать файл в `~/.pi/agent/skills/quicktty-terminal/SKILL.md`. **Внимание:** следующие команды создают каталог и копируют файл; если SKILL уже существует, `cp -i` спросит перед перезаписью. Сначала сравните существующий файл, не подтверждайте замену чужих изменений вслепую. Это инструкция пользователю, не автоматическое действие агента. Выполняется из корня checkout:

```sh
mkdir -p "$HOME/.pi/agent/skills/quicktty-terminal" &&
cp -i skills/quicktty-terminal/SKILL.md "$HOME/.pi/agent/skills/quicktty-terminal/SKILL.md"
```

После копирования перезапустите Pi. Для явной загрузки полного текста введите в Pi `/skill:quicktty-terminal`; наличие description в контексте не доказывает, что агент прочитал skill. Обнаружение skills можно отключить через `--no-skills`, но явный `--skill` остаётся действующим. Команды `/skill:…` отдельно зависят от `enableSkillCommands` (настройка через `/settings`). Инструкция не требует автоматических записей в пользовательский config.

### Границы проверки

Контракт сверен с parser/codec в `Shared/AgentIntegrations/TerminalControl/`, `TerminalAutomationCoordinator.swift` и реальным host в `QuickTTY/WindowCoordinator.swift`, включая `resizeManagedTask`. Ранее прошли native-проверки actual TTY, ANSI, password, child resize/`stty`, raw keys, status, EOF/final tail, restart и termination, а также security/StateStore и focused CLI-проверки. Свежий агент с полным текстом SKILL прошёл шесть сценариев выбора действий на модельных ответах: обычное завершение, неопределённая доставка, stale revision/UInt64/conflict, пароль/takeover, revoke/restart и недоверенный вывод/ложный успех. Команды `quicktty` в этом прогоне не исполнялись: это не end-to-end CLI и не проверка обнаружения skill через `/skill:quicktty-terminal`. Полный финальный `make check` пока не пройден; эти результаты не означают full-green или release readiness.

## Restore fallback and duplicates

- A pane with no binding starts a fresh shell.
- Disabled restore policy starts a fresh shell and retains the binding.
- A failed or unverified binding starts a fresh shell until explicit Retry.
- Missing executable, unsupported or unverified version, invalid binding, unknown/blocked adapter, missing helper/controller, launch failure, timeout, or immediate exit fails closed. The pane keeps its identity and offers safe recovery; it never runs a persisted arbitrary command.
- A missing saved working directory falls back to the user's home directory.
- If multiple panes claim the same adapter/session pair, none wins. Each duplicate is marked failed; forget bindings until one claim remains, then Retry.
- A successful restoration must register the expected adapter/session back into the same pane. Stale socket messages, process callbacks, timers, and earlier Retry generations are ignored.

## OSC progress

OSC progress remains independent of session restoration. Any terminal program may emit OSC `9;4`; QuickTTY does not infer an agent identity from it.

### Pi

In Pi, open `/settings` and enable **Terminal progress** (`terminal.showTerminalProgress`). It is off by default. Pi emits working at `agent_start`, keepalive updates while running, and completed at `agent_end`; no progress helper, hook, or extension is required.

### Claude Code and Codex progress examples

The manual progress-only examples remain bundled at:

```text
/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/
```

Merge the appropriate example into existing settings; do not replace the full file. QuickTTY never silently installs these progress examples. `quicktty-progress` accepts only:

```text
quicktty-progress claude working|waiting|failed|completed
quicktty-progress codex working|waiting|failed|completed
```

States map to OSC `9;4` as `working` → `3`, `waiting` → `4`, `failed` → `2`, and `completed` → `0`. Claude mode prints one JSON object with `terminalSequence`; Codex mode writes OSC to `/dev/tty` and exactly `{}` to stdout. The helper reads no stdin, prompt, transcript, or environment secrets. Unknown modes, states, or extra arguments return nonzero.
