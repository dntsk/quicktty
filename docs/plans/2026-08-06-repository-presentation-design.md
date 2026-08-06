# Repository Presentation Design

## Goal

Turn the QuickTTY GitHub repository into a polished, English-language product and contributor entry point while keeping detailed release operations out of the main README.

## Public README

The README will use a product-first structure:

1. QuickTTY icon, concise positioning, and direct links to the website, download, documentation, and releases.
2. Trust and compatibility badges for the latest release, MIT license, macOS 15+, and Apple Silicon.
3. A large workspace screenshot sourced from the existing website assets.
4. A concise feature overview covering tabs and splits, named workspaces, Quake mode, broadcast input, native search, and coding-agent progress.
5. Installation instructions for the signed and notarized DMG.
6. Minimal source-build instructions and links to contributor, security, release, and third-party documentation.

Detailed signing, notarization, and appcast procedures remain in `docs/releasing.md` rather than appearing inline in the README.

## Community Health Files

The repository will add:

- an MIT `LICENSE` naming Dmitrii Lialiuev as the copyright holder;
- `CONTRIBUTING.md` with supported platforms, setup, validation, scope, and pull-request expectations;
- `CODE_OF_CONDUCT.md` with concise first-party participation and enforcement rules;
- `SECURITY.md` that accurately states there is no private reporting channel and warns reporters not to publish sensitive details;
- structured bug and feature request issue forms;
- issue-template configuration with links to documentation and downloads;
- a pull-request checklist covering scope, tests, documentation, generated artifacts, and secrets.

All new public-facing content will be in English. Existing internal plans and release runbooks will not be translated as part of this change.

## GitHub Repository Metadata

The repository homepage will be `https://quicktty.app`. The description will position QuickTTY as a native terminal workspace for macOS. Topics will cover macOS, Swift, AppKit, terminal workflows, Ghostty, and developer tools. GitHub Issues remain enabled.

A social preview image is excluded because GitHub does not expose a dependable repository API or CLI field for configuring it; it can be uploaded manually in repository settings later.

## Validation

Validation will cover:

- YAML parsing and required fields for issue forms;
- existence of every relative README link and image;
- absence of Russian text in the new public-facing files;
- repository status and diff review;
- verification of the remote description, homepage, topics, issue setting, and detected license through GitHub CLI.

No product code, public API, release artifact, tag, or commit will be changed.
