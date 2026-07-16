# Интеграционные контракты

## Назначение границы

`GhosttyBridge` — единственная точка взаимодействия Swift-кода GhostTerm с нестабильным upstream C API Ghostty. Остальная часть приложения зависит от устойчивых Swift-типов и идентификаторов проекта, а не от заголовков, символов, структур, callback-типов или правил владения Ghostty.

Полная embedding-библиотека `libghostty` закрепляется на конкретной ревизии. Совместимость с произвольной новой ревизией upstream не предполагается.

## Закреплённая ревизия и сборка

- Upstream: Ghostty v1.3.1.
- Commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- Submodule: `Vendor/ghostty`.
- Совместимая версия Zig: строго 0.15.2.

Сборка проверена из `Vendor/ghostty` командой:

```sh
zig build -Dapp-runtime=none -Dxcframework-target=native -Demit-xcframework=true -Demit-macos-app=false -Doptimize=ReleaseFast
```

Проверенный результат: static XCFramework в `Vendor/ghostty/macos/GhosttyKit.xcframework`. Для закреплённого Ghostty v1.3.1 применяется локальный packaging workaround дефекта выравнивания текущего Apple `libtool`: после upstream-сборки build script выбирает единственный native `.zig-cache/o/*/libghostty.a`, экспортирующий `_ghostty_init`, и единственный `.zig-cache/h/*.txt` manifest, который содержит точный relative path этого архива и не менее двух существующих archive inputs. Только финальные поля строк, оканчивающиеся на `.a`, принимаются как входы; каждый путь обязан быть относительным под `.zig-cache/o/` и указывать на валидный архив. Все archive inputs в точном порядке manifest полностью и детерминированно перепаковываются MRI-командами `addlib` через `zig ar -M` во временном каталоге `.build/ghostty`, индексируются `ranlib`, проверяются и только затем атомарно заменяют сгенерированный `libghostty-fat.a`. `ar -x`, изменение upstream source/pin и автоматическая очистка `.zig-cache` не используются. До замены, до записи stamp и при каждом reuse проверяются единственный fat archive и символы `_ghostty_init`, `_ghostty_app_new`, `_ghostty_config_new`, `_ghostty_surface_new`, `_FT_New_Library`, `_ImFontConfig_ImFontConfig`, `_glslang_initialize_process`, `_sentry_malloc`, `_mpack_start_array`, `_zig_os_log_with_type`. Повторная сборка использует кэшированный результат, если не изменились pin Ghostty, версии Zig/Xcode, build script или его фиксированные flags; checksum реализации full repack входит в cache key через checksum build script. Generated stamp имеет строгий двухстрочный формат с cache key и SHA-256 финального repacked fat archive. Reuse требует корректного формата stamp, совпадения ключа и checksum архива, единственного fat archive и всех репрезентативных символов. Перед rebuild из-за отсутствующего или невалидного кэша удаляется только stamp текущего ключа; новый stamp записывается через temporary file и atomic `mv` только после atomic замены, повторной проверки и checksum финального архива. Перед reuse/build проверяются точный HEAD и index gitlink, а изменённый, staged либо содержащий неигнорируемые untracked-файлы submodule отклоняется. XcodeGen добавляет XCFramework в link phase без embed; application target также линкует `Carbon.framework` и C++ runtime через `-lstdc++`, повторяя закреплённый upstream macOS app. В Xcode 26 для компиляции Metal shaders необходим установленный Metal Toolchain.

## Интерфейсы

| Интерфейс | Направление | Контракт | Статус |
|---|---|---|---|
| Engine/config lifecycle | Swift → Ghostty | Bridge создаёт, настраивает и уничтожает engine/config в установленном порядке | Принят |
| Surface lifecycle | Swift → Ghostty | Bridge создаёт и уничтожает terminal surface; наружу передаётся только Swift-обёртка/identity | Принят |
| Keyboard и paste | Swift → Ghostty | Каждая целевая surface получает исходное logical input event; кодирование не переиспользуется от активной pane | Принят |
| Mouse и resize | Swift → Ghostty | События направляются только соответствующей surface; broadcast для них запрещён | Принят |
| Config reload | Swift → Ghostty | Валидная конфигурация применяется ко всем существующим surfaces без перезапуска процессов | Принят |
| Runtime callbacks | Ghostty → Swift | Bridge преобразует callbacks в Swift-события/команды модели и не раскрывает C payloads | Принят |
| Process exit | Ghostty → Swift | Завершение дочернего процесса преобразуется в событие закрытия соответствующей pane | Принят |
| CWD и metadata | Ghostty → Swift | Bridge возвращает устойчивые Swift-значения, пригодные для модели и сохранения state | Принят |
| Theme/config values | Ghostty → Swift | Palette, font, cursor, opacity и ANSI colors поступают из Ghostty config | Принят |

## Правила владения и типов

- Opaque C handles, указатели, C callbacks и upstream enums не выходят за пределы `GhosttyBridge`.
- Bridge владеет соответствием `paneID`/surface и освобождает ресурсы в порядке, требуемом закреплённой ревизией Ghostty.
- Swift-код вне bridge не импортирует upstream C headers и не вызывает C API напрямую.
- На границе используются собственные Swift value types, идентификаторы и ошибки GhostTerm.
- Время жизни callback context должно быть явно связано со временем жизни engine или surface; callback после teardown не должен обращаться к освобождённому состоянию.
- Неизвестные детали владения нельзя угадывать: их проверяют по исходникам и заголовкам закреплённой ревизии.

