ifneq ($(filter release notarize signed-alpha,$(MAKECMDGOALS)),)
ifeq ($(origin DEVELOPMENT_TEAM),command line)
$(error DEVELOPMENT_TEAM must be passed through the process environment before make, not on the command line)
endif
ifeq ($(origin CODE_SIGN_IDENTITY),command line)
$(error CODE_SIGN_IDENTITY must be passed through the process environment before make, not on the command line)
endif
ifeq ($(origin DMG),command line)
$(error DMG must be passed through the process environment before make, not on the command line)
endif
ifeq ($(origin NOTARY_PROFILE),command line)
$(error NOTARY_PROFILE must be passed through the process environment before make, not on the command line)
endif
ifeq ($(origin DEVELOPER_DIR),command line)
$(error DEVELOPER_DIR must be passed through the process environment before make, not on the command line)
endif
ifeq ($(origin RELEASE_LABEL),command line)
$(error RELEASE_LABEL must be passed through the process environment before make, not on the command line)
endif
endif

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

PROJECT := GhostTerm.xcodeproj
SCHEME := GhostTerm
DERIVED_DATA := .build/DerivedData
DESTINATION := platform=macOS,arch=arm64
SWIFT_SOURCES := GhostTerm GhostTermTests

# Build and test share one DerivedData directory.
.NOTPARALLEL:

.PHONY: generate doctor ghostty ghostty-resources-test release release-contract notarize notarize-contract signed-alpha format callback-contract lint build test check

generate: ghostty
	xcodegen generate --spec project.yml

doctor:
	./scripts/check-tools.sh

ghostty:
	./scripts/build-ghostty.sh

ghostty-resources-test: ghostty
	./scripts/tests/copy-ghostty-resources-test.sh

release:
	./scripts/build-release.sh

release-contract:
	./scripts/tests/build-release-test.sh

notarize:
	./scripts/notarize-dmg.sh

notarize-contract:
	./scripts/tests/notarize-dmg-test.sh

signed-alpha:
	$(MAKE) release
	$(MAKE) notarize

format:
	swift format format --recursive --in-place $(SWIFT_SOURCES)

callback-contract:
	./scripts/check-runtime-callbacks.sh

lint: release-contract notarize-contract callback-contract
	swift format lint --recursive $(SWIFT_SOURCES)

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) test

check: ghostty-resources-test lint build test
