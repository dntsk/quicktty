# GhostTerm

Минимальный AppKit-каркас нативного терминала для macOS.

## Требования

- macOS 15 или новее на Apple Silicon;
- полная версия Xcode, а не только Command Line Tools;
- XcodeGen 2.45.4 или новее;
- Apple Swift Format, доступный как `swift format`;
- Zig строго версии 0.15.2 для закреплённой ревизии Ghostty.

Если `DEVELOPER_DIR` не задан, команды сборки используют `/Applications/Xcode.app/Contents/Developer`, не изменяя системный `xcode-select`. Уже заданное значение `DEVELOPER_DIR` сохраняется. В Xcode 26 Metal Toolchain может потребовать отдельной установки командой `xcodebuild -downloadComponent MetalToolchain`; `make doctor` проверяет его наличие.

После клонирования инициализируйте submodule:

```sh
git submodule update --init --recursive
```

## Команды

```sh
make doctor
make ghostty
make generate
make format
make lint
make build
make test
make check
```

## Подписанный alpha DMG и нотарификация

Артефакт alpha предназначен для macOS 15+ на Apple Silicon. Полный ярлык выпуска — `0.1.0-alpha.1`; в метаданных Apple ему соответствуют `CFBundleShortVersionString = 0.1.0` и `CFBundleVersion = 1`. Поэтому ярлык используется в имени DMG, а не в маркетинговой версии bundle.

Перед выпуском нужны полная Xcode в `DEVELOPER_DIR` (по умолчанию `/Applications/Xcode.app/Contents/Developer`), сертификат Developer ID Application команды `N8FS9YUZQA` и заранее сохранённый профиль Keychain `ghostterm-notary`. Репозиторий не хранит Apple ID, пароли, API-ключи или private keys; команды принимают только имя профиля Keychain.

Создать подписанный archive и DMG:

```sh
make release \
  DEVELOPMENT_TEAM=N8FS9YUZQA \
  CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
```

Отправить уже созданный точный DMG на нотарификацию:

```sh
make notarize \
  DMG=.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg \
  NOTARY_PROFILE=ghostterm-notary
```

Выполнить оба этапа последовательно:

```sh
make signed-alpha \
  DEVELOPMENT_TEAM=N8FS9YUZQA \
  CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)' \
  NOTARY_PROFILE=ghostterm-notary
```

`make release` создаёт `.build/Release/GhostTerm.xcarchive` и `.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg`. Перед отправкой `make notarize` требует чистое дерево и проверяет строгую подпись DMG, Developer ID identity, Team ID и надёжную метку времени; затем печатает размер и SHA-256. Только после `Accepted` он прикрепляет тикет, проверяет stapler, повторно проверяет подпись и запускает проверку Gatekeeper. JSON-ответ Apple сохраняется как `.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg.notary-result.json`; финальный вывод содержит путь к DMG, submission ID, SHA-256 и путь к доказательству. Статус нотарификации этого репозитория не подразумевается этой документацией: команду нужно выполнить для конкретного DMG.

`make doctor` проверяет инструменты, а `make ghostty` собирает закреплённый Ghostty в `Vendor/ghostty/macos/GhosttyKit.xcframework`. Повторные команды `make` используют кэшированный XCFramework, пока не изменились pin, toolchain или build script; reuse требует корректного generated stamp с текущим cache key и SHA-256 финального fat archive, единственного архива и репрезентативных символов. Перед rebuild удаляется только stamp текущего ключа, а новый двухстрочный stamp атомарно публикуется после замены и проверки архива. Изменённый, staged либо содержащий неигнорируемые untracked-файлы submodule отклоняется. Для закреплённого Ghostty v1.3.1 build script обходит дефект выравнивания текущего Apple `libtool`: после upstream-сборки он находит единственный native `libghostty.a` и соответствующий Zig cache manifest, затем детерминированно полностью перепаковывает все перечисленные в manifest dependency archives через MRI-режим `zig ar`. Подмена выполняется только для сгенерированного `libghostty-fat.a` после проверки C API и репрезентативных символов bundled-зависимостей; checksum и те же символы проверяются при reuse кэша. Workaround не изменяет upstream source и pin и не очищает `.zig-cache`. Это генерируемый static XCFramework: Xcode-проект линкует его, но не встраивает отдельной копией. `Carbon.framework` и C++ runtime (`-lstdc++`) подключены так же, как в закреплённом upstream macOS app. `make generate` автоматически проверяет эту сборку перед XcodeGen.

Сгенерированные Xcode-проекты, XCFramework и DerivedData не хранятся в Git.
