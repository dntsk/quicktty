# Signed Alpha Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Собрать GhostTerm `0.1.0-alpha.1` в подписанный и нотариально заверенный DMG для Apple Silicon и macOS 15+.

**Architecture:** Xcode собирает и подписывает arm64 Release app с hardened runtime. Build phase добавляет сгенерированные Ghostty runtime resources до CodeSign. Отдельные POSIX shell scripts создают DMG и отправляют его в Apple через заранее сохранённый Keychain profile, не принимая секреты в командной строке.

**Tech Stack:** Swift 6, AppKit, XcodeGen, asset catalogs, POSIX shell, `xcodebuild`, `codesign`, `hdiutil`, `notarytool`, `stapler`, `spctl`.

---

### Task 1: Версия и временная иконка

**Files:**
- Create: `GhostTerm/Assets.xcassets/Contents.json`
- Create: `GhostTerm/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `GhostTerm/Assets.xcassets/AppIcon.appiconset/*.png`
- Create: `scripts/generate-app-icon.swift`
- Modify: `project.yml`

**Step 1: Зафиксировать генератор утверждённой иконки**

Перенести утверждённый AppKit-генератор из `/tmp/ghostterm-icon-preview.swift` в `scripts/generate-app-icon.swift`. Генератор должен создавать master PNG 1024×1024 и полный macOS AppIcon set без внешних зависимостей.

**Step 2: Сгенерировать asset catalog**

Запустить:

```bash
swift scripts/generate-app-icon.swift GhostTerm/Assets.xcassets/AppIcon.appiconset
```

Проверить через `sips`, что созданы 16, 32, 64, 128, 256, 512 и 1024 px варианты и корректный `Contents.json`.

**Step 3: Добавить metadata**

В `project.yml` установить:

```yaml
MARKETING_VERSION: 0.1.0
CURRENT_PROJECT_VERSION: 1
ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
INFOPLIST_KEY_CFBundleDisplayName: GhostTerm
```

Полный prerelease label `0.1.0-alpha.1` не помещать в `CFBundleShortVersionString`, потому что Apple ожидает числовую версию.

**Step 4: Собрать Release без подписи и проверить bundle**

```bash
make generate
xcodebuild -project GhostTerm.xcodeproj -scheme GhostTerm -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Ожидание: Release build проходит; `Info.plist` содержит `0.1.0`/`1`; в app bundle есть скомпилированная иконка.

**Step 5: Commit**

```bash
git add GhostTerm/Assets.xcassets scripts/generate-app-icon.swift project.yml
git commit -m "feat: add alpha version and app icon"
```

### Task 2: Ghostty runtime resources и лицензия

**Files:**
- Create: `scripts/copy-ghostty-resources.sh`
- Create: `GhostTerm/Resources/ThirdPartyNotices.txt`
- Modify: `project.yml`

**Step 1: Написать строгий resource-copy script**

Скрипт принимает ровно destination `Contents/Resources`, проверяет source sentinels:

```text
Vendor/ghostty/zig-out/share/terminfo/78/xterm-ghostty
Vendor/ghostty/zig-out/share/ghostty/shell-integration
```

Затем копирует `terminfo` и `ghostty` с сохранением структуры. Он может заменять только эти два каталога внутри Xcode build product и должен отклонять пустой, корневой или неожиданный destination.

**Step 2: Подключить script до CodeSign**

Добавить target build script в `project.yml`, вызывающий:

```sh
"$SRCROOT/scripts/copy-ghostty-resources.sh" \
  "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
```

Ghostty build остаётся источником ресурсов; generated `zig-out` не коммитится.

**Step 3: Добавить license notice**

Включить точный текст `Vendor/ghostty/LICENSE` и ссылку на pinned revision в `GhostTerm/Resources/ThirdPartyNotices.txt`.

**Step 4: Проверить Debug и Release bundles**

После сборки проверить наличие:

```text
Contents/Resources/terminfo/78/xterm-ghostty
Contents/Resources/ghostty/shell-integration
Contents/Resources/ghostty/themes
Contents/Resources/ThirdPartyNotices.txt
```

Ожидание: paths находятся внутри app до подписи; структура совпадает с поиском ресурсов pinned Ghostty.

**Step 5: Commit**

```bash
git add scripts/copy-ghostty-resources.sh GhostTerm/Resources/ThirdPartyNotices.txt project.yml
git commit -m "build: bundle Ghostty runtime resources"
```

### Task 3: Подписанная Release-сборка и DMG

**Files:**
- Create: `scripts/build-release.sh`
- Modify: `Makefile`

**Step 1: Добавить проверки параметров**

`build-release.sh` требует непустые `DEVELOPMENT_TEAM` и `CODE_SIGN_IDENTITY`. Скрипт не принимает Apple ID, пароль или private key. Перед изменением он проверяет, что output находится строго под `.build/Release`.

**Step 2: Реализовать archive**

Скрипт запускает pinned Ghostty build, XcodeGen и:

```bash
xcodebuild archive \
  -project GhostTerm.xcodeproj \
  -scheme GhostTerm \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath .build/Release/GhostTerm.xcarchive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
```

Удаляются или перезаписываются только прежние generated outputs в `.build/Release`.

**Step 3: Проверить app до упаковки**

Скрипт обязан остановиться, если неверны версия, build number, arm64 architecture, resource sentinels, signature или hardened runtime.

**Step 4: Создать и подписать DMG**

Создать staging directory с `GhostTerm.app` и symlink `Applications`, затем compressed DMG:

```text
.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg
```

Подписать DMG тем же `Developer ID Application` с secure timestamp и проверить `codesign --verify`.

**Step 5: Добавить Make target**

Добавить `make release`, передающий только team и identity.

**Step 6: Выполнить реальную сборку**

```bash
make release \
  DEVELOPMENT_TEAM=N8FS9YUZQA \
  CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
```

Ожидание: archive и signed DMG созданы; app signature valid; hardened runtime включён.

**Step 7: Commit**

```bash
git add scripts/build-release.sh Makefile
git commit -m "build: create signed alpha DMG"
```

### Task 4: Notarization и документация выпуска

**Files:**
- Create: `scripts/notarize-dmg.sh`
- Modify: `Makefile`
- Modify: `README.md`

**Step 1: Реализовать notarization script**

Скрипт принимает DMG path и Keychain profile, проверяет DMG signature, затем выполняет:

```bash
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --verbose "$DMG"
```

При ответе Apple, отличном от `Accepted`, script завершается ошибкой и печатает submission ID для `notarytool log`, не читая credentials.

**Step 2: Добавить Make target**

Добавить `make notarize` и `make signed-alpha`, где второй последовательно вызывает release и notarization. Значение profile по умолчанию — `ghostterm-notary`; секретов в Makefile нет.

**Step 3: Обновить README**

Описать:

- alpha version и требования macOS 15+/Apple Silicon;
- создание Developer ID certificate и Keychain profile;
- точную команду выпуска;
- расположение archive/DMG;
- проверки signature, ticket и Gatekeeper;
- отсутствие credentials в repo.

**Step 4: Проверить shell syntax**

```bash
sh -n scripts/build-release.sh
sh -n scripts/notarize-dmg.sh
sh -n scripts/copy-ghostty-resources.sh
```

Ожидание: PASS.

**Step 5: Commit**

```bash
git add scripts/notarize-dmg.sh Makefile README.md
git commit -m "build: notarize signed alpha releases"
```

### Task 5: Финальная проверка и выпуск

**Files:**
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/2026-07-20-signed-alpha.md`

**Step 1: Автоматические проверки**

```bash
make lint
make test
make release DEVELOPMENT_TEAM=N8FS9YUZQA \
  CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
```

Если известный flaky test падает, повторить только его для классификации; реальные failures исправить до выпуска.

**Step 2: Отправить DMG Apple**

```bash
make notarize \
  DMG=.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg \
  NOTARY_PROFILE=ghostterm-notary
```

Ожидание: Apple status `Accepted`, stapler validation PASS, Gatekeeper assessment PASS.

**Step 3: Проверить готовый artifact**

Проверить SHA-256 и вывести:

```text
DMG path
file size
SHA-256
Developer ID identity
notarization submission ID
```

**Step 4: Manual smoke test с разрешения пользователя**

Смонтировать DMG, скопировать app в отдельный временный Applications directory или `/Applications` по выбору пользователя и проверить первый запуск, shell, tabs, split, Quake и restart restore. Не заменять запущенную Debug-сборку без явного разрешения.

**Step 5: Review**

Отдельный reviewer проверяет release scripts, path safety, отсутствие credentials, bundle resources, signature/notarization evidence и соответствие design doc. Исправить все Critical/Important findings.

**Step 6: Записать результат**

Обновить project memory и handoff на русском языке. Не выполнять push и не публиковать DMG автоматически.
