#!/usr/bin/env bash
set -euo pipefail

selector="$(git rev-parse --show-toplevel)/scripts/kontrol-inputs-match.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
git init -q
git config user.name "CI fixture"
git config user.email "fixture@example.invalid"

commit_tree() {
  local tree commit
  git add -A
  tree=$(git write-tree)
  commit=$(git commit-tree "$tree" "$@" -m fixture)
  git update-ref HEAD "$commit"
}

expect_proof() {
  if bash "$selector" "$1" HEAD; then
    echo "Unexpected proof reuse for $2" >&2
    exit 1
  fi
}

mkdir -p src docs scripts
echo 'contract Pool {}' > src/Pool.sol
echo 'benchmark' > scripts/benchmark-receipts.py
commit_tree
verified=$(git rev-parse HEAD)

echo 'measured results' > docs/gas.md
echo 'new measurements' >> scripts/benchmark-receipts.py
commit_tree -p HEAD
bash "$selector" "$verified" HEAD
expect_proof "" "missing verified revision"
unrelated=$(git commit-tree "$(git write-tree)" -m unrelated)
expect_proof "$unrelated" "matching files without a verified ancestor"

echo 'contract Pool { uint public value; }' > src/Pool.sol
commit_tree -p HEAD
echo 'documentation follow-up' >> docs/gas.md
commit_tree -p HEAD
expect_proof "$verified" "an unverified Solidity change followed by documentation"

git mv src/Pool.sol docs/Pool.md
commit_tree -p HEAD
expect_proof HEAD^ "a Solidity file renamed into documentation"

echo 'new tool' > scripts/new-tool
commit_tree -p HEAD
bash "$selector" HEAD^ HEAD

mkdir -p tools
echo 'contract Extra {}' > tools/Extra.sol
commit_tree -p HEAD
expect_proof HEAD^ "a new Solidity source"

echo 'pinned dependency' > soldeer.lock
commit_tree -p HEAD
expect_proof HEAD^ "a dependency lock change"
