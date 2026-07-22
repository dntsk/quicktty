# QuickTTY Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Полностью переименовать актуальный продукт GhostTerm в QuickTTY с чистыми пользовательскими данными, новой иконкой и release identity `0.1.0-alpha.2`, не меняя runtime-поведение и не затрагивая Ghostty.

**Architecture:** Переименование разделено на Xcode/module identity, пользовательскую identity/config/state, release tooling, визуальный asset и документацию. Ghostty integration остаётся за прежней границей и сохраняет все `Ghostty*` имена. Старые GhostTerm plans, handoffs и подписанный alpha.1 считаются историей и не переписываются.

**Tech Stack:** Swift 6, AppKit, XcodeGen, Swift Testing, POSIX shell release contracts, first-party Swift/AppKit icon generator.

---

## Общие ограничения

- Работать в `/Users/silver/Projects/DNTSK/quicktty-rename` на ветке `rename/quicktty`.
- Не запускать, не устанавливать и не закрывать приложение.
- Не выполнять signing, notarization, release и push.
- Не читать Keychain credentials или `.env`.
- Не менять `Vendor/ghostty`, pin Ghostty и типы `Ghostty*`.
- Не переносить и не удалять `~/.config/ghostterm`, `~/Library/Application Support/GhostTerm` или старый DMG.
- Комментарии в коде писать только на английском и только если объясняется неочевидное «почему».

### Task 1: Rename Xcode project, modules and source trees

**Files:**
- Rename: `GhostTerm/` → `QuickTTY/`
- Rename: `GhostTermTests/` → `QuickTTYTests/`
- Rename: `QuickTTY/GhostTermApplication.swift` → `QuickTTY/QuickTTYApplication.swift`
- Rename: `QuickTTY/Config/GhostTermConfig.swift` → `QuickTTY/Config/QuickTTYConfig.swift`
- Modify: `project.yml`
- Modify: `Makefile`
- Modify: `.gitignore`
- Modify: `.agents/scripts/style-audit.sh`
- Modify: `scripts/check-runtime-callbacks.sh`
- Modify: `scripts/copy-ghostty-resources.sh`
- Modify: `scripts/tests/copy-ghostty-resources-test.sh`
- Modify: all files under `QuickTTYTests/` containing `@testable import GhostTerm`

**Step 1: Switch the resource-copy contract to the new app layout**

Update `scripts/tests/copy-ghostty-resources-test.sh` fixtures from `GhostTerm.app` to `QuickTTY.app`, including DerivedData/archive paths and temporary prefixes. Keep every path-containment, symlink and signal rollback assertion.

**Step 2: Run the focused contract and verify it fails**

Run:

```bash
./scripts/tests/copy-ghostty-resources-test.sh
```

Expected: FAIL because production `scripts/copy-ghostty-resources.sh` still accepts only `GhostTerm.app/Contents/Resources`.

**Step 3: Rename tracked source trees and first-party Swift entry/config files**

Run:

```bash
git mv GhostTerm QuickTTY
git mv GhostTermTests QuickTTYTests
git mv QuickTTY/GhostTermApplication.swift QuickTTY/QuickTTYApplication.swift
git mv QuickTTY/Config/GhostTermConfig.swift QuickTTY/Config/QuickTTYConfig.swift
```

Rename declarations and references:

```swift
enum QuickTTYApplication { ... }
struct QuickTTYConfig: Equatable, Sendable { ... }
```

Replace every first-party/test `@testable import GhostTerm` with `@testable import QuickTTY`. Do not rename `GhosttyBridge`, `GhosttySurface*`, `GhosttyConfiguration`, `GhosttyKit` or the `ghostty` resource directory.

**Step 4: Rename XcodeGen and local build identities**

In `project.yml`, define:

```yaml
name: QuickTTY
targets:
  QuickTTY:
    sources:
      - path: QuickTTY
      - path: QuickTTY/Resources
    settings:
      base:
        CURRENT_PROJECT_VERSION: 2
        INFOPLIST_KEY_CFBundleDisplayName: QuickTTY
        MARKETING_VERSION: 0.1.0
        PRODUCT_BUNDLE_IDENTIFIER: com.dntsk.QuickTTY
        PRODUCT_NAME: QuickTTY
  QuickTTYTests:
    sources:
      - path: QuickTTYTests
    dependencies:
      - target: QuickTTY
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.dntsk.QuickTTYTests
        PRODUCT_NAME: QuickTTYTests
schemes:
  QuickTTY: ...
```

