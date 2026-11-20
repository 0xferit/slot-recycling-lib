#!/usr/bin/env bash
set -euo pipefail

verified=${1-}
candidate=${2-}
[[ -n "$verified" && -n "$candidate" ]] || exit 1
git merge-base --is-ancestor "$verified" "$candidate"
git diff --quiet --no-ext-diff --no-renames --ignore-submodules=none "$verified" "$candidate" -- \
  ':(top,glob)**/*.sol' ':(top,glob)**/*.vy' ':(top,glob)**/*.vyi' ':(top,glob)**/*.yul' \
  ':(top,glob)**/*.k' ':(top,glob)**/*.k.md' \
  ':(top,glob)**/.gitattributes' ':(top).gitmodules' ':(top).env' \
  ':(top)foundry.toml' ':(top)kontrol.toml' ':(top)remappings.txt' \
  ':(top)soldeer.toml' ':(top)soldeer.lock' ':(top)dependencies' \
  ':(top)scripts/install-ci-forge.sh' ':(top)scripts/kontrol-inputs-match.sh' \
  ':(top).github/workflows/ci.yml'