## Проверенные lifecycle и callback-факты

### Callback ABI и userdata

- Закреплённый header задаёт `wakeup` как `void(void*)`, clipboard callbacks с первым `void*`, `close_surface` как `void(void*, bool)` и `action` как `bool(ghostty_app_t, ghostty_target_s, ghostty_action_s)`: `Vendor/ghostty/include/ghostty.h:972-989`. Runtime config хранит один app-level `userdata` и указатели всех callback-функций: `Vendor/ghostty/include/ghostty.h:991-1000`.
- App-level `userdata` передаётся напрямую только в wakeup callback: `Vendor/ghostty/src/apprt/embedded.zig:232-233`. Action callback синхронно получает `App*`: `Vendor/ghostty/src/apprt/embedded.zig:266-285`; сохранённый app-level `userdata` возвращает `ghostty_app_userdata`: `Vendor/ghostty/src/apprt/embedded.zig:1431-1434`. Поэтому оба callback восстанавливают один independently C-retained callback context: wakeup — прямо из `userdata`, action — через `ghostty_app_userdata(app)`. Raw pointer bridge в C runtime не передаётся, и callbacks не восстанавливают `GhosttyBridge`.
- Surface config имеет отдельный `userdata`: `Vendor/ghostty/include/ghostty.h:440-453`. Именно surface userdata передаётся в read/confirm/write clipboard callbacks и close callback: `Vendor/ghostty/src/apprt/embedded.zig:639-645`, `Vendor/ghostty/src/apprt/embedded.zig:672-720`, `Vendor/ghostty/src/apprt/embedded.zig:737-755`. Task 3A реализует его как независимо C-retained `SurfaceCallbackContext`, не связанный владением с `GhosttyBridge`; контекст хранит только стабильный `PaneID`, close handler и синхронизированное состояние активности.
- Reload action содержит обязательный `soft` payload: `Vendor/ghostty/include/ghostty.h:778-781`; union хранит его в `reload_config`: `Vendor/ghostty/include/ghostty.h:945-955`. Bridge полностью копирует payload в устойчивое Swift-значение `.reloadConfig(soft: Bool)` до выхода из callback.

### Config ownership

- Production bootstrap с `configURL: nil` намеренно создаёт только встроенные finalized defaults через `ghostty_config_new` → `ghostty_config_finalize`: default Ghostty user files и recursive loader не вызываются. Explicit URL загружает только указанный root через `ghostty_config_load_file`, затем сохраняет его recursive includes и выполняет finalize. В закреплённом source `config-file` по умолчанию пуст (`Vendor/ghostty/src/config/Config.zig:2452`), а recursive loader при пустом списке является no-op (`Vendor/ghostty/src/config/Config.zig:4171-4173`), но nil-path всё равно его не вызывает для явного built-in-only контракта. Task 7 передаст bridge будущий GhostTerm effective file для `~/.config/ghostterm/config`; bootstrap до Task 7 не создаёт и не читает этот файл.
- При создании embedded app клонирует переданный config и владеет клоном: `Vendor/ghostty/src/apprt/embedded.zig:124-150`.
- `updateConfig` требует main thread, разрешает caller освободить config сразу после возврата и синхронно публикует `config_change`: `Vendor/ghostty/src/App.zig:134-163`. До вызова action callback embedded runtime клонирует app-level update в собственный `App.config`: `Vendor/ghostty/src/apprt/embedded.zig:288-315`. Bridge преобразует это событие в стабильное `.configChanged`; callback-scoped C config handle намеренно не выходит из bridge.
- Любые непустые diagnostics replacement-конфигурации отклоняют reload до `ghostty_app_update_config`: diagnostics копируются в стабильный `[String]`, replacement освобождается, последняя валидная конфигурация остаётся владельцем bridge, а caller получает `GhosttyBridgeError.invalidConfiguration([String])`. Следующий валидный reload применяется синхронно и очищает diagnostics. Начальная конфигурация с diagnostics по-прежнему допускает bootstrap, чтобы приложение могло показать ошибки.
- Следовательно, bridge сохраняет собственный последний валидный config handle для diagnostics и следующего reload, но Ghostty app не заимствует этот handle. При shutdown bridge сначала деактивирует callback context, вызывает `ghostty_app_free`, освобождает отдельное C-владение context и только затем освобождает свой config.

### Threading и teardown