Update the post-build expected path to `QuickTTY.app/Contents/Resources`.

In `Makefile` use:

```make
PROJECT := QuickTTY.xcodeproj
SCHEME := QuickTTY
SWIFT_SOURCES := QuickTTY QuickTTYTests
```

Update `.gitignore`, callback contract paths and style-audit directories/messages. Update production resource-copy path guards to `QuickTTY.app/Contents/Resources`. Rename test-only temporary prefixes and signal failpoint environment variables from `GHOSTTERM_*` to `QUICKTTY_*` when they belong to our scripts.

**Step 5: Regenerate and verify module/build contracts**

Run:

```bash
make generate
./scripts/tests/copy-ghostty-resources-test.sh
./scripts/check-runtime-callbacks.sh
make build
```

Expected: `QuickTTY.xcodeproj`, scheme `QuickTTY`, app `QuickTTY.app`; all commands PASS. `GhostTerm.xcodeproj` must not be regenerated.

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename app modules to QuickTTY"
```

### Task 2: Apply QuickTTY user identity with a clean start

**Files:**
- Modify: `QuickTTY/Config/QuickTTYConfig.swift`
- Modify: `QuickTTY/Config/ConfigDocument.swift`
- Modify: `QuickTTY/Config/ConfigController.swift`
- Modify: `QuickTTY/Persistence/StateStore.swift`
- Modify: `QuickTTY/AppDelegate.swift`
- Modify: `QuickTTY/WindowController.swift`
- Modify: `QuickTTY/Presentation/NormalWindowController.swift`
- Modify: `QuickTTY/Presentation/QuakeWindow.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabBarViewController.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyClipboard.swift`
- Modify: `QuickTTY/Resources/default-config`
- Modify: `QuickTTY/Resources/configuration-reference.md`
- Test: `QuickTTYTests/Config/ConfigDocumentTests.swift`
- Test: `QuickTTYTests/Config/ConfigControllerTests.swift`
- Test: `QuickTTYTests/Persistence/StateStoreTests.swift`
- Test: `QuickTTYTests/AppDelegateLifecycleTests.swift`
- Test: `QuickTTYTests/Integration/GhosttyClipboardTests.swift`
- Test: presentation tests asserting titles, diagnostics or pasteboard types

**Step 1: Write failing identity and clean-path tests**

Add assertions for all eight canonical `QuickTTYConfig.Key` values:

```text
quicktty-presentation-mode
quicktty-global-toggle
quicktty-quake-height
quicktty-quake-animation-duration
quicktty-quake-padding
quicktty-hide-on-focus-loss
quicktty-restore-workspaces
quicktty-config-editor
```

Add tests that production-path helpers resolve only:

```text
~/.config/quicktty/config
~/.config/quicktty/.ghostty-effective-config
~/Library/Application Support/QuickTTY/state.json
```

The tests must assert no returned path contains `/ghostterm/` or `/GhostTerm/`. Add exact tests for `QuickTTY` menu/window/error/accessibility strings and identifiers:

```text
com.dntsk.QuickTTY.selection
com.dntsk.QuickTTY.tab
```

Do not add legacy fallback or migration fixtures.

**Step 2: Run focused tests and verify failure**

Run the actual Xcode selectors for Config, StateStore, lifecycle, presentation and clipboard suites. Expected: FAIL on old keys, paths, strings and identifiers; confirm tests are selected rather than reporting zero tests.

**Step 3: Implement the minimal product-identity rename**

- Rename own config type and parser naming to `QuickTTYConfig` and QuickTTY terminology.
- Change config prefix from `ghostterm-` to `quicktty-`.
- Make `ConfigController.production` use `.config/quicktty` while retaining `.ghostty-effective-config` because that file belongs to the Ghostty integration.
- Make `StateStore.production` use `Application Support/QuickTTY/state.json`.
- Add narrow internal pure path helpers only if needed to test production paths; do not create a general identity abstraction.
- Update logger subsystem, menu/window titles, startup error, accessibility labels, drag pasteboard and selection pasteboard identifiers.
- Update the starter config and current configuration reference.
- Do not inspect, copy, move or delete old GhostTerm data.

**Step 4: Run focused suites**

Run:

```bash
make test
```

Expected: all tests PASS under module `QuickTTY`; output must show the complete non-zero suite count.

**Step 5: Commit**

```bash
git add QuickTTY QuickTTYTests
git commit -m "refactor: apply QuickTTY product identity"
```

### Task 3: Rename release and notarization tooling for alpha.2

**Files:**
- Modify: `scripts/release-helpers.sh`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/build-ghostty.sh`
- Modify: `scripts/notarize-helpers.sh`
- Modify: `scripts/notarize-dmg.sh`
- Modify: `scripts/tests/build-release-test.sh`
- Modify: `scripts/tests/notarize-dmg-test.sh`
- Modify: `Makefile` only if a release contract still contains an old first-party identifier

