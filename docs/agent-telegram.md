# Telegram для coding agents — в разработке

В checkout добавлены секция Telegram в **Agent Integrations**, Keychain, фоновый опрос и authenticated CLI-канал вопросов/решений. Поддерживается **явная отправка структурированных запросов зарегистрированным агентом** через `quicktty agent request`. Автоматический перехват произвольных вопросов и нативных permission dialogs всех агентов ещё НЕ реализован; это отдельные адаптеры. Пользователь проверил подключение и pairing реального бота, а затем подтвердил автоматическое появление Connected в новой локальной сборке без повторного токена; полный live-agent question/action round-trip ещё не проверен. AppKit regression выполняется отдельно, по разрешению. Изменения checkout не обновляют установленное приложение и не устанавливают интеграции молча. После однократного подключения сохранённый бот автоматически восстанавливается при запуске; явное выключение Telegram сохраняется между запусками.

## Подключение

1. В новой сборке откройте **QuickTTY → Agent Integrations… → Telegram**. Нужен работающий lifecycle subsystem; при ошибке запуска messaging socket секция недоступна, остальное приложение продолжает работать.
2. Введите token своего выделенного бота в secure field и нажмите **Connect bot**. Не отправляйте token в чат агента. Откройте private chat с ботом и отправьте показанный `/start <code>`.
3. Явно подтвердите предложенный Telegram user ID в приложении. Только после этого token и точная привязка user/chat сохраняются в device-only, non-synchronizable Keychain. Доступность after-first-unlock позволяет отвечать при заблокированном экране; это не сохраняет процессы во время сна Mac.
4. Готово: **Use Telegram for agents** включает канал сразу для зарегистрированных агентов во всех текущих и будущих workspaces. Не нужно выбирать workspace, выдавать разрешение каждой новой сессии или повторять pairing после перезапуска. Это разрешение пользоваться каналом, **не одобрение действий** и не terminal-control grant.
5. Один раз установите/обновите supported integration через обычный preview/apply. Pi автоматически получает `quicktty_ask_user`, `quicktty_confirm_action`, `quicktty_notify` и prompt guidelines. Claude/Codex/Gemini получают CLI-инструкцию после принятой SessionStart регистрации; version-gated Claude hook описан ниже. Копировать инструкции в каждую сессию не нужно. У CLI-only адаптеров автоматический перехват вопросов не заявляется.
6. Ожидающие вопросы доступны также в **Waiting for your reply** QuickTTY. Текст черновика сохраняется при обновлении статуса. Закрытие sheet отменяет только начатый в нём pairing, не фоновое автоподключение и не подключённого бота.

После запуска QuickTTY самостоятельно читает сохранённую привязку из Keychain и подключается, если канал включён. Записи старой сборки тоже восстанавливаются без повторного token/pairing. Временная недоступность Keychain, сети или Telegram при подключении повторяется с backoff/Retry-After; отправки вопросов автоматически не повторяются. Без сохранённого бота сеть не запускается. Выключение **Use Telegram for agents** прекращает сеть и сохраняет паузу между запусками. В **Connection settings** доступны **Reconnect**, **Change bot…** и **Forget bot**; последнее также удаляет сохранённую привязку. QuickTTY не вызывает `deleteWebhook`, если бот занят другим poller/webhook.

## Горячая клавиша и индикатор

`Cmd+Opt+T` переключает общий канал Telegram для **всех** зарегистрированных агентов во всех workspaces. Тот же переключатель доступен в меню QuickTTY → Use Telegram for Agents, в Agent Integrations и по клику на индикатор Telegram в верхней панели normal/Quake. Индикатор различает Off, подключение, On, setup и ошибку; состояние сохраняется. Выключение отзывает pending-запросы и grants, не удаляя бота. Повторное включение восстанавливает соединение, но не старые решения. Shortcut настраивается через `quicktty-shortcut = toggle-telegram=cmd+opt+t`; это локальная комбинация приложения, не глобальный системный hotkey.

## Сценарий

