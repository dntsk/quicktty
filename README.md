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

`make doctor` проверяет инструменты, а `make ghostty` собирает закреплённый Ghostty в `Vendor/ghostty/macos/GhosttyKit.xcframework`. Повторные команды `make` используют кэшированный XCFramework, пока не изменились pin, toolchain или build script; reuse требует корректного generated stamp с текущим cache key и SHA-256 финального fat archive, единственного архива и репрезентативных символов. Перед rebuild удаляется только stamp текущего ключа, а новый двухстрочный stamp атомарно публикуется после замены и проверки архива. Изменённый, staged либо содержащий неигнорируемые untracked-файлы submodule отклоняется. Для закреплённого Ghostty v1.3.1 build script обходит дефект выравнивания текущего Apple `libtool`: после upstream-сборки он находит единственный native `libghostty.a` и соответствующий Zig cache manifest, затем детерминированно полностью перепаковывает все перечисленные в manifest dependency archives через MRI-режим `zig ar`. Подмена выполняется только для сгенерированного `libghostty-fat.a` после проверки C API и репрезентативных символов bundled-зависимостей; checksum и те же символы проверяются при reuse кэша. Workaround не изменяет upstream source и pin и не очищает `.zig-cache`. Это генерируемый static XCFramework: Xcode-проект линкует его, но не встраивает отдельной копией. `Carbon.framework` и C++ runtime (`-lstdc++`) подключены так же, как в закреплённом upstream macOS app. `make generate` автоматически проверяет эту сборку перед XcodeGen.

Сгенерированные Xcode-проекты, XCFramework и DerivedData не хранятся в Git.