**Step 1: Change contract expectations first**

Update shell tests to require:

```text
RELEASE_LABEL_DEFAULT=0.1.0-alpha.2
RELEASE_ARCHIVE_NAME=QuickTTY.xcarchive
RELEASE_DMG_NAME=QuickTTY-0.1.0-alpha.2-arm64.dmg
RELEASE_STAGE_NAME=QuickTTY-0.1.0-alpha.2-stage
PRODUCT_NAME=QuickTTY
BUNDLE_IDENTIFIER=com.dntsk.QuickTTY
BUILD_NUMBER=2
NOTARY_PROFILE_DEFAULT=quicktty-notary
```

Rename first-party/test environment variables to `QUICKTTY_*`, including forced Ghostty rebuild, capture paths, malicious markers and resource-copy failpoints. Keep `GHOSTTY_*` names only where they are actual upstream Ghostty variables.

**Step 2: Run release contracts and verify failure**

Run:

```bash
make release-contract
make notarize-contract
```

Expected: FAIL on old GhostTerm artifact names, project/scheme, bundle identity, profile or first-party environment variables.

**Step 3: Implement tooling rename**

Update release scripts to archive `QuickTTY.xcodeproj` / scheme `QuickTTY`, validate `QuickTTY.app`, produce the alpha.2 QuickTTY archive/stage/DMG, use build `2`, and create only QuickTTY-prefixed temporary notarization files. Preserve all canonical-path checks, cleanup allowlists, JSON validation, signing checks, stapler and Gatekeeper checks.

`quicktty-notary` is only a default label; do not create/read credentials. `NOTARY_PROFILE=ghostterm-notary` may still be supplied explicitly through the process environment if the developer chooses.

The cleanup allowlist must not remove the historical GhostTerm alpha.1 archive, DMG or evidence.

**Step 4: Run contracts and syntax checks**

Run:

```bash
sh -n scripts/*.sh scripts/tests/*.sh
make release-contract
make notarize-contract
```

Expected: PASS. Do not run `make release`, `make notarize` or `make signed-alpha`.

**Step 5: Commit**

```bash
git add Makefile scripts
git commit -m "build: rename alpha pipeline to QuickTTY"
```

### Task 4: Design and approve the new QuickTTY icon

