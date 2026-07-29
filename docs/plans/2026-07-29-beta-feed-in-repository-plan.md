# Beta Feed in Repository Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Восстановить обновления существующих beta-клиентов и перевести все будущие beta-релизы на versioned appcast в репозитории без изменения published GitHub Release assets.

**Architecture:** Beta-сборки читают постоянный raw GitHub URL `docs/appcasts/beta.xml` из ветки `master`. XML всегда содержит enclosure на immutable DMG конкретного `v<version>` release. После каждого опубликованного beta release отдельная локальная команда копирует exact final appcast в tracked file атомарно; следующий commit публикует beta feed. Один immutable bootstrap GitHub Release c tag `beta` нужен только старым версиям, которые жёстко запрашивают legacy URL `/releases/download/beta/appcast.xml`.

**Tech Stack:** Swift 6, AppKit, Sparkle 2, POSIX shell, GitHub Releases, raw.githubusercontent.com, XcodeGen.

---

### Task 1: Зафиксировать beta feed как application contract

**Files:**
- Modify: `QuickTTY/AppDelegate.swift:103-110`
- Modify: `QuickTTYTests/AppDelegateLifecycleTests.swift`
- Modify: `QuickTTY/Resources/configuration-reference.md`

**Step 1: Write the failing test**

Добавить в `AppDelegateLifecycleTests` проверку internal static URL:

```swift
@Test
func betaUpdateFeedUsesTrackedRepositoryAppcast() {
    #expect(
        AppDelegate.betaFeedURL.absoluteString
            == "https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml"
    )
}
```

**Step 2: Run the focused test and verify it fails**

Run:

```sh
make test
```

Expected: compile failure because `AppDelegate.betaFeedURL` is not declared.

**Step 3: Write the minimal implementation**

Expose only internal static URL constants used at startup; do not change the public `UpdateManager` API:

```swift
static let stableFeedURL = URL(
    string: "https://github.com/dntsk/quicktty/releases/latest/download/appcast.xml"
)!
static let betaFeedURL = URL(
    string: "https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml"
)!
```

Pass these constants to `UpdateManager` in `applicationDidFinishLaunching`. Remove the legacy `/releases/download/beta/appcast.xml` construction.

Document `quicktty-update-channel = beta`: it selects the tracked beta feed and never the stable `latest` feed.

**Step 4: Run the focused test and verify it passes**

Run:

```sh
make test
```

Expected: PASS.

**Step 5: Commit**

```sh
git add QuickTTY/AppDelegate.swift QuickTTYTests/AppDelegateLifecycleTests.swift QuickTTY/Resources/configuration-reference.md
git commit -m "fix: route beta updates through repository appcast"
```

### Task 2: Add the tracked beta appcast and safe promotion command

**Files:**
- Create: `docs/appcasts/beta.xml`
- Create: `docs/appcasts/README.md`
- Create: `scripts/promote-beta-appcast.sh`
- Modify: `scripts/release-helpers.sh`
- Modify: `Makefile`
- Modify: `scripts/tests/build-release-test.sh`
- Create: `scripts/tests/promote-beta-appcast-test.sh`

**Step 1: Write failing contract tests**

Add a fixture final DMG and matching appcast. Test a new helper that:

- rejects a source appcast or DMG that fails `release_verify_appcast`;
- rejects a symlink target;
- replaces only a regular `docs/appcasts/beta.xml` through a temporary file in its parent directory;
- leaves no temporary file on success or failure;
- does not execute `git`, `gh`, signing, notarization, or network calls.

Add a shell contract for `scripts/promote-beta-appcast.sh` that checks its trusted `PATH`, zero-argument interface, clean-source-tree precondition, and `make beta-feed` target.

**Step 2: Run the contract tests and verify they fail**

Run:

```sh
make release-contract
sh scripts/tests/promote-beta-appcast-test.sh
```

Expected: FAIL because the helper, script, and Make target do not exist.

**Step 3: Implement promotion**

In `scripts/release-helpers.sh`, add constants:

