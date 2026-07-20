DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

PROJECT := GhostTerm.xcodeproj
SCHEME := GhostTerm
DERIVED_DATA := .build/DerivedData
DESTINATION := platform=macOS,arch=arm64
SWIFT_SOURCES := GhostTerm GhostTermTests

# Build and test share one DerivedData directory.
.NOTPARALLEL:

.PHONY: generate doctor ghostty ghostty-resources-test format callback-contract lint build test check

generate: ghostty
	xcodegen generate --spec project.yml

doctor:
	./scripts/check-tools.sh

ghostty:
	./scripts/build-ghostty.sh

ghostty-resources-test: ghostty
	./scripts/tests/copy-ghostty-resources-test.sh

format:
	swift format format --recursive --in-place $(SWIFT_SOURCES)

callback-contract:
	./scripts/check-runtime-callbacks.sh

lint: callback-contract
	swift format lint --recursive $(SWIFT_SOURCES)

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) test

check: ghostty-resources-test lint build test