- Ни один C callback не считается main-thread callback. Все function pointers в `ghostty_runtime_config_s` входят в top-level nonisolated Swift-функции; inline closures с actor isolation не используются. Реальный runtime показал, что action callback может прийти с IO read thread: путь начинается в `Exec.ReadThread.threadMainPosix`, который передаёт PTY output в `Termio.processOutput` (`Vendor/ghostty/src/termio/Exec.zig:1248-1326`), затем parser вызывает `StreamHandler` (`Vendor/ghostty/src/termio/Termio.zig:675-728`), `StreamHandler.surfaceMessageWriter` публикует через `apprt.surface.Mailbox.push` (`Vendor/ghostty/src/termio/stream_handler.zig:125-135`, `Vendor/ghostty/src/apprt/surface.zig:135-155`), а embedded `performAction` синхронно вызывает `action_cb` (`Vendor/ghostty/src/apprt/embedded.zig:266-285`). Попытка использовать inline `@MainActor` C callback на этом пути завершалась runtime actor-isolation crash до выполнения тела callback.
- Action callback полностью копирует C action и payload в устойчивый `GhosttyRuntimeAction` вне main actor. Independently retained `CallbackContext` возвращает `true` только для известного action при наличии handler, совпадении callback app с активным app и постановке `Task { @MainActor ... }`; для неизвестного action, отсутствующего handler или неактивного app возвращается `false`. Task независимо удерживает context и захватывает стабильные action/address, а перед handler повторно сверяет address с mutex-состоянием. Поэтому handler выполняется асинхронно и никогда inline; shutdown/deactivate подавляет уже поставленную доставку. Возвращённый C callback `true` означает, что action был принят в очередь при активном app, но не гарантирует последующую доставку: shutdown между callback и MainActor Task допустимо превращает её в no-op.
- Wakeup является cross-thread сигналом: app mailbox предназначен для отправки сообщений другими потоками, а каждая публикация вызывает runtime wakeup: `Vendor/ghostty/src/App.zig:568-583`. Independently retained app context хранит только address активного app и coalesced pending tick в `Synchronization.Mutex`; top-level wakeup callback ставит явный `Task { @MainActor ... }`. Task повторно читает активный app address и вызывает `ghostty_app_tick` только на MainActor: `Vendor/ghostty/src/apprt/embedded.zig:1423-1428`. `MainActor.assumeIsolated` не используется.
- Surface callback userdata — отдельный `Unmanaged.passRetained(SurfaceCallbackContext)`. Top-level close callback синхронно обновляет только защищённое mutex состояние и ставит `Task { @MainActor [self] ... }`; queued Task тем самым удерживает context до доставки или безопасного no-op. Пока одна доставка pending, новые callbacks не ставят второй actor hop: `false` имеет терминальный приоритет и заменяет pending `true`, pending `false` уже не изменяется, а повторный `true` сохраняет pending `true`. `processAlive == false` означает завершившийся процесс и сохраняет терминальный приоритет при coalescing: context остаётся active до доставки события на MainActor, затем синхронный route удаляет registry/handler и вызывает `surface.close()`, который атомарно деактивирует context, дренирует clipboard tokens и только после этого освобождает surface; coordinator уведомляется после free. Между MainActor route и `close()` нет suspension или lifecycle gap: оба шага выполняются синхронно на MainActor. `processAlive == true` означает запрос подтверждения: context очищает pending delivery, но остаётся active, а bridge сохраняет registry, handler, surface и C retain. Поэтому cancel допускает повторный запрос, а последующий process exit остаётся доставляемым. Подтверждённый explicit close сначала деактивирует context, затем вызывает `ghostty_surface_free`, после возврата освобождает C retain и не вызывает callback handler рекурсивно. Embedded surface при deinit удаляет себя из app и освобождает core surface (`Vendor/ghostty/src/apprt/embedded.zig:595-606`), а core surface до освобождения общего состояния останавливает и `join`-ит search/render/IO threads (`Vendor/ghostty/src/Surface.zig:195-206`, `Vendor/ghostty/src/Surface.zig:776-802`).
- `Surface.close` в закреплённом upstream передаёт runtime результат `needsConfirmQuit()`, а `BaseTerminalController` не удаляет node при `true` до подтверждения (`Vendor/ghostty/macos/Sources/Features/Terminal/BaseTerminalController.swift:401-427`). `WindowCoordinator` является delegate физического `NSWindow`: `windowShouldClose` синхронно запрашивает `ghostty_surface_needs_confirm_quit` через stable `PaneID` lookup и coalesces один aggregated close в общей confirmation queue. Allow закрывает все active surfaces в стабильном порядке до прямого `window.close()`, deny сохраняет окно и surfaces; no-confirm path сначала дренирует surfaces и возвращает `true`. `windowWillClose` инвалидирует confirmations и safety-закрывает остаток. Runtime live-surface close использует ту же queue для одного `PaneID`; process exit инвалидирует pending identity и безопасно вызывает прямой `windowController.close()` после удаления последней surface. Запоздалый ответ не закрывает уже завершившуюся/удалённую pane.
- macOS `nsview` передаётся как unretained platform pointer (`GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift:353-357`; pinned runtime принимает этот pointer в `Vendor/ghostty/src/apprt/embedded.zig:347-379`). Bridge удерживает `GhosttySurfaceView` на всём активном lifecycle, а `close()` выполняет `ghostty_surface_free` и thread joins, пока вызванный метод всё ещё удерживает view живым (`GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift:92-105`). Поэтому renderer не переживает unretained `NSView`.
- `ghostty_app_free` сначала завершает embedded app, затем уничтожает core app: `Vendor/ghostty/src/apprt/embedded.zig:1436-1440`. Core teardown освобождает все surfaces: `Vendor/ghostty/src/App.zig:105-123`. На MainActor shutdown сначала закрывает surfaces, затем обнуляет app address и pending tick context, поэтому уже поставленные main-actor tasks становятся no-op; после этого вызывает `ghostty_app_free`. Единственное C-владение app context освобождается ровно один раз только после возврата из `ghostty_app_free`; путь ошибки `ghostty_app_new` освобождает его без app, а `isolated deinit` повторяет безопасный idempotent fallback. Context не владеет bridge, поэтому цикла нет.

### Hosted unit tests

