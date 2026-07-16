#!/bin/sh
# Remind maintainers to update project memory after a substantial commit.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  exit 0
fi

CHANGED_COUNT=$(git diff-tree --root --no-commit-id --name-only -r HEAD | wc -l | tr -d '[:space:]')

if [ "$CHANGED_COUNT" -gt 5 ]; then
  printf '\n%s\n' "REMINDER: The last commit changed $CHANGED_COUNT files."
  printf '%s\n' 'Review project memory:'
  printf '%s\n' '  - .agents/memory/architecture-decisions.md'
  printf '%s\n' '  - .agents/memory/integration-contracts.md'
  printf '%s\n' '  - .agents/memory/tasks-completed.md'
  printf '%s\n' '  - .agents/memory/handoffs/'
fi
