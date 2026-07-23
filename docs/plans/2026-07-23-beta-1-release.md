# QuickTTY 0.1.0-beta.1 Release Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task.

**Goal:** Выпустить текущий `master` как подписанный и нотариально заверенный GitHub prerelease `v0.1.0-beta.1` для macOS 15+ на Apple Silicon.

**Architecture:** Существующий release pipeline остаётся источником сборки, подписи, DMG и notarization evidence. Изменяются только release label/build metadata, актуальная документация и contract tests; исторические планы и данные предыдущих выпусков не переписываются.

**Tech Stack:** Swift 6, AppKit, XcodeGen, POSIX shell, Xcode, Developer ID, `notarytool`, GitHub CLI.

---

### Task 1: Обновить release metadata

**Files:**
- Modify: `project.yml`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/release-helpers.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `scripts/tests/build-release-test.sh`
- Modify: `scripts/tests/notarize-dmg-test.sh`

**Steps:**
1. Зафиксировать `CURRENT_PROJECT_VERSION = 3` и `BUILD_NUMBER=3`.
2. Зафиксировать label `0.1.0-beta.1` и артефакт `QuickTTY-0.1.0-beta.1-arm64.dmg`.
3. Добавить нейтральный target `make signed-release`, сохранив `signed-alpha` как совместимый alias.
4. Обновить только актуальный release-раздел README; исторические документы не менять.
5. Обновить contract tests на beta label/build и оба Make target.

### Task 2: Проверить release preparation

**Steps:**
1. Запустить `make release-contract` и `make notarize-contract`.
2. Провести integrated review release diff.
3. Закоммитить release preparation и отправить `master` в `origin`.
4. Запустить `.agents/scripts/pre-deploy-check.sh`; ожидается чистое дерево, совпадение с upstream и полный `make check` без ошибок.

### Task 3: Собрать и нотариально заверить DMG

**Steps:**
1. Выполнить `make release` с Team ID `N8FS9YUZQA` и Developer ID Application identity через process environment.
2. Проверить archive, arm64-only binary, hardened runtime, подпись приложения и DMG.
3. Выполнить `make notarize` с Keychain profile `ghostterm-notary`.
4. Сохранить submission ID, размер и финальный SHA-256 после stapler/Gatekeeper.
5. Не устанавливать и не запускать приложение.

### Task 4: Опубликовать GitHub prerelease

**Steps:**
1. Подготовить release notes по изменениям после `v0.1.0-alpha.2`.
2. Создать lightweight tag `v0.1.0-beta.1` на проверенном release commit и отправить tag в `origin`.
3. Создать GitHub prerelease и загрузить единственный нотариально заверенный DMG.
4. Проверить публичный URL, имя asset, размер и SHA-256.

### Task 5: Записать evidence

**Files:**
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/2026-07-23-<time>-beta-1-release.md`

**Steps:**
1. Записать tag/commit, release URL, submission ID, размер, SHA-256 и результаты gate.
2. Закоммитить и отправить release evidence в `master` без перемещения release tag.