Через Agent Integrations пользователь один раз подключает своего бота и подтверждает личный Telegram-аккаунт. Общий переключатель управляет каналом всех зарегистрированных агентов без повторных workspace/session checkbox. Бот сообщает, что агент ждёт ответа, завершил работу или столкнулся с ошибкой. На конкретный вопрос можно ответить текстом или кнопкой. Вопрос автоматически открывает Telegram Reply через `InlineKeyboardMarkup.force_reply=true`, сохраняя варианты и отмену. У свободного вопроса нет инструкции выбрать несуществующий вариант. Принятый текст подтверждается отдельным кратким сообщением без эха ответа; текст без Reply не назначается наугад сессии, а получает объяснение, пока есть ожидающие запросы. Для действия показываются операция, ресурсы и последствия; подтверждение относится только к одному неизменённому запросу.

Пароли и системные диалоги остаются локальными. Telegram-боты не используют сквозное шифрование; вопросы и краткие результаты покидают Mac. Полный терминальный вывод и внутренние session credentials отправлять не предполагается. Фильтр текста не гарантирует удаления секретов из вопроса: адаптер должен явно выбирать минимальный безопасный payload.

## Pi tools и общий протокол

В Pi инструменты регистрируются через документированный `registerTool` **только после подтверждённой QuickTTY lifecycle registration**. До этого extension не запускает messaging helpers и не добавляет tools в агент вне QuickTTY. Вопрос/action остаётся активным до ответа, отмены или ограниченного deadline; сигнал отмены и session shutdown закрывают его best effort. Повтор того же tool call возвращает сохранённый результат, изменённый payload — conflict. При неопределённой доставке выполняется только readonly status для исходного UUID, без новой отправки.

Если начальная lifecycle registration не подтверждена, Pi сохраняет точный event/payload и делает одну ограниченную попытку перед каждым следующим запуском агента (`before_agent_start`). После успешной регистрации tools и их инструкции доступны уже первому model request; до успеха tools не публикуются. Смена сессии повторяет исходный `session_switch`, а не обходит отказ через `session_start`. В TUI QuickTTY первый сбой показывает короткий код причины без credentials/session metadata; повторные prompts не дублируют предупреждение. Shutdown прекращает восстановление и игнорирует поздний ack. Это повтор регистрации, не автоматический повтор вопросов, подтверждений или уведомлений. Уже установленное расширение обновляется отдельно через обычный preview/apply.

`quicktty_confirm_action` требует operation/resources/consequences, default elevated=true, сам ничего не выполняет и не перехватывает native permissions. Нельзя batch-ить защищённую команду с запросом подтверждения: агент должен получить решение и только затем отдельным шагом выполнять ровно разрешённое действие. SDK hooks технически блокируют весь assistant batch, если в нём есть confirmation и любой другой tool call, независимо от их порядка. Проверяются только имена tools, не содержимое команд; заблокированный batch даже не отправляет вопрос. Tools не гарантируют безопасность последующего поведения модели и не заменяют запреты пользователя/платформы.

`quicktty_notify` отправляет только явно подготовленное краткое сообщение. Это не чтение transcript и не угадывание completion по `agent_end`: low-level run может продолжиться. Автоматического сбора свободного текста вопросов из терминала нет.

API и примеры полностью сверены с локальным Pi **1.5.0**. Extension использует plain JSON Schema и только Node built-ins, без новых runtime dependencies. Loader/mock-helper contract проверяет registration, ответы, elevated default, replay/conflict, cancellation, uncertain delivery и отсутствие session ID в model-facing result. Дополнительно настоящий `AgentSession` и `DefaultResourceLoader` прогнаны с локальным faux provider и mock-helper: ожидающий вопрос действительно блокирует agent loop, ответ возвращается в model transcript, затем агент продолжает работу. Проверены approved/denied, notify, реальная schema validation, abort и запрет confirmation + effect в обоих порядках. Test-only effect меняет только счётчик в памяти. HOME/config/cache/session, settings и credential store изолированы; сетевые соединения запрещены. Это отдельный **SDK runtime с scripted provider/helper**, не живой LLM и не новая auto-resume verification.