```sh
RELEASE_BETA_APPCAST_RELATIVE_PATH=docs/appcasts/beta.xml
RELEASE_BETA_APPCAST_RAW_URL=https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml
```

Add a helper that calls `release_verify_appcast` against `.build/Release/$RELEASE_DMG_NAME`, verifies the tracked target is a non-symlink regular file, copies through an adjacent `mktemp` file, and atomically moves it into place.

`scripts/promote-beta-appcast.sh` must:

1. resolve the canonical repository root and trusted tools;
2. reject arguments, secrets, dirty source tree, missing/unsafe release output, and unsafe tracked target;
3. promote only `.build/Release/appcast/appcast.xml` into `docs/appcasts/beta.xml`;
4. print the changed path and exact enclosure after success;
5. never stage, commit, push, tag, sign, notarize, or publish.

Add `beta-feed` and `beta-feed-contract` Make targets. Include `beta-feed-contract` in `lint` so a future agent cannot silently remove the promotion guard.

Seed `docs/appcasts/beta.xml` from the public final `v0.1.2.beta-1` appcast. It must retain its absolute enclosure URL and exact final length; no hand-written XML.

`docs/appcasts/README.md` must state that `beta.xml` is generated final-release data, must not be edited by hand, and is promoted only with `make beta-feed` after public release verification.

**Step 4: Run contracts and verify they pass**

Run:

```sh
make release-contract beta-feed-contract
make lint
```

Expected: PASS; no build, signing, notarization, GitHub, or network side effect.

**Step 5: Commit**

```sh
git add docs/appcasts scripts/promote-beta-appcast.sh scripts/release-helpers.sh Makefile scripts/tests
git commit -m "build: promote beta appcast from final release artifact"
```

### Task 3: Make the beta promotion non-optional in release documentation

**Files:**
- Modify: `docs/releasing.md`
- Modify: `AGENTS.md`
- Modify: `.agents/rules/project-profile.md`
- Modify: `README.md`

**Step 1: Write documentation acceptance checks**

Extend the beta-feed contract test to require the raw beta URL, `make beta-feed`, the post-publication ordering, public raw feed verification, and the prohibition on hand-editing `docs/appcasts/beta.xml` in `docs/releasing.md`.

**Step 2: Run the contract and verify it fails**

Run:

```sh
make beta-feed-contract
```

Expected: FAIL because the runbook does not define this procedure.

**Step 3: Document the exact release procedure**

Add a dedicated beta section to `docs/releasing.md`:

1. A normal beta application release still contains exactly two assets: final DMG and final appcast.
2. Publish and anonymously verify that normal prerelease before changing the tracked beta feed.
3. Run `make beta-feed` with a clean source tree.
4. Inspect `git diff -- docs/appcasts/beta.xml`; commit and push the exact generated file in a separate post-release commit.
5. Anonymous `curl` to `RELEASE_BETA_APPCAST_RAW_URL` must match the local final appcast and its enclosure must download the final public DMG.
6. Do not replace or delete published assets, move tags, or hand-edit the XML.

Document the one-time legacy bootstrap exception: the immutable `beta` GitHub Release contains exactly one `appcast.xml` asset that points to `v0.1.2.beta-2`; it is not an application release, must never be changed, and does not become `latest`.

Link this rule from `AGENTS.md`, `.agents/rules/project-profile.md`, and README release documentation.

**Step 4: Run documentation contract**

Run:

```sh
make beta-feed-contract
```

Expected: PASS.

**Step 5: Commit**

```sh
git add docs/releasing.md docs/appcasts/README.md AGENTS.md .agents/rules/project-profile.md README.md scripts/tests/promote-beta-appcast-test.sh
git commit -m "docs: require beta appcast promotion after releases"
```

### Task 4: Prepare `0.1.2.beta-2` as the one-time client migration release

