#!/bin/sh
# Run read-only Swift style checks for source directories that exist.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

FOUND=0

for DIRECTORY in QuickTTY QuickTTYTests; do
  if [ -d "$DIRECTORY" ]; then
    if ! command -v swift >/dev/null 2>&1; then
      printf '%s\n' "ERROR: Swift toolchain is required to lint $DIRECTORY." >&2
      exit 1
    fi

    printf '%s\n' "Linting $DIRECTORY..."
    swift format lint --recursive "$DIRECTORY"
    FOUND=1
  fi
done

if [ "$FOUND" -eq 0 ]; then
  printf '%s\n' 'No QuickTTY or QuickTTYTests directory exists; nothing to lint.'
fi