Дополнительно единым non-GUI прогоном проверен путь **настоящий Pi SDK → скомпилированный CLI → authenticated lifecycle/messaging sockets → QuickTTY service/ledger → mock Telegram → ответ в SDK**. При включённом канале host автоматически создаёт свежий grant после authenticated регистрации. Используются реальные JSON-запросы, Telegram keyboard data и signed IPC, а не mock-helper. Проверены чужой sender, choice/продолжение, однократная кнопка elevated-подтверждения (обычное «да» отвергнуто), текстовый вопрос с непривязанным/валидным ответом и feedback, deny, notify, abort/cancel и revoke с поздним ответом. В wire messages и model-facing results нет внутренних session/pane credentials. Это всё ещё faux provider и injected Telegram/credential store: **не реальный бот, Keychain или live LLM**.

После успешной authenticated `SessionStart` регистрации Claude, Codex и Gemini helper возвращает общую CLI-инструкцию через документированный `hookSpecificOutput.additionalContext`. Она использует точный bundled helper path, не содержит origin/session credentials и не выдаёт grant. Для Claude передача контекста в настоящий SDK/model request проверена; Codex/Gemini — source/schema evidence и contracts, не vendor runtime.

Для остальных launch-capable adapters общий CLI не требует неподтверждённых vendor APIs, но автоматическая доставка инструкций и native question forwarding пока не реализованы. Кнопка ручного копирования убрана из обычного интерфейса: её наличие не решало интеграцию. Матрица ниже отделяет такой CLI-only backend от проверенных Pi tools и ограниченного Claude question hook.

## Что реализовано в общем механизме

- Неизменяемый request UUID, полный origin (instance/workspace/pane/adapter/session/generation), question с вариантами и action с ресурсами/последствиями.
- Одно сохраняемое включение Telegram для зарегистрированных агентов всех workspaces. Host автоматически создаёт runtime grant только для живой authenticated сессии, проверяя binding, pane и актуальное поколение credentials; Telegram сам grant не выдаёт. Смена origin отзывает старые незавершённые запросы; новый grant не переносит старые ответы/одобрения. После restart старые запросы вообще не восстанавливаются.
- Один ожидающий запрос на origin, до 32 ожидающих и 4096 запросов за время жизни ledger. Завершённые записи сохраняются для replay/conflict; при заполнении новые запросы отклоняются, записи не вытесняются молча.
- Срок запроса 1–1800 секунд, по умолчанию 900. Host использует монотонный ContinuousClock, продолжающий идти во время сна: после пробуждения старое окно подтверждения не продлевается. Expiry, revoke и смена origin закрывают ожидающий запрос.
- Первый принятый локальный или Telegram-ответ закрывает запрос. Повторный ответ не принимается; повтор submit с тем же UUID и идентичным payload возвращает прежний результат, а изменение payload даёт conflict.
- В Telegram любое action, включая elevated, подтверждается кнопкой **«Подтвердить один раз»** под полным неизменённым запросом. Принимается только callback привязанного пользователя в private chat к точному актуальному message/request; обычное «да» не считается разрешением. Локальное elevated-подтверждение в интерфейсе QuickTTY пока сохраняет точную фразу `CONFIRM <request-uuid>`; старые explicit text replies совместимы. Код возвращает решение, но не исполняет команды и не обходит ограничения агента.
- Telegram-ответ принимается только от привязанного user ID в привязанном private chat и только к зарегистрированному message ID. Group, forwarded/relayed, edited и inline-only сообщения не маршрутизируются. Просто написать «да» без reply нельзя.
- Pairing: случайный одноразовый код с TTL 5 минут. `/start <code>` только предлагает кандидата; для доступа нужно отдельное локальное подтверждение именно этого кандидата.
- Plain text без `parse_mode`, previews выключены, `protect_content` включён. Операция не обрезается для помещения в сообщение. В Telegram попадают отображаемые имена workspace/агента и request UUID, но не внутренние session/pane credentials.
- HTTPS JSON POST к фиксированному Telegram endpoint; ephemeral URLSession без redirects, cookies, URL credentials и disk cache; ответ ограничен 1 MiB. Опрос подписывается только на `message`/`callback_query`.
- Клиент не повторяет отправки автоматически. Ошибка сети, 5xx или непроверяемый ответ при отправке означают **неопределённую доставку**, а не доказанное отсутствие сообщения. Токен и сырые URL/response descriptions не включаются в экспортируемые ошибки.