- `GhostTermApplication.main` всегда выполняет глобальный `ghostty_init` до создания `NSApplication`, включая hosted unit tests.
- Текущий Xcode test host проверенно устанавливает `XCTestConfigurationFilePath` в процессе приложения. `ApplicationEnvironment.isRunningHostedTests` использует только наличие этого environment key; AppDelegate при таком сигнале не создаёт default-config bridge, окно или alert. UI-test application under test запускается отдельным обычным процессом без test bundle injection, поэтому этот критерий не отключает будущие UI-test launches.

## Потоки и concurrency

- AppKit, `NSView` и любые изменения UI выполняются на main thread.
- Bridge обязан явно преобразовывать runtime callbacks в подходящий Swift concurrency context до обращения к модели или UI.
- Чистая модель не зависит от renderer и возвращает команды с `paneID`.
- `@unchecked Sendable` и `nonisolated(unsafe)` не используются для обхода callback/lifecycle-инвариантов.

## Ограничение ресурсов Task 3

Проверенный app bundle содержит Metal library внутри `libghostty`: renderer и terminal surface инициализируются. При этом terminfo и shell integration resources Ghostty пока не добавлены в bundle. Поэтому Ghostty явно откатывается к `xterm-256color` и отключает shell integration. Это не блокирует завершённый Task 3 и остаётся будущей config/resource-работой.

Task 3 завершён после финальных spec PASS и quality APPROVED: 3A покрывает первую AppKit surface, renderer sizing/focus/occlusion, lifecycle, process exit и безопасную callback-доставку; 3B — keyboard/IME; 3C1 — source-only mouse/scroll; 3C2 — clipboard/selection, unsafe paste и OSC52 с асинхронным exactly-once state machine и общей очередью подтверждений. Финальный `make check` прошёл 76 тестов в 5 suites. Интерактивный системный IME, реальный `NSPasteboard` и видимые confirmation sheets вручную не проверены. Broadcast-ввод относится к Task 10 и не реализован.

## Keyboard и IME Task 3B

### Синхронный dataflow

- `GhosttySurfaceView.keyDown`, `keyUp` и `flagsChanged` не кодируют ввод напрямую. Каждый responder override синхронно передаёт тот же исходный `NSEvent` и source `PaneID` в принадлежащий bridge main-actor route. Surface хранит route closure со слабым захватом bridge, поэтому владение bridge → surface не образует цикл.
- Bridge на MainActor ищет source `PaneID` в реестре активных surfaces. В Task 3B событие получает только source surface; отсутствующая или уже закрытая surface означает немедленный no-op. `NSEvent` не попадает в `Task`, Sendable payload или долговременное хранилище. DEBUG-наблюдение после production C-вызова сохраняет только owned Swift metadata и `ObjectIdentifier`, но не event или handle.
- Каждая целевая surface сама вызывает `ghostty_surface_key_translation_mods`, сохраняет скрытые NSEvent bits, при необходимости создаёт только локальный translation event и затем формирует собственный `ghostty_input_key_s`. Если translation modifiers не изменились, используется именно исходный объект event; это обязательный Korean IME invariant закреплённого upstream.
- Будущий broadcast может заменить source-only выбор списком `PaneID`, но обязан передавать каждой surface исходное logical событие. Translation modifiers, `interpretKeyEvents`, composing state и PTY encoding выполняются отдельно на каждой target surface; encoded bytes одной pane никогда не переиспользуются другой.

### Key lifetime и shortcuts

- Opaque surface handle остаётся private main-actor state `GhosttySurfaceView`. Все AppKit responder/NSTextInputClient и C input entrypoints выполняются синхронно на MainActor. `String.withCString` охватывает ровно один синхронный `ghostty_surface_key`, `ghostty_surface_text` или `ghostty_surface_preedit`; C pointer не сохраняется после closure. Для text/preedit в API передаётся точное число UTF-8 bytes без завершающего NUL.
- `ghostty_surface_key == true` означает либо consumed input, либо `.closed`: `Vendor/ghostty/src/apprt/embedded.zig:179-204`. Поэтому после вызова код не обращается к C handle. При нескольких accumulated commits surface callback context проверяется между вызовами; terminal close прекращает последовательность до следующего C-вызова.
- `performKeyEquivalent` работает только для focused keyDown. Он сначала синхронно спрашивает `ghostty_surface_key_is_binding`; binding маршрутизирует исходный event через bridge и потребляется. Не связанные с Ghostty AppKit shortcuts возвращают `false`. Из upstream сохранены только Ctrl+Return, точный Ctrl+/ и timestamp-based `doCommand(by:)` redispatch для command/control; Ghostty menu, AppDelegate key-equivalent, key tables и sequence UI не портированы.
- `flagsChanged` повторяет pinned left/right keycode mapping. Action определяется по aggregate modifier и соответствующему device-side bit; отпускание правого modifier при удерживаемом левом даёт release с оставшимся aggregate bit. Во время marked text modifier events игнорируются.

### IME state

