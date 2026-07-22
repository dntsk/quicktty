# Handoff: публичная QuickTTY alpha 0.1.0-alpha.2

## Результат

QuickTTY опубликован как public GitHub prerelease:

- repository: `https://github.com/dntsk/quicktty`;
- release: `https://github.com/dntsk/quicktty/releases/tag/v0.1.0-alpha.2`;
- tag: `v0.1.0-alpha.2`;
- tagged commit: `4b367442a62da4f59ad4bfe1bf6b4324efa29fcd`;
- artifact: `QuickTTY-0.1.0-alpha.2-arm64.dmg`;
- size: `9040555` bytes;
- SHA-256: `fe3dac9780de7c23dab57caa34fdfb6c10f28323e6773c4e4423dbe7c3e8ca49`;
- checksum asset: `QuickTTY-0.1.0-alpha.2-arm64.dmg.sha256`;
- release status: public, non-draft, prerelease.

## Apple verification

- Developer ID identity: `Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)`;
- Apple submission ID: `fb215fc9-4de9-44bc-92b5-7506dd6f838b`;
- notarization status: `Accepted`;
- stapler validate: PASS;
- strict DMG codesign verification: PASS;
- Gatekeeper: `accepted`, source `Notarized Developer ID`;
- evidence: `.build/Release/QuickTTY-0.1.0-alpha.2-arm64.dmg.notary-result.json`.

Профиль `quicktty-notary` ещё не создан. Для этой поставки использован явно переданный существующий Keychain profile `ghostterm-notary`; credentials и secret values не читались и не попадали в команды или repository.

## Проверки перед публикацией

- `master` был чист и совпадал с `origin/master`.
- `.agents/scripts/pre-deploy-check.sh`: PASS.
- `make check`: 452 tests, 26 suites, PASS.
- Signed archive и DMG прошли release-script validation.
- Notarized DMG повторно прошёл stapler, codesign и Gatekeeper.
- GitHub asset после публикации скачан по публичному URL без авторизации; SHA-256 совпал с локальным notarized DMG.
- Tag после fetch указывает на точный commit `4b36744`.
- Git-история до перевода repository в public проверена на типовые private-key/token patterns; tracked secret-like filenames не найдены.

## Публикация

- Repository visibility изменена с private на public по явному решению пользователя.
- Release title: `QuickTTY 0.1.0-alpha.2`.
- Release содержит DMG и отдельный checksum asset.
- Release notes фиксируют macOS 15+, Apple Silicon only, clean-start paths и известные ограничения alpha.

## Дальше

- Не перезаписывать tag или assets этого release; любые изменения выпускать новой версией.
- Перед следующим notarization создать `quicktty-notary` либо продолжить явно передавать проверенный профиль через environment.
- Установку и ручной smoke test именно опубликованного QuickTTY DMG в этой сессии не выполняли.