Это гарантирует один принятый ответ, **не exactly-once выполнение внешней операции**. Валидация описания операции не доказывает, что агент правильно оценил её риск.

## CLI-контракт: `quicktty agent request`

При корректной CLI-грамматике helper читает один JSON-запрос из stdin (до 64 KiB), пишет один JSON-ответ с newline в stdout. Credentials CLI читает сам из app-owned окружения: не печатайте их, не передавайте вручную и не копируйте в managed children. Нужны новая сборка, активная lifecycle registration в origin-панели и подключённый Telegram с включённым общим переключателем. Этот API не запускает команды и не вводит клавиши в терминал.

Пример схемы вопроса (пример не запускался; request UUID нужно создавать один раз на свой логический запрос):

```json
{"version":1,"operation":"question","requestID":"53fdbd4e-2bb5-4cc7-8a34-3cfb9491696f","text":"Какой вариант выбрать?","choices":["Первый","Второй"],"timeoutMilliseconds":900000}
```

Для отправки передайте такой JSON в stdin `quicktty agent request`. Допустимы операции:

| `operation` | Поля помимо `version: 1`, `requestID` |
|---|---|
| `question` | `text` (1–2304 bytes), необязательные `choices` (до 8 уникальных строк, каждая до 64 bytes) и `timeoutMilliseconds` (1000–1800000, default 900000) |
| `action` | `text` — точная операция (до 1024 bytes), `resources`, `consequences` (до 768 bytes каждое); необязательные `elevated` и `timeoutMilliseconds`. Default `elevated: true`; изменение risk — часть immutable payload |
| `status` | Только `requestID` исходного question/action |
| `wait` | `requestID` исходного question/action, `timeoutMilliseconds` (100–30000). Ограниченное ожидание, не бесконечный poll |
| `cancel` | `requestID` исходного question/action. Закрывает только pending; уже принятый ответ не отменяет |
| `notify` | `status`: `working`, `waiting`, `completed` или `failed`; `text` — безопасное краткое сообщение до 512 bytes. Новый request UUID на логическое событие; `working` не создаёт уведомления на телефон |

Нативный adapter может программно добавить `sessionID` ко всем своим запросам: host отвергает несовпадение с текущей зарегистрированной сессией, даже если pane credentials ещё актуальны. Этот opaque ID остаётся в локальном IPC; его не нужно читать агенту вручную, показывать модели или отправлять в Telegram.

Строки — UTF-8; управляющие/bidi-control символы и пустой текст отклоняются моделью. Неизвестные и неприменимые поля запрещены. В socket JSON канонический; stdin допускает обычные пробелы, перестановку ключей и UUID в верхнем/нижнем регистре. Duplicate JSON keys запрещены. CLI нормализует UUID перед созданием signed frame; требования к каноническим байтам IPC не ослаблены.

`state` ответа: `pending`, `text` (с `text`), `choice` (с `choiceIndex` с нуля и `text` выбранного label), `approved`, `denied`, `cancelled`, `expired`, `revoked`, `accepted` или `error` (с `code`). Истечение bounded wait возвращает текущий `pending`, не разрешение продолжить действие. `accepted` у notify означает постановку на best-effort отправку, не доставку пользователю.

Exit code: `0` — доменный ответ, включая `pending`/`denied`; `1` — доменная или транспортная ошибка; `2` — недопустимый stdin JSON/CLI grammar. Не определяйте разрешение действия по exit code — только по актуальному `approved` для точного запроса. Повтор чтения прежнего решения не является новым разрешением на повторное выполнение операции.

`permissionRequired` означает отсутствие текущего channel grant (например, Telegram выключен или ещё подключается), `requestIDConflict` — проверки исходного UUID/payload, `deliveryUncertain` — неопределённой доставки. При неопределённой доставке не создавайте новый request UUID: допустим только обоснованный повтор того же запроса с тем же UUID и идентичным payload. Нельзя повторять действие по replay старого `approved`. После session/grant revoke доступ прекращается.

## Состояние адаптеров

