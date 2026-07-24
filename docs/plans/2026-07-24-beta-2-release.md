# QuickTTY 0.1.0-beta.2 Signed Release Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task.

**Goal:** Publish QuickTTY `0.1.0-beta.2` build `4` as an arm64 Developer ID-signed, Apple-notarized, stapled GitHub prerelease.

**Architecture:** Reuse the existing guarded release/notarization pipeline. Update only current release metadata, contracts, and documentation; commit and push the preparation; run the clean-tree upstream gate; then build, sign, notarize, staple, verify, tag, and publish the exact fixed-name artifact. Historical beta.1 evidence and tag remain immutable.

**Tech Stack:** Swift 6, AppKit, XcodeGen, POSIX shell, Xcode archive, Developer ID Application, `notarytool`, `stapler`, Gatekeeper.

---

### Task 1: Pin beta.2 metadata with contract-first tests

**Files:**
- Modify: `scripts/tests/build-release-test.sh`
- Modify: `scripts/tests/notarize-dmg-test.sh`
- Modify: `project.yml`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/release-helpers.sh`

**Step 1: Update contract expectations first**

Set exact expected values:

```text
CURRENT_PROJECT_VERSION: 4
BUILD_NUMBER=4
RELEASE_LABEL_DEFAULT=0.1.0-beta.2
RELEASE_DMG_NAME=QuickTTY-0.1.0-beta.2-arm64.dmg
RELEASE_STAGE_NAME=QuickTTY-0.1.0-beta.2-stage
```

Keep marketing version `0.1.0`, bundle ID, product name, arm64-only policy, hardened runtime, cleanup allowlist, secret rejection, and signing/notarization behavior unchanged.

**Step 2: Run contracts and verify RED**

```sh
make release-contract
make notarize-contract
```

Expected: failures only because production metadata still identifies beta.1/build 3.

**Step 3: Update production metadata**

Apply the exact values from Step 1. Do not make `RELEASE_LABEL` arbitrary and do not rename the shared `QuickTTY.xcarchive`.

**Step 4: Run contracts and verify PASS**

```sh
make release-contract
make notarize-contract
```

Expected: PASS.

### Task 2: Update current release documentation

**Files:**
- Modify: `README.md`

Update only the current release section to beta.2/build 4, including the DMG path and notary evidence path. Preserve historical beta.1 plan, evidence, tag, release URL, checksums, and artifacts unchanged.

Run:

```sh
make lint
git diff --check
```

Expected: PASS.

### Task 3: Review and commit release preparation

1. Run an integrated spec/code-quality review of the complete preparation diff.
2. Verify no `Vendor/ghostty`, `.env`, user config, signing identity, credentials, keychain material, or generated artifacts entered the diff.
3. Run `make check` before commit.
4. Commit with a release-preparation message and push `master` to `origin` as explicitly authorized by the user.
5. Verify clean tree and exact `HEAD == origin/master`.

### Task 4: Run the clean pre-deploy gate

Run:

```sh
.agents/scripts/pre-deploy-check.sh
```

Expected: clean tree, exact upstream match, all contracts/build/tests PASS.

### Task 5: Build, sign, notarize, and staple beta.2

Use the established Team ID and Developer ID Application identity through the process environment. Use the previously verified `ghostterm-notary` Keychain profile; do not read or print credentials.

Before execution, state the guarded cleanup scope: the pipeline may replace only `.build/Release/QuickTTY.xcarchive`, the beta.2 DMG/notary-result/stage paths, and generated Ghostty runtime resource directories. Historical beta.1 DMG/evidence and unrelated files must remain untouched.

Run `make signed-release`. This performs:

1. forced clean rebuild of generated Ghostty runtime resources without changing the pin/source;
2. arm64 Release archive with hardened runtime and secure timestamp;
3. strict app and DMG signature validation;
4. fixed-name compressed DMG creation;
5. Apple notary submission and wait;
6. ticket stapling and validation;
7. Gatekeeper assessment;
8. final size, SHA-256, submission ID, and JSON evidence output.

Do not install or launch the artifact.

### Task 6: Verify and publish the prerelease

1. Verify the Release app metadata: `CFBundleShortVersionString=0.1.0`, `CFBundleVersion=4`, bundle ID `com.dntsk.QuickTTY`, macOS 15+, arm64-only, hardened runtime.
2. Verify bundled `AgentIntegrations` examples and executable `quicktty-progress` in the archived app.
3. Re-run strict codesign, stapler validation, Gatekeeper assessment, file size, and SHA-256 on the final DMG.
4. Create lightweight tag `v0.1.0-beta.2` on the verified preparation commit and push only that tag.
5. Create a GitHub prerelease with release notes and exactly one DMG asset.
6. Verify the public release URL, tag target, asset name/size/digest, and an anonymous re-download checksum.
7. Confirm historical beta.1 tag, artifact, release, and evidence paths were not overwritten.

### Task 7: Record evidence

Record the commit/tag, GitHub URL, notarization submission ID, size, SHA-256 and gates in `.agents/memory/tasks-completed.md` and a new Russian handoff. Commit/push evidence only with explicit permission.