**Files:**
- Modify: `project.yml`
- Modify: `scripts/release-helpers.sh`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/tests/build-release-test.sh`
- Modify: `scripts/tests/notarize-dmg-test.sh`
- Modify: `README.md`
- Create: `docs/releases/0.1.2.beta-2.md`

**Step 1: Update failing metadata contracts**

Change expectations to release label `0.1.2.beta-2`, marketing version `0.1.2`, build `8`, DMG `QuickTTY-0.1.2.beta-2-arm64.dmg`, and direct `v0.1.2.beta-2` enclosure prefix.

**Step 2: Run release contracts and verify they fail**

Run:

```sh
make release-contract notarize-contract
```

Expected: FAIL until every release metadata source is synchronized.

**Step 3: Synchronize metadata and release notes**

Update every current-release source together. English release notes must say that beta updates now use the repository-hosted appcast and that this build migrates legacy beta clients. Do not edit `0.1.2.beta-1` artifacts, tag, notes, or evidence.

**Step 4: Run release contracts and full gate**

Run:

```sh
make release-contract notarize-contract
.agents/scripts/pre-deploy-check.sh
```

Expected: all PASS. Do not run a separate `make check` around the pre-deploy gate.

**Step 5: Create and push the release commit**

Only with explicit release authorization:

```sh
git add project.yml scripts README.md docs/releases/0.1.2.beta-2.md docs/appcasts/beta.xml
git commit -m "release: 0.1.2.beta-2"
git push origin master
```

### Task 5: Publish `0.1.2.beta-2`, promote the tracked feed, and bootstrap legacy clients

**Files:**
- Modify after publication only: `docs/appcasts/beta.xml`
- Create after publication: `.agents/memory/handoffs/YYYY-MM-DD-HHMM-0.1.2-beta-2-release.md`
- Modify after publication: `.agents/memory/tasks-completed.md`

**Step 1: Build, sign, notarize, and generate final appcast**

Follow `docs/releasing.md` exactly. Use the `QuickTTY` Keychain profile and retain final size, SHA-256, submission ID, and appcast before publication. Do not create a tag if Apple does not report `Accepted`.

Before publish, resolve the Sparkle Ed25519 warning: configure a persistent private signing key in Keychain and add only the matching public key to the app configuration. The final appcast must contain a valid `sparkle:edSignature`. Never commit or print the private key.

**Step 2: Publish the normal application prerelease**

Create and verify an annotated `v0.1.2.beta-2` tag, then create a GitHub draft with exactly the final DMG and appcast. Verify draft asset names, size, SHA-256, appcast enclosure, and English notes. Publish with `--prerelease --latest=false`.

**Step 3: Verify public normal release**

Without GitHub credentials, download the direct beta.2 appcast and DMG. Compare appcast bytes, DMG size, SHA-256, and direct enclosure URL with the local final files. Confirm stable `latest` did not change.

**Step 4: Promote the repository beta feed**

From a clean tree after the normal prerelease public verification:

```sh
make beta-feed
git diff --check
git diff -- docs/appcasts/beta.xml
git add docs/appcasts/beta.xml
git commit -m "docs: promote 0.1.2.beta-2 beta appcast"
git push origin master
```

Then anonymously download `RELEASE_BETA_APPCAST_RAW_URL` and compare it byte-for-byte with `.build/Release/appcast/appcast.xml`; download its enclosure and compare size/SHA-256 with the local final DMG.

**Step 5: Create the immutable legacy bootstrap once**

Create annotated tag `beta` on the exact `v0.1.2.beta-2` release commit and push it. Create a separate GitHub **draft prerelease** for tag `beta` with exactly one asset, the same final `appcast.xml`; title and notes are English. Verify that its enclosure targets the immutable `v0.1.2.beta-2` DMG, then publish with `--prerelease --latest=false`.

Anonymous verification must prove that `https://github.com/dntsk/quicktty/releases/download/beta/appcast.xml` and the raw repository beta URL have identical appcast bytes. Never upload, replace, delete, or alter this bootstrap release, tag, or asset.

**Step 6: Smoke test and evidence**

In a previous beta build configured with `quicktty-update-channel = beta`, run **Check for Updates…**. It must discover build 8, validate the signed appcast, download, install, and relaunch without error. Record all release and bootstrap URLs, checksums, signing verification, gate results, and the smoke-test outcome in project memory and a new Russian handoff. Commit and push only the evidence changes; do not touch either published tag or assets.
