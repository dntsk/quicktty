#!/bin/sh
# Verify repository state and tests without performing release operations.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: This directory is not a Git working tree.' >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  printf '%s\n' 'ERROR: The working tree is not clean. Commit or stash changes first.' >&2
  exit 1
fi

if ! UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
  printf '%s\n' 'ERROR: The current branch has no configured upstream.' >&2
  exit 1
fi

LOCAL_HEAD=$(git rev-parse HEAD)
UPSTREAM_HEAD=$(git rev-parse '@{upstream}')

if [ "$LOCAL_HEAD" != "$UPSTREAM_HEAD" ]; then
  printf '%s\n' "ERROR: HEAD does not match upstream $UPSTREAM." >&2
  exit 1
fi

printf '%s\n' "Working tree is clean and HEAD matches $UPSTREAM."
printf '%s\n' 'Running make check...'
make check