- `GhosttySurfaceView` имеет main-actor local marked text и optional keyDown accumulator. `keyDown` устанавливает accumulator до `interpretKeyEvents`, сохраняет предыдущее marked/layout state, синхронизирует preedit и отправляет committed accumulator через обычный key event. Если текста нет, key event получает pinned composing flag, чтобы отмена preedit не кодировала лишний backspace. Это исключает duplicate text между `interpretKeyEvents` и raw key path.
- `insertText` принимает `String` и `NSAttributedString`: внутри keyDown только добавляет committed text в accumulator, вне keyDown вызывает `ghostty_surface_text`. `setMarkedText` синхронизирует `ghostty_surface_preedit` вне keyDown; `unmarkText`, commit и close очищают local и C preedit. После close все input entrypoints игнорируются.
- Read-only DEBUG-наблюдения доказывают именно пройденную production C-границу: owned `text`/`composing`/result записываются после возврата `ghostty_surface_key`, semantic `.set(Data UTF8)`/`.clear` — после возврата `ghostty_surface_preedit`, а raw view rect и итоговый screen rect — после `ghostty_surface_ime_point` внутри `firstRect`. Они не раскрывают C handle и не представляют внутреннее состояние Ghostty.
- NSTextInputClient использует terminal-minimal ranges: marked text занимает `0..<UTF-16 length`, отсутствующее marked/selected state возвращает пустой `NSRange`; valid attributes пусты, attributed substring всегда `nil`, character index равен `0`. `firstRect` получает реальные x/y/width/height из `ghostty_surface_ime_point`, преобразует top-left surface coordinates в AppKit view/window/screen coordinates и не раскрывает handle.

### Pinned adaptation