Источник локальной проверки: `AgentIntegrationRegistry.swift`, bundled lifecycle resources и `docs/agent-integrations.md`. Существующий lifecycle hook не доказывает наличие question/permission API. В текущем окружении обнаружен только Pi; остальные executable из реестра отсутствуют в PATH. Общий host/CLI-контракт проверен по реестру для 14 launch-capable IDs и отклоняет 6 blocked IDs. Это модельные registrations с настоящим локальным socket, **не запуск 14 внешних CLI и не проверка их hooks**. В UI отдельно показаны **Pi tools**, **Claude 2.1.318 / CLI**, **CLI** и **blocked** (1 + 1 + 12 + 6), без обещания auto-forwarding произвольных dialogs.

| Агент | Существующая lifecycle-интеграция | Messaging capability и граница проверки |
|---|---|---|
| Claude Code (`claude`) | Native; restore policy остаётся version-unverified | CLI + SessionStart context; guarded AskUserQuestion hook устанавливается только через preview/apply. Проверен точный arm64 CLI 2.1.318 / SDK 0.3.318 с faux API/mock Telegram; другие binaries возвращаются к native prompt |
| Codex (`codex`) | Native, version-unverified | CLI + автоматический SessionStart context; vendor runtime не проверен |
| Grok (`grok`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |
| Pi (`pi`) | Native; историческая restore-проверка описана в agent-integrations.md | Явные question/action/status tools; API/loader, SDK loop и единый real CLI/authenticated host/mock Telegram contract Pi 1.5.0; live-model/bot runtime не проверен |
| OMP (`omp`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Campfire (`campfire`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |
| Amp (`amp`) | Wrapper, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Cursor CLI (`cursor`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Gemini CLI (`gemini`) | Native, version-unverified | CLI + автоматический SessionStart context; vendor runtime не проверен |
| Kiro (`kiro`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |
| Antigravity (`antigravity`) | Wrapper, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| OpenCode (`opencode`) | Wrapper, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Rovo Dev (`rovo-dev`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |
| Hermes (`hermes`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| GitHub Copilot CLI (`copilot`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| CodeBuddy (`codebuddy`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |
| Factory/Droid (`droid`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Qoder (`qoder`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Kimi Code (`kimi`) | Native, version-unverified | CLI-only; автоматическая доставка контекста и vendor runtime не проверены |
| Ollama (`ollama`) | Blocked | Не реализованы; сначала устранить lifecycle blocker |

Нет screen scraping, слепого ввода в TTY, придуманных hooks и включения глобального auto-approve. Недоступные возможности должны оставаться явно недоступными. Поддержка Telegram не выводится из возможностей auto-resume и наоборот.

### Проверенные API для следующих native bridges

Профильные разделы официальных rolling docs проверены read-only; схемы vendors не взаимозаменяемы. Установленных CLI, кроме Pi, нет; для Claude проверены отдельные временные official artifacts (ниже), остальные vendor runtimes пока не проверены:

- [Claude Code hooks](https://code.claude.com/docs/en/hooks): `AskUserQuestion` можно отвечать через `PreToolUse` с `permissionDecision: allow`, исходным `questions` и `updatedInput.answers`. Одного `allow` недостаточно. `PermissionRequest` имеет отдельный `decision.behavior`; exit 2 без decision **не отказывает**. Timeout обычного hook может продолжить native flow; fail-closed требует проверенной версии и соответствующей настройки.
- [Codex hooks](https://developers.openai.com/codex/hooks): `PermissionRequest` тоже поддерживает `decision.behavior`, но набор поддержанных полей отличается. Неподдержанный `PreToolUse` output или ошибка MCP callback может оставить tool call незаблокированным. Нельзя печатать обычный QuickTTY response вместо vendor schema или считать hook error гарантированным deny.

Нельзя пересылать общий hook input целиком: он включает raw tool arguments и transcript metadata, а не только явно подготовленный вопрос. Нужны ограниченный projection, точная version policy, cancellation/failure contracts и отдельная runtime-проверка. Claude installer добавляет только ограниченный question hook, Codex native permission hooks не изменялись.

Для Claude реализованы `ClaudeQuestionHook`, `ClaudeQuestionResolver` и явный CLI entry `quicktty internal hook claude PreToolUse`: только main-session `PreToolUse/AskUserQuestion`, 1–4 single-select questions, полные bounded descriptions, стабильные per-question IDs и точный `updatedInput.answers`. Resolver последовательно ждёт ответы через authenticated host, при неопределённой доставке читает только status исходного ID и имеет общий ContinuousClock deadline 300 секунд. SIGTERM/SIGINT/потеря parent и незавершённый запрос вызывают best-effort cancel. Нет grant/unsupported input → `{}` для native fallback; закрытый начатый вопрос → vendor deny без выдуманного ответа. Ответы выдаются только целиком и только для точных существующих labels. Никаких shell/actions, raw transcript, updatedPermissions или arbitrary free text. Owned installer update добавляет `PreToolUse` с точным matcher `^AskUserQuestion$`, timeout 330s и guarded entry `quicktty internal hook claude PreToolUseVerified`. Ранее установленные lifecycle operations сохраняются; preview/backup/upgrade/uninstall проверены во временном HOME, чужие hooks не удаляются. Даже старую owned интеграцию можно удалить без предварительного обновления. Реальные настройки сами не меняются; restore version policy не менялась.

Guard проверяет максимум четыре same-UID parent executable identity (без argv/env/transcript/session inference), пропускает только системные `/bin/sh`, `/bin/bash`, `/bin/zsh` и сверяет SHA256 первого другого executable с официальным arm64 2.1.318 artifact `677a2ea7bf576cedd20e191d973914ed8a41796f53a63b1923381ddc4d5b5e7d`. Fingerprint читается потоково, максимум 512 MiB. Имя файла не является доказательством версии: переименованный точный artifact тоже работает, непроверенный non-shell parent не может заимствовать поддержку у более старого предка. Непроверенный, будущий или нечитаемый binary возвращает `{}` для native fallback, даже при действующем grant; версию из environment не угадываем. Это узкая совместимость с проверенным SDK/native flow, не утверждение о всех сборках, interactive TUI или action permissions. Явный экспериментальный `PreToolUse` entry остаётся для transport contracts и installer его не использует.

Официальный arm64 CLI **2.1.318** и SDK **0.3.318** проверены по SRI, native codesign verify прошёл. Первый изолированный startup probe не проходил; затем blocker снят без реальных ключей: empty `security` mock возвращает «запись не найдена», а документированный `CLAUDE_CODE_TMPDIR` направляет временные файлы внутрь fixture. Реальный Keychain/private files и внешняя сеть остаются запрещены OS sandbox. Простой `-p` отключает AskUserQuestion без SDK-канала и не считается question runtime evidence.

Повторяемый optional contract проверил **настоящий SDK → native CLI → SessionStart registration → real helper/signed IPC → host/ledger → mock Telegram → native tool_result → продолжение**. Четыре исхода через guarded entry: answer/cancel/revoke/fallback, плюс отдельный native answer после переименования копии exact artifact в `2.1.318`; generic SDK permission callback всегда отказывает, никаких auto-approve/action tools. Перед каждым случаем C-probe проверяет разрешение owned file/точного localhost port и отказ outside synthetic file/другому port. SessionStart-инструкция действительно попала в model request. Это native CLI с локальным faux API и injected Telegram/Keychain, **не live LLM/real-bot verification**. SDK abort может вернуть ошибочный tool_result и cleanup turn, ожидая hook; мгновенная остановка всех vendor процессов не обещается.

### Дополнительный source audit и ограничения

- **Codex 0.167.0**, tag `rust-v0.167.0`: `request_user_input` — root-thread-only tool, ждёт клиентский response; аргументы содержат questions, не готовые answers. Async-вариант эмитит сообщения и сразу возвращает accepted. Не переносить Claude updatedInput.answers на эти tools.
- **Gemini 0.67.0**, tag `v0.67.0`: `ask_user` получает ответы через native confirmation callback. BeforeTool меняет args/блокирует вызов, AfterTool работает только после завершения; Notification не выдаёт approval. Подтверждённого question-answer substitution через эти hooks нет.
- **OpenCode 1.19.5**, tag `v1.19.5`: публичный v2 question API имеет asked/replied/rejected и отдельный reply; legacy plugin client и v2 API нельзя смешивать. Нужны проверка session binding, реальный SDK/runtime и cancellation, прежде чем менять plugin.
- **OMP 18.18.3**: официальный `@oh-my-pi/pi-coding-agent` требует Bun >=1.4.4; локально Bun отсутствует. Pi API нельзя считать автоматически совместимым с fork.
- **Cursor rolling hooks**: documented lifecycle — `sessionStart`/`sessionEnd`, а не legacy `session_start`/`session_end` текущего unverified policy. `preToolUse` использует permission/updated_input, не Claude schema. Источник: [Cursor hooks](https://cursor.com/docs/hooks.md). Не выдавать bundled legacy shape за проверенную текущую интеграцию.
- **Hermes source**: human-input observers игнорируют возвращаемые значения, включают типы sudo/clarify/approval и не являются answer callback. Gateway HOOK.yaml/handler.py и CLI plugin/shell hooks различны. Native reply/registration ещё не проверены.
- **Amp**: официальный [plugin API](https://ampcode.com/docs/markdown/plugin-api) имеет registerTool и event handlers; [SDK](https://ampcode.com/docs/markdown/sdk/typescript) — отдельный client flow. Version/runtime и наследование origin credentials не проверены.
- **Antigravity**: официальный [hooks API](https://antigravity.google/docs/hooks) использует toolCall/conversationId и собственные decision/overwrite, а не Claude fields; raw lastUserInput/transcript metadata пересылать нельзя.
- **Qoder**: официальный [SDK quick start](https://docs.qoder.com/en/cli/sdk/quick-start) отделяет approval/user input; vendor/runtime и hook mapping ещё не проверены.
- **Kimi**: Python `kimi-cli` 1.52.0 относится к архивированному поколению; официальный [migration guide](https://moonshotai.github.io/kimi-code/en/guides/migration) переводит на `@moonshot-ai/kimi-code`. Старый marker hook нельзя считать совместимым с новым CLI без runtime-проверки.
- **Copilot 1.0.107**: package/repository identity сверены; README не доказывает native question callback. **Droid**: публичный docs index недоступен в текущей проверке. Оба runtime остаются unverified.
- **Grok, Campfire, Kiro, Rovo Dev, CodeBuddy, Ollama**: существующие lifecycle blockers не сняты; messaging не включает их автоматически. Общий JSON/модельный registry test не заменяет официальный API и runtime.

Эти findings — незавершённый аудит, **не поддержка всех 20 vendors**. Непроверенные installer shapes/versions не следует «чинить» предположениями или обходить global auto-approve.

## Проверки

Для нового сценария «подключить один раз» прошли `make ghostty-resources-test lint build`, compiler-only `build-for-testing` и `git diff --check`. Non-GUI contracts проверяют migration сохранённого бота, persistent pause/resume/forget, retry временных network/Keychain ошибок и остановку при permanent credentials/token errors; автоматический grant existing/new/replaced origins, новые workspaces и отсутствие восстановления старых запросов. Pi SDK → real CLI/IPC → mock Telegram теперь проходит без ручной выдачи grant. Пользовательские credentials/preferences и реальные integrations в этих тестах не используются. После отдельного разрешения прошёл новый focused AppKit/test-host прогон: **46 тестов в 3 suites**, включая общий переключатель без manual grants/copy steps, закрытие sheet во время autoconnect, сохранение reply draft и owned Pi update при конфликтующем PATH launcher. После отдельного локального подписанного запуска пользователь подтвердил автоматическое появление **Connected** для сохранённого бота без повторной настройки. Полный real-bot/live-agent question/action round-trip, keyboard/VoiceOver и normal/Quake smoke этим не подтверждены.

`make agent-messaging-contract` компилирует и выполняет Foundation-only executable с mock Telegram/Keychain и настоящими временными Unix sockets. Он не запускает GUI/test-host, не подключается к Telegram и не читает реальные credentials. Проверки включены в `make lint`; executable ограничен внешним timeout 30 секунд, без частого polling в тестах.

Проверяются replay/conflict, capacity, expiry/revoke, два канала ответа, локальная elevated-фраза и Telegram elevated-кнопка, чужой account/chat/message, callbacks, pairing с обязательным локальным подтверждением аккаунта, API wire contract, неопределённая доставка, Retry-After и cancellation. Проверен race «ответ уже пришёл, sendMessage ещё не вернулся», а также host → authenticated socket → request → local answer → agent status для всех 14 launch-capable registry IDs и отказ для 6 blocked. Это **не end-to-end проверка GUI, реального Telegram или внешних адаптеров**. AppKit проверяется отдельным focused test-host прогоном; каждый запуск требует нового разрешения.

Историческая проверка прежнего UI (до перехода на общий переключатель): после добавления Copy instructions, capability labels и Pi tools разрешённый повторный focused test-host прогон прошёл: **44 теста в 3 suites** (AgentTelegramViewTests, AgentSessionControllerTests, AgentIntegrationsViewControllerTests). Проверены secure token field, отсутствие неявного чтения credentials, сохранение черновиков и копирование инструкции только по клику. Это не ручная проверка keyboard/VoiceOver/normal-Quake и не подключение реального бота. В логе остаются прежние AppIntents service и test-only QoS warnings.

`make ghostty-resources-test lint build`, compiler-only `build-for-testing` и `git diff --check` прошли. `make agent-messaging-contract` также запускает Pi loader/mock-helper проверки и upgrade/backup/uninstall owned extension во временном HOME; реальные настройки не меняются. Отдельный Foundation contract проверяет Claude codec: projection privacy, original questions round-trip, immutable identity/conflict, duplicate keys, неизвестные fields, byte bounds, NFC, reply ID/index/label и запрет partial/approved/pending replies; реальные integrations тест не устанавливает. Foundation contract дополнительно запускает настоящий CLI против authenticated host: native fallback без grant, отказ synthetic executable с именем `claude` при действующем grant, два sequential ответа и SIGTERM cleanup. Owned Claude fixture проверяет exact matcher/timeout/quoted helper, legacy upgrade с backup, uninstall старой policy, сохранение чужих nodes и tamper conflict.

Adapter runner проверяет отказ первой регистрации и восстановление перед prompt: exact payload, отсутствие дублей при concurrent recovery, сохранение предыдущей сессии, постоянный отказ без tools, однократную безопасную диагностику и поздний ack после shutdown. Настоящий Pi SDK проверяет, что после такого сбоя все три tool declarations и prompt guidelines присутствуют уже в первом provider request.

Adapter runner запускает настоящий Pi SDK contract с faux provider/helper и отдельный сквозной SDK/real CLI/authenticated host/mock Telegram contract (каждый ограничен timeout 45 секунд). Сквозной fixture также проверяет unregister, отсутствие повторных сообщений и удаление обоих временных socket endpoints. Он выявил и закрепил regression: noncanonical CLI JSON ошибочно отвергал lowercase UUID из Node; исправлена только нормализация stdin UUID, signed frames остаются canonical. Pi SDK — необязательная локальная проверочная зависимость, ничего не устанавливается: если CLI отсутствует или не содержит SDK package, выводится явный `SKIP`; остальные Foundation/IPC checks продолжают работать. Установленный npm SDK обнаруживается через реальный путь CLI и package identity, без фиксированного Homebrew prefix. Отсутствие SDK не означает, что native runtime прошёл проверку.

Для отдельного native Claude contract нужны заранее проверенные artifacts CLI 2.1.318 и SDK 0.3.318:

```sh
./scripts/tests/agent-messaging-claude-native-test.sh /absolute/path/to/claude /absolute/path/to/sdk/package
```

Runner ничего не скачивает и не устанавливает, не запускает GUI/test-host и не использует реальные credentials. Передаваемые paths должны указывать на доверенные официальные artifacts; неподдержанная версия отклоняется. Все generated HOME/config/process state временные; настоящие installed integrations не меняются.

Официальный источник wire contract: [Telegram Bot API](https://core.telegram.org/bots/api), методы `getMe`, `getUpdates`, `sendMessage`, `answerCallbackQuery`, `editMessageReplyMarkup`.
