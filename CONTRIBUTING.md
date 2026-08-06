# Contributing to QuickTTY

Thank you for helping improve QuickTTY. This project keeps a deliberately focused scope: a native terminal workspace for macOS with one physical window, tabs, splits, named workspaces, and mutually exclusive normal and Quake presentations.

## Before You Start

- Search existing issues before opening a new one.
- Use the structured issue forms for bugs and feature requests.
- Open an issue before investing in a large feature or architectural change.
- Keep pull requests focused. Unrelated refactoring makes changes harder to review.
- Do not change the pinned Ghostty revision or its integration boundary without prior agreement and integration coverage.

## Development Requirements

QuickTTY development requires:

- macOS 15 or newer on Apple Silicon;
- a full Xcode installation;
- XcodeGen 2.45.4 or newer;
- Apple Swift Format, available as `swift format`;
- Zig exactly 0.15.2 for the pinned Ghostty revision.

Clone the repository with all submodules:

```sh
git clone --recurse-submodules https://github.com/dntsk/quicktty.git
cd quicktty
```

For an existing clone:

```sh
git submodule update --init --recursive
```

Verify the local toolchain and generate the Xcode project:

```sh
make doctor
make generate
```

## Making Changes

- Preserve existing public behavior and APIs unless the issue requires a change.
- Keep unstable Ghostty C APIs inside `QuickTTY/Integration/GhosttyBridge/`; opaque C handles must not escape the bridge.
- Keep AppKit and `NSView` work on the main thread and preserve Swift strict-concurrency guarantees.
- Add or update tests for behavior changes.
- Update user documentation when configuration, shortcuts, or visible behavior changes.
- Do not commit generated Xcode projects, XCFrameworks, DerivedData, signing material, credentials, or local configuration.
- Write code comments in English and only when they explain a non-obvious reason.

## Validation

Run the smallest relevant checks while developing. Before submitting a pull request, run:

```sh
make check
```

You can also run the individual stages:

```sh
make format
make lint
make build
make test
```

A pull request should explain any check that could not be run and why.

## Pull Requests

A good pull request:

- describes the user problem and the chosen solution;
- links the relevant issue when one exists;
- contains only changes needed for that solution;
- includes tests and documentation where appropriate;
- calls out compatibility, configuration, or release implications;
- has no secrets or generated build artifacts.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