**Files:**
- Modify: `scripts/generate-app-icon.swift`
- Regenerate: `QuickTTY/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Regenerate: `QuickTTY/Assets.xcassets/AppIcon.appiconset/*.png`

**Step 1: Build an untracked preview first**

Change the generator in a subagent worktree or temporary copy so its 1024×1024 master uses:

- graphite macOS superellipse and restrained depth;
- one large light `Q` as the dominant mark;
- compact `TTY` in a cold accent color;
- no retained `G`/`T` split composition from the old icon;
- minimum stroke/gap sizes that survive 16×16 downsampling.

Generate only to `/tmp/quicktty-icon-preview.appiconset` first:

```bash
swift scripts/generate-app-icon.swift /tmp/quicktty-icon-preview.appiconset
```

Expected: ten PNGs and `Contents.json`; tracked appiconset remains unchanged.

**Step 2: Present the preview and wait for user approval**

Show `/tmp/quicktty-icon-preview.appiconset/icon_512x512@2x.png` and a 32×32 rendering. Do not overwrite tracked icons until the user approves the preview.

**Step 3: Generate the approved appiconset**

Run:

```bash
swift scripts/generate-app-icon.swift QuickTTY/Assets.xcassets/AppIcon.appiconset
```

Verify `sips -g pixelWidth -g pixelHeight` for all declared sizes and inspect the 16×16/32×32 outputs for legibility.

**Step 4: Build asset catalog integration**

Run:

```bash
make build
```

Expected: PASS without missing/duplicate AppIcon warnings.

**Step 5: Commit**

```bash
git add scripts/generate-app-icon.swift QuickTTY/Assets.xcassets/AppIcon.appiconset
git commit -m "design: add QuickTTY application icon"
```

### Task 5: Update current documentation and living project memory

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `.agents/rules/project-profile.md`
- Modify: `.agents/rules/architecture.md`
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/integration-contracts.md` only for current first-party paths/names
- Modify: `.agents/memory/tasks-completed.md`
- Modify: `docs/backlog.md`
- Modify: `THIRD_PARTY_NOTICES.md`
- Preserve: existing `docs/plans/2026-07-14-*`, `docs/plans/2026-07-20-signed-alpha*`, old handoffs and old completed-task details

**Step 1: Update current product docs**

Describe QuickTTY, repository naming, current config/state paths, bundle identity, alpha.2 artifact and `quicktty-notary` setup. Keep Ghostty capitalization and attribution exact.

AGENTS and current rules should identify QuickTTY while linking both the original product design and `docs/plans/2026-07-22-quicktty-rename-design.md` as the rename override.

**Step 2: Record the naming decision**

Add a dated ADR/living-memory entry documenting:

- GhostTerm rejected because exact terminal products already exist;
- GhostTTY rejected because an exact product exists and it is confusable with Ghostty;
- QuickTTY selected;
- clean start intentionally chosen;
- historical GhostTerm artifacts/docs remain immutable.

Add a top completed-task row only after implementation and verification are complete.

**Step 3: Audit historical preservation**

Ensure old handoffs still name the exact signed artifact `GhostTerm-0.1.0-alpha.1-arm64.dmg`, submission ID and SHA-256. Do not rewrite historical command output or paths.

**Step 4: Commit**

```bash
git add README.md AGENTS.md .agents/rules .agents/memory docs/backlog.md THIRD_PARTY_NOTICES.md
git commit -m "docs: adopt QuickTTY project identity"
```

### Task 6: Full rename audit and validation

**Files:**
- Modify only files required by findings from the audit
- Create at session end: `.agents/memory/handoffs/2026-07-22-<time>-quicktty-rename.md`

**Step 1: Audit old identifiers**

Run tracked-file searches excluding `Vendor/ghostty`, old plans, old handoffs and historical completed entries. In current production/tooling, these must be absent:

```text
GhostTerm
GhostTermTests
com.dntsk.GhostTerm
ghostterm-
.config/ghostterm
GHOSTTERM_
GhostTerm.app
GhostTerm.xcodeproj
```

Review every remaining match manually. Do not blindly replace `Ghostty` or historical evidence.

**Step 2: Run formatting and complete checks**

Run:

```bash
make format
make check
git diff --check
```

Expected: all contracts, Debug build and the complete non-zero test suite PASS.

**Step 3: Validate built app metadata without launching it**

Inspect `.build/DerivedData/Build/Products/Debug/QuickTTY.app/Contents/Info.plist` and executable layout. Expected:

```text
CFBundleDisplayName = QuickTTY
CFBundleName = QuickTTY
CFBundleIdentifier = com.dntsk.QuickTTY
CFBundleShortVersionString = 0.1.0
CFBundleVersion = 2
Contents/MacOS/QuickTTY
```

Verify the bundled Ghostty runtime resources and `ThirdPartyNotices.txt` are still present. Do not use `open`, install the app or terminate the installed GhostTerm alpha.

**Step 4: Run an unsigned Release compilation**

Use `xcodebuild` with Release configuration and `CODE_SIGNING_ALLOWED=NO` against `QuickTTY.xcodeproj`/`QuickTTY` into a separate DerivedData path. Expected: compilation PASS. Do not create a distributable DMG and do not invoke signing/notarization.

**Step 5: Review**

Dispatch a code-reviewer for the complete branch. Critical review points:

- no accidental Ghostty rename;
- no legacy GhostTerm data access or deletion;
- no cleanup path capable of removing old alpha.1 artifacts;
- complete QuickTTY module/bundle/config/state/release identity;
- historical evidence preserved;
- icon legible and approved;
- all tests genuinely selected.

Fix Critical/Important findings and rerun affected gates plus `make check`.

**Step 6: Record handoff and final commit**

Write a Russian handoff with commits, tests, unresolved items, remote status and explicit statement that no push/release/signing/notarization/app launch occurred.

```bash
git add -A
git commit -m "chore: complete QuickTTY rename"
git status --short --branch
```

Expected: clean branch `rename/quicktty`. Do not push.