Узкая адаптация зафиксирована на commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` и отмечена в first-party исходниках/`THIRD_PARTY_NOTICES.md`. Источники: `macos/Sources/Ghostty/NSEvent+Extension.swift:3-76`, modifier/scoped-wrapper части `macos/Sources/Ghostty/Ghostty.Input.swift`, `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:376-390,641-701,1077-1426,1808-2037` и keyboard-layout ID helper `macos/Sources/Helpers/KeyboardLayout.swift`. Полный upstream macOS Swift wrapper не линкуется и не импортируется. При смене pin нужно вручную сравнить эти paths и ABI `include/ghostty.h:96-119,322-330,1092-1112`, изучить embedded/Surface semantics, перенести только релевантный diff и запустить conversion, responder-route, real PTY и IME tests.

## Mouse и scroll Task 3C1

### Синхронный dataflow и source-only граница

- `GhosttySurfaceView` на MainActor обрабатывает left/right/other down/up, entered/exited/moved, все три drag-варианта и `scrollWheel` напрямую. Mouse/scroll никогда не передаются в keyboard-only `GhosttyBridge.routeInput`, не участвуют в broadcast и не сохраняют `NSEvent` в `Task` либо другом асинхронном хранилище. Две реальные surface в integration test подтверждают, что наблюдения появляются только у source view, а bridge route и вторая surface остаются неизменными.
- Каждый entrypoint синхронно проверяет активный private C handle. После `close()` mouse/scroll являются no-op без C-вызова, DEBUG-наблюдения, повторного tracking area или вызова `super` для right click. Возвращаемый `ghostty_surface_mouse_button` `Bool` означает consumed, а не closed; после C-вызова handle повторно не используется.
- Button call получает точные action/button/modifiers. `NSEvent.buttonNumber` преобразуется как `0 left, 1 right, 2 middle, 3 eight, 4 nine, 5 six, 6 seven, 7 four, 8 five, 9 ten, 10 eleven`, остальные значения — unknown. Модификаторы используют тот же converter, что keyboard. Left/other игнорируют consumed result по pinned AppKit-поведению; right вызывает `super` только при реальном `false` от Ghostty.

### Координаты и scroll ABI

- Позиция вычисляется как `convert(event.locationInWindow, from: nil)`: `x` и `bounds.height - local.y` передаются в logical points. Embedded runtime закреплённой ревизии сам переводит их в scaled pixels. Enter и move обновляют позицию; каждый drag вызывает тот же position path. Exit передаёт `-1/-1`, кроме случая `NSEvent.pressedMouseButtons != 0`, когда pinned поведение продолжает получать drag events за viewport.
- Swift value types фиксируют C ABI mouse state `0...1`, button `0...11`, momentum `0...6` и 32-bit `ghostty_input_scroll_mods_t`. Bit 0 означает precision, bits 1...3 — momentum. Pure tests проверяют все значения, mapping и packing.
- Scroll использует только `scrollingDeltaX/Y`. При `hasPreciseScrollingDeltas` обе оси умножаются на `2`; Swift не применяет config multiplier, потому что pinned `Surface.scrollCallback` сам применяет `mouse-scroll-multiplier`. Momentum берётся именно из `event.momentumPhase`, не `phase`; один реальный `ghostty_surface_mouse_scroll` получает packed flags.

### Focus click, tracking и lifetime

- Каждая активная surface владеет ровно одним `NSTrackingArea` с `mouseEnteredAndExited`, `mouseMoved`, `inVisibleRect`, `activeAlways`. `updateTrackingAreas` удаляет предыдущую owned area перед заменой; `close()`/`deinit` удаляют её и очищают ссылку. Dynamic cursor runtime actions и `acceptsFirstMouse` не добавлены.
- Один узкий local monitor слушает `leftMouseDown` и `keyUp`, слабо захватывает surface и синхронно dispatches по типу. Mouse path сохраняет прежнюю multi-surface семантику: focus-only click активного key window переводит first responder, потребляет down и подавляет следующий left up; activation click возвращается AppKit. Key path перехватывает только Command-modified `keyUp`, если app active, event принадлежит тому же key window и эта surface является first responder; тот же `NSEvent` синхронно маршрутизируется через `PaneID` bridge route как release и monitor возвращает `nil`. Non-Command, unfocused и other-window events возвращаются без изменений. Suppression сбрасывается при потере focus и teardown; monitor удаляется точно один раз при `close()`/`deinit`, а DEBUG ownership tests не оставляют глобальное состояние между serial tests.
- DEBUG-only массивы ограничены 256 owned observations и заполняются только после настоящих C-вызовов: button хранит event identity/action/button/modifiers/consumed, position — identity/x/y/modifiers, scroll — identity/x/y/raw packed flags. C handle и fake production bypass наружу не выдаются.

### Pinned adaptation и проверка

Mouse/scroll-адаптация закреплена на commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. Источники: `include/ghostty.h:59-98,1100-1112`, `macos/Sources/Ghostty/Ghostty.Input.swift:253-535`, `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:376-390,641-701,820-1076`, mouse wrappers `src/apprt/embedded.zig:820-897,1817-1868` и callbacks `src/Surface.zig:3371-3518,3863-4110,4604-4760`. При смене pin нужно вручную сравнить перечисленные ABI/mapping/focus/tracking/scroll paths, убедиться, что units и consumed semantics не изменились, затем запустить pure ABI, synthetic two-surface, focus/teardown и real PTY tests.

Real PTY test создаёт только временный explicit config с `mouse-scroll-multiplier = discrete:1`. Child включает DECSET `?1000h` и `?1006h`, запрашивает DECRQM `?1000$p`, блокирующе читает точный enabled response, затем сигнализирует FIFO. После handshake real C path выдаёт точные SGR bytes left press/release, wheel-up и right press/release; test ожидает process-exit stream без polling и fixed sleep.

## Clipboard Task 3C2

### ABI, owned-типы и системное отображение

- Закреплённый C ABI задаёт clipboard location `standard = 0`, `selection = 1`, request tag `paste = 0`, `OSC 52 read = 1`, `OSC 52 write = 2`, а `ghostty_clipboard_content_s` содержит два NUL-terminated `const char *`: `Vendor/ghostty/include/ghostty.h:43-57`. Callback signatures, runtime-флаг selection clipboard и complete export зафиксированы в `Vendor/ghostty/include/ghostty.h:972-1000,1123-1127`. Swift-код проверяет raw values чистым ABI-тестом; MIME и data копируются в owned `String` до возврата callback.
- Bridge-internal `GhosttyClipboardLocation`, `GhosttyClipboardContent`, `GhosttyClipboardConfirmationRequest` и `GhosttyClipboardClient` не раскрывают C enums/pointers. Confirmation request содержит UUID identity, `PaneID`, location, kind и полный owned массив MIME entries. Отдельный protocol, дублирующий bridge, не введён.
- Production client изолирован MainActor. Standard использует `NSPasteboard.general`; selection намеренно использует отдельный named pasteboard `com.dntsk.GhostTerm.selection`. Namespace принадлежит GhostTerm, а отдельная-board семантика повторяет закреплённый upstream `com.mitchellh.ghostty.selection` без совместного clipboard между приложениями.
- Read precedence точно адаптирован из `NSPasteboard+Extension.swift`: сначала все `NSURL`, file URL превращаются в shell-escaped path, остальные — в `absoluteString`, элементы соединяются пробелом; затем используется `.string`. Write сначала очищает pasteboard, затем сохраняет все поддерживаемые entries. `text/plain` точно отображается в `.string`, `text/html` — в `.html`; остальные MIME проходят через `UTType(mimeType:)` с закреплённым fallback на MIME identifier. Callback content является строковым, не binary-length ABI, поэтому Swift-модель использует `String`, а не произвольный `Data`.

### Callback threads и token state machine

- Все три runtime clipboard function pointer указывают на top-level free functions. Ни один callback не считается main-thread callback. Entry point только восстанавливает independently C-retained `SurfaceCallbackContext`, преобразует location/request tag, немедленно копирует C strings или весь content array, регистрирует mutex-state и ставит явный `Task { @MainActor ... }`. AppKit, `NSPasteboard`, actor-isolated bridge/surface и `main.sync` на callback thread не используются.
- Embedded runtime выделяет один `apprt.ClipboardRequest` перед read callback и уничтожает его сам только при `false` либо после terminal completion: `Vendor/ghostty/src/apprt/embedded.zig:670-730`. Accepted raw address хранится только как internal `UInt` token. `true` означает, что active context принял уникальный token и поставил asynchronous MainActor read; все принятые token либо завершаются один раз, либо атомарно изымаются teardown до `ghostty_surface_free`.
- Read phases: `queued → completingInitial → removed` для safe/empty значения либо `queued → completingInitial → confirmationQueued → removed` для unsafe paste/unauthorized OSC52 read. MainActor read сначала переводит token в `completingInitial`, получает значение injected client и вызывает `ghostty_surface_complete_clipboard_request(surface, data, token, false)` со scoped CString. Закреплённый embedded wrapper синхронно вызывает `confirm_read_clipboard` при `UnsafePaste`/`UnauthorizedPaste` и сохраняет тот же request allocation. Confirm callback копирует data/kind, атомарно переводит только `completingInitial` token в `confirmationQueued` и ставит UI event. После возврата initial completion token удаляется только если синхронный confirm не зарегистрирован.
- Allow/Paste атомарно claims request identity, навсегда инвалидирует token и вызывает terminal completion с исходным owned data и `confirmed = true`. Deny/Cancel claims тот же identity и завершает `"", true`. Late/duplicate response не находит identity и является no-op. Core немедленно копирует CString: `Vendor/ghostty/src/Surface.zig:6115-6305`; CString живёт ровно до возврата C call.
- AppKit pasteboard нельзя синхронно читать с off-main callback, поэтому GhostTerm безопасно расходится с upstream immediate `false` для пустого pasteboard: active read всегда принимается, а отсутствующее значение асинхронно завершается пустой строкой. Это освобождает embedded request allocation и не пишет PTY bytes. Empty-path test ждёт реальный post-C-completion DEBUG event и проверяет нулевой token count.
- Normal write (`confirm = false`) копирует весь MIME array на callback thread, затем пишет client только на MainActor. OSC52 ask write не имеет C state/completion: context сохраняет owned request/content по UUID; Allow выполняет client write, Deny и teardown только инвалидируют request. Реальные OSC52 allow/ask tests подтверждают callback return lifetime и обе ветви.

### Routing, teardown и confirmations

- `SurfaceCallbackContext` владеет только `PaneID`, mutex-protected active/close/token/write metadata и MainActor event closure. Он не владеет C surface, `NSView` или bridge. `GhosttyBridge.makeSurface` передаёт closure со слабым bridge route; bridge повторно ищет active `PaneID`, затем только соответствующий `GhosttySurfaceView` использует private C handle и injected client. Retain cycle отсутствует.
- MainActor teardown имеет критический порядок: context атомарно становится inactive и возвращает все valid read token; пока private C surface жив, каждый token один раз завершается `"", confirmed = true`; затем bridge посылает confirmation invalidation для pane, surface очищает preedit/local input/tracking, обнуляет handle, вызывает `ghostty_surface_free` и только после возврата освобождает C retain context. Queued callback Tasks повторно проверяют state и становятся no-op. Pending OSC writes просто удаляются. App shutdown закрывает и дренирует каждую surface до `ghostty_app_free`.
- Bridge имеет один optional MainActor clipboard confirmation handler. Отсутствующий handler немедленно Deny, а недоступное production window также Deny; ни один путь не авторизует молча. WindowCoordinator использует общую FIFO-модель для clipboard и live-process close sheets. В каждый момент presenter имеет не более одной identity. Live close получает приоритет: clipboard requests той же pane Deny/invalidate, активный clipboard другой pane снимается и возвращается в очередь, затем показывается close. Process exit инвалидирует clipboard/close identity pane; late sheet completion не действует.
- Production presenter использует только AppKit `NSAlert` sheet. Unsafe paste показывает `Warning: Potentially Unsafe Paste`, закреплённое warning-сообщение и кнопки `Cancel`/`Paste`; OSC52 read/write — `Authorize Clipboard Access`, соответствующее сообщение и `Deny`/`Allow`. Полный owned content показывается в read-only selectable monospaced `NSTextView` внутри scroll view. SwiftUI/settings не используются; forced dismiss и response closures используют weak captures.
- `GhosttySurfaceView.copy(_:)`, `paste(_:)`, `pasteSelection(_:)` и стандартный responder `selectAll(_:)` вызывают реальный `ghostty_surface_binding_action` со строками `copy_to_clipboard`, `paste_from_clipboard`, `paste_from_selection`, `select_all` и точным UTF-8 byte count. После close все четыре — no-op. Clipboard не проходит через keyboard broadcast route, context menu/URL hover/dynamic cursor не добавлены.

### Tests, limits и обновление pin

- Serialized MainActor `GhosttyClipboardTests` не обращается к реальному general/selection pasteboard и не читает user config. Injected in-memory client покрывает ABI/mapping, distinct selection, MIME preservation, empty read, missing handler и writes. Реальные surfaces с explicit `/bin/sh -c`, FIFO/query handshake и process-exit event проверяют safe paste, unsafe bracketed/sanitized Allow, Deny без bytes, OSC52 read exact base64/ST response, OSC52 ask/allow writes, а также parsed `copy-me` через реальные `select_all` → `copy_to_clipboard` и core MIME `[text/plain, text/html]`. Arbitrary sleeps, polling, login-shell command и fake C handle/completion seams не используются.
- Teardown tests удерживают unsafe requests, затем явно закрывают одну и shutdown нескольких surfaces; C completion наблюдается до free, context count возвращается, late/duplicate answers являются no-op. Pure confirmation queue tests проверяют FIFO, close priority, forced cancel и exactly-one response без системного sheet.
- DEBUG clipboard observations ограничены 256 owned records и появляются только после реального binding action, C completion или client write; C handle/token не публикуются. Production confirmation intentionally хранит полный content до ответа, поэтому дополнительный first-party truncation limit не вводится. Закреплённый OSC parser может выделять payload больше inline `MAX_BUF = 2048`; при смене pin нужно отдельно проверить parser/allocation limits и не добавлять не подтверждённый ABI length.
- Clipboard-адаптация закреплена на commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. При обновлении нужно вручную сравнить `include/ghostty.h` clipboard ABI, `src/apprt/embedded.zig` allocation/callback return/two-call completion, `src/Surface.zig` paste/copy/OSC52/safety, `Ghostty.App.swift`, `GhosttyPackage.swift`, `Ghostty.Shell.swift:3-17`, `NSPasteboard+Extension.swift`, `Features/ClipboardConfirmation/*`, `BaseTerminalController` confirmation и `SurfaceView_AppKit` bindings; затем прогнать ABI, real PTY, OSC52, queue, teardown и полный integration suite. Интерактивный clipboard/OSC sheet smoke не заявляется до отдельной ручной проверки точного Debug app.

## Стабильный контракт приложения

`GhosttyBridge` покрывает только:

1. lifecycle engine и config;
2. lifecycle terminal surfaces;
3. keyboard, mouse и paste events;
4. resize;
5. config reload;
6. runtime callbacks и process exit;
7. получение cwd и terminal metadata.

Дополнительный protocol, дублирующий bridge, не вводится. Для тестов интеграции используется настоящий `GhosttyBridge`; чистая модель тестируется независимо через команды и `paneID`.

## Ошибки

- Ошибка одной surface преобразуется в состояние placeholder с действиями `Retry` и `Close Pane`; broadcast выключается.
- Ошибка инициализации `libghostty` передаётся приложению для отдельного error window и указания пути к логам.
- Ошибка config reload не уничтожает последнюю валидную конфигурацию.
- Ошибка перехода в Quake не должна уничтожать surface или процесс и приводит к возврату в normal mode.

## Обновление upstream

Изменение закреплённой ревизии Ghostty требует отдельной задачи:

1. изучить diff C headers, lifecycle и callback semantics;
2. изменить только реализацию и Swift-контракт `GhosttyBridge`, если публичное поведение GhostTerm не меняется;
3. проверить сборку `libghostty` под arm64;
4. отдельно сравнить pinned keyboard/IME и mouse/scroll Swift paths, C input ABI, embedded wrappers и core callbacks, не подтягивая полный macOS wrapper;
5. запустить integration tests lifecycle, shell command/output, keyboard conversion/route, mouse source-only/focus/tracking, exact PTY bytes, IME, resize, process exit, config reload и theme update;
6. обновить этот файл и ADR, если контракт или архитектурное решение изменились.

## Журнал изменений контракта

| Дата | Изменение | Причина |
|---|---|---|
| 2026-07-15 | Task 3 закрыт после добавления monitor для Command-`keyUp`, перехвата `performClose`, C-backed resize, реального selection-copy, строгой C import boundary и исправленного teardown-контракта; финальный `make check` прошёл 76 тестов в 5 suites | Финальные проверки дали spec PASS и quality APPROVED |
| 2026-07-15 | Clipboard callbacks переведены на asynchronous owned state machine с synchronous two-call confirm transition, отдельным selection board, injected MainActor client, drain-before-free, FIFO AppKit confirmation/close queue и точными binding actions; реальные PTY/FIFO tests проверяют safe/unsafe paste и OSC52 | Реализация Task 3C2 подготовлена к review; Task 3C и tasks-completed не закрываются до принятия review |
| 2026-07-15 | Mouse/scroll обрабатываются напрямую source `GhosttySurfaceView`, зафиксированы ABI mapping/packing, logical-point coordinates, core-owned multiplier/reporting, focus-only suppression, tracking/monitor lifetime, post-close no-op и pinned update strategy; real PTY DECRQM+FIFO проверяет точные SGR bytes | Реализован контракт Task 3C1 без clipboard; Task 3C и tasks-completed не закрываются до 3C2/review |
| 2026-07-15 | Keyboard responder route сохраняет identity исходного NSEvent и source `PaneID`; каждая surface независимо выполняет translation/IME/encoding; зафиксированы C-string lifetimes, preedit cleanup, shortcut boundary, future broadcast invariant и ручная pinned adaptation strategy | Завершён keyboard/IME-контракт Task 3B без mouse/clipboard/full upstream wrapper |
| 2026-07-15 | Queued runtime action повторно проверяет active app перед MainActor-доставкой и безопасно отбрасывается после shutdown; `processAlive == true` сохраняет surface до подтверждения в AppKit sheet, а false/explicit close освобождают её в установленном порядке | Исправлены два Important lifecycle finding review Task 3A |
| 2026-07-15 | Runtime callbacks переведены на top-level nonisolated entrypoints; action и surface close явно ставят MainActor Tasks; зафиксированы off-main IO action path, independently retained surface context, unretained NSView lifecycle и отсутствие terminfo/shell integration resources в Task 3A | Завершён callback/lifecycle-контракт Task 3A после runtime crash fix |
| 2026-07-14 | Nil-source `GhosttyConfiguration` использует только built-in finalized defaults без default Ghostty user files и recursive loader; explicit file сохраняет recursive includes; Task 7 передаст GhostTerm effective file | Исправлено последнее Important finding review Task 2 |
| 2026-07-14 | Callback userdata заменён на independently C-retained context без ссылки на bridge; reload стал транзакционным по diagnostics, `config_change` стабилизирован как `.configChanged`, hosted tests не создают production UI, cache stamp проверяет SHA-256 fat archive | Исправлены Important findings review Task 2 без surface API |
| 2026-07-14 | Проверены callback signatures/userdata, config clone, cross-thread wakeup/main tick, synchronous action invariant и teardown закреплённого source; reload action преобразуется вместе с `soft` payload | Завершён lifecycle/bootstrap-контракт Task 2 без surface API |
| 2026-07-14 | Закреплены Ghostty v1.3.1, commit и проверенная XCFramework-сборка; workaround Apple `libtool` использует полный `zig ar` repack точных manifest inputs, а application target повторяет upstream Carbon/C++ link requirements | Реализована dependency/tooling-интеграция без изменения upstream source |
| 2026-07-14 | Зафиксирована начальная граница `GhosttyBridge` | Утверждён дизайн MVP |
