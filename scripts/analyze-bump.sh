#!/usr/bin/env bash
set -euo pipefail

# Called by @semantic-release/exec as analyzeCommitsCmd.
# Asks Claude to determine the semantic version bump from the diff.
# Skips release entirely when no Solidity source files under src/ changed.
# Falls back to "patch" if the token is missing or the call fails.

# Comparison base: last successful Soldeer publish, then last release tag, then repo root.
if git rev-parse soldeer-published >/dev/null 2>&1; then
  BASE="soldeer-published"
elif [ -n "${LAST_RELEASE_GIT_TAG:-}" ]; then
  BASE="$LAST_RELEASE_GIT_TAG"
else
  BASE=$(git rev-list --max-parents=0 HEAD)
fi

# No release when library source is unchanged (README, CI, docs, tests are chore).
SOL_DIFF=$(git diff "$BASE"..HEAD -- 'src/*.sol' 'src/**/*.sol' 2>/dev/null || echo "")
if [ -z "$SOL_DIFF" ]; then
  exit 0
fi

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "patch"
  exit 0
fi

COMMIT_LOG=$(git log "$BASE"..HEAD --pretty=format:"- %s" 2>/dev/null || echo "- initial release")
DIFF_STAT=$(git diff "$BASE"..HEAD --stat 2>/dev/null | tail -30 || echo "no diff")

PROMPT="You are a semantic versioning expert for a Solidity library (slot-recycling-lib).
The public API is frozen post-1.0.0 per STABILITY.md. The frozen public API surface is:

  Frozen surface (any change here → major):
  - RecycleConfig user-defined value type and its uint256 underlying type
  - SlotRecyclingLib.Pool struct
  - File-level errors: BadRecycleConfig, TombstoneIsZero, VacancyFlagNotSet, ClearMaskIncomplete, SentinelOccupied (names, parameter types, parameter order)
  - Library function signatures: create, vacancyMask, bitmask, allocate, free, freeWithSentinel, load, store, isVacant, findVacant
  - Global using directive: using SlotRecyclingLib for RecycleConfig global
  - Canonical import path: slot-recycling-lib/src/SlotRecyclingLib.sol

Rules:
- major: ANY change to the frozen public API surface above (renamed/removed functions, changed signatures, renamed/removed errors, changed type definitions, changed import path)
- minor: new features that do not break existing consumers (new functions, new error types, new helper types)
- patch: bug fixes, internal refactoring, performance improvements, documentation, tooling

Respond with exactly one word: major, minor, or patch.

Commits since v${LAST_RELEASE_VERSION:-0.0.0}:
${COMMIT_LOG}

Changed files:
${DIFF_STAT}

Solidity diff (truncated):
$(echo "$SOL_DIFF" | head -200)"

RESPONSE=$(echo "$PROMPT" | claude --print --model opus --effort max 2>/dev/null) || { echo "patch"; exit 0; }

BUMP=$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]' | grep -oE 'major|minor|patch' | head -1)

echo "${BUMP:-patch}"
