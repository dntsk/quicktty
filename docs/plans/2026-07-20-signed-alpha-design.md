# Signed Alpha Design

## Цель

Выпустить GhostTerm `0.1.0-alpha.1` как подписанный и нотариально заверенный DMG для Apple Silicon и macOS 15+. После скачивания приложение должно открываться без обхода Gatekeeper.

## Состав сборки

Приложение получает временную иконку `GT`, утверждённую пользователем. В `Info.plist` используются допустимые для macOS значения `CFBundleShortVersionString = 0.1.0` и `CFBundleVersion = 1`; полный ярлык `0.1.0-alpha.1` используется в имени DMG и документации.

В bundle копируются сгенерированные Ghostty resources из `Vendor/ghostty/zig-out/share`: terminfo и каталог `ghostty` с shell integration и встроенными terminal themes. Это устраняет runtime fallback на `xterm-256color` и отключённую shell integration. Ресурсы копируются до подписи приложения. В bundle также включается уведомление о лицензии Ghostty.

## Сборка и подпись

Release script заново проверяет pinned Ghostty, генерирует Xcode project и выполняет arm64 Release archive. Приложение подписывается сертификатом `Developer ID Application` с hardened runtime; sandbox остаётся выключенным, потому что терминалу нужны PTY, shell-процессы и произвольные рабочие каталоги.

Скрипт проверяет версию, архитектуру, наличие обязательных Ghostty resources, подпись и hardened runtime. Затем он создаёт DMG с `GhostTerm.app` и ссылкой на `/Applications`, подписывает DMG и сохраняет его в `.build/Release/`.

## Notarization

Отдельный script отправляет DMG в Apple через имя Keychain profile. Пароли, Apple ID и ключи не передаются аргументами и не читаются из файлов проекта. После статуса `Accepted` script прикрепляет ticket к DMG и проверяет его через `stapler` и Gatekeeper.

Для текущего выпуска используются:

- Team ID: `N8FS9YUZQA`;
- certificate: `Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)`;
- Keychain profile: `ghostterm-notary`.

Эти значения передаются как параметры команды выпуска, а не зашиваются в исходный код.

## Проверка

Перед отправкой выполняются lint, callback-contract, unit/integration tests и Release build. После notarization проверяются подпись приложения, подпись DMG, ticket и Gatekeeper. Финальная ручная проверка выполняется из смонтированного DMG: копирование в Applications, первый запуск, shell, вкладки, splits, Normal/Quake и повторный запуск с восстановлением состояния.

Темы интерфейса, placeholder ошибок surface, multi-tab drag и новые функции в этот выпуск не входят.
