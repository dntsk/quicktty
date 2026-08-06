# Repository Presentation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Create a polished English GitHub landing page, complete community health files, an MIT license, and accurate repository metadata for QuickTTY.

**Architecture:** Reuse the existing website icon, screenshots, product language, and canonical URLs so the repository and website remain consistent. Keep contributor-facing policy in root and `.github` files, while preserving detailed release operations in `docs/releasing.md`.

**Tech Stack:** Markdown, GitHub issue-form YAML, GitHub CLI, existing static website assets.

---

### Task 1: Rebuild the product-first README

**Files:**
- Modify: `README.md`
- Modify: `scripts/tests/promote-beta-appcast-test.sh`
- Reference: `site/index.html`
- Reference: `site/assets/app-icon.png`
- Reference: `site/assets/screenshots/workspace.png`

**Step 1:** Replace the internal runbook-style README with the approved English product-first structure.

**Step 2:** Include canonical links for the website, documentation, latest download, releases, contributing guide, security policy, release runbook, and third-party notices.

**Step 3:** Keep source setup concise and accurate: macOS 15+, Apple Silicon, Xcode, XcodeGen, Swift Format, Zig 0.15.2, recursive submodules, and the existing Make targets.

**Step 4:** Preserve the beta-feed contract in an English maintainer note and update its shell test so only the English README uses `superset of stable`; keep the existing Russian internal-policy assertions unchanged.

**Step 5:** Verify every relative image and document link exists.

Run: a local Python link check over `README.md`.
Expected: every repository-relative target exists.

### Task 2: Add license and community policies

**Files:**
- Create: `LICENSE`
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `SECURITY.md`
- Modify: `THIRD_PARTY_NOTICES.md`

**Step 1:** Add the standard MIT license with `Copyright (c) 2026 Dmitrii Lialiuev`.

**Step 2:** Document supported development setup, focused contribution scope, validation commands, and pull-request expectations.

**Step 3:** Add concise participation standards and transparent enforcement through public GitHub issues.

**Step 4:** State that no private vulnerability channel exists and prohibit sensitive details, credentials, personal data, or working exploit instructions in public reports.

**Step 5:** Translate the linked third-party notice to English without changing the pinned revision, source inventory, or upstream MIT license text. Replace the obsolete statement that QuickTTY has no first-party license with a link to `LICENSE`.

**Step 6:** Search the public files for non-English text.

Run: `rg -n '[\x{0400}-\x{04FF}]' LICENSE CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md THIRD_PARTY_NOTICES.md`.
Expected: no matches.

### Task 3: Add GitHub contribution templates

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/pull_request_template.md`

**Step 1:** Add a structured bug form with version, macOS version, reproduction, expected behavior, actual behavior, config, and logs.

**Step 2:** Add a feature form centered on the user problem, use case, proposed behavior, and alternatives.

**Step 3:** Disable blank issues and add links to QuickTTY documentation, downloads, and the security policy.

**Step 4:** Add a focused pull-request checklist for scope, tests, docs, generated files, and secrets.

**Step 5:** Parse every YAML template locally.

Run: `ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path); puts "OK #{path}" }' .github/ISSUE_TEMPLATE/*.yml`.
Expected: every file prints `OK` without parser errors.

### Task 4: Configure GitHub repository metadata

**Files:**
- No repository files changed.

**Step 1:** Set the description to `Native terminal workspace for macOS with tabs, splits, Quake mode, and coding-agent progress.`

**Step 2:** Set the homepage to `https://quicktty.app` and keep Issues enabled.

**Step 3:** Set focused topics: `macos`, `terminal`, `terminal-emulator`, `swift`, `appkit`, `ghostty`, `developer-tools`, and `apple-silicon`.

**Step 4:** Verify the resulting public metadata with `gh repo view`.

Expected: description, homepage, topics, Issues, and MIT license are reported correctly after GitHub indexes the new license.

### Task 5: Run final validation and update project memory

**Files:**
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/2026-08-06-repository-presentation.md`

**Step 1:** Run link, YAML, and English-language checks.

**Step 2:** Run the repository's relevant documentation checks and inspect `git diff --check`.

**Step 3:** Review `git diff` for accidental product, release, secret, or generated-file changes.

**Step 4:** Record the completed repository-presentation work in project memory and leave a Russian-language handoff.

**Step 5:** Do not commit; present the working-tree changes and validation results to the user.
