#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/.kontrol"
CONFIG_FILE="${KONTROL_CONFIG_FILE:-kontrol.toml}"
CONFIG_PROFILE="${KONTROL_CONFIG_PROFILE:-local}"
LOCAL_HI_PROFILE="${KONTROL_LOCAL_HI_PROFILE:-local-hi}"
KONTROL_BIN="${KONTROL_BIN:-kontrol}"
KONTROL_REINIT="${KONTROL_REINIT:-1}"
KONTROL_PROVE_RETRIES="${KONTROL_PROVE_RETRIES:-3}"

SOLIDITY_ESSENTIAL_REGEX="${KONTROL_SOLIDITY_ESSENTIAL_REGEX:-ProofSlotRecyclingSolidity.prove_.*_reverts}"
SOLIDITY_FULL_REGEX="${KONTROL_SOLIDITY_FULL_REGEX:-ProofSlotRecyclingSolidity.prove_.*}"

usage() {
  cat <<'EOF'
Usage: ./script/kontrol.sh <command>

Commands:
  prove-core      Build and prove essential Solidity Kontrol specs (native host Kontrol).
  prove-core-hi   Build and prove Solidity-focused specs with the local-hi profile.
  prove-core-full Build and prove full Solidity Kontrol spec set.
  list            List discovered Kontrol tests/specs (native host Kontrol).
  clean           Remove local Kontrol artifacts (.kontrol/).
EOF
}

run_kontrol() {
  "${KONTROL_BIN}" "$@"
}

run_kontrol_prove_with_retries() {
  local retries="${KONTROL_PROVE_RETRIES}"
  local -a prove_args=("$@")

  local attempt
  for ((attempt = 1; attempt <= retries; attempt++)); do
    set +e
    run_kontrol "${prove_args[@]}"
    local status=$?
    set -e
    if [[ "${status}" -eq 0 ]]; then
      return 0
    fi
    if (( attempt == retries )); then
      return "${status}"
    fi
    echo "Kontrol prove failed (attempt ${attempt}/${retries}); retrying..."
    pkill -f 'kore-rpc out/kompiled/definition.kore' >/dev/null 2>&1 || true
    sleep 2
  done
}

ensure_runtime() {
  if ! command -v "${KONTROL_BIN}" >/dev/null 2>&1; then
    cat >&2 <<EOF
Kontrol is not installed locally.
Install locally (Apple Silicon):
  APPLE_SILICON=true UV_PYTHON=3.10 kup install kontrol --version v1.0.231
EOF
    exit 1
  fi

  if ! command -v forge >/dev/null 2>&1; then
    echo "Foundry (forge) is required but not installed." >&2
    exit 1
  fi

}

write_toolchain_metadata() {
  mkdir -p "${ARTIFACT_DIR}"
  {
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'kontrol_bin=%s\n' "$(command -v "${KONTROL_BIN}")"
    printf 'kontrol_version=%s\n' "$("${KONTROL_BIN}" version | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]$//')"
    printf 'forge_version=%s\n' "$(forge --version | head -n 1)"
  } > "${ARTIFACT_DIR}/local-toolchain.txt"
}

prove_matches() {
  local profile="$1"
  shift
  local -a patterns=("$@")
  cd "${ROOT_DIR}"
  ensure_runtime
  write_toolchain_metadata
  run_kontrol build --config-file "${CONFIG_FILE}" --config-profile "${profile}"
  for pattern in "${patterns[@]}"; do
    local -a prove_args=(
      prove
      --config-file "${CONFIG_FILE}"
      --config-profile "${profile}"
      --match-test "${pattern}"
    )
    if [[ "${KONTROL_REINIT}" == "1" ]]; then
      prove_args+=(--reinit)
    fi
    run_kontrol_prove_with_retries "${prove_args[@]}"
  done
}

case "${1:-}" in
  prove-core)
    prove_matches \
      "${CONFIG_PROFILE}" \
      "${SOLIDITY_ESSENTIAL_REGEX}"
    ;;
  prove-core-hi)
    prove_matches \
      "${LOCAL_HI_PROFILE}" \
      "${SOLIDITY_ESSENTIAL_REGEX}"
    ;;
  prove-core-full)
    prove_matches \
      "${CONFIG_PROFILE}" \
      "${SOLIDITY_FULL_REGEX}"
    ;;
  list)
    cd "${ROOT_DIR}"
    ensure_runtime
    write_toolchain_metadata
    mkdir -p "${ROOT_DIR}/out/proofs"
    run_kontrol build --config-file "${CONFIG_FILE}" --config-profile "${CONFIG_PROFILE}"
    run_kontrol list --config-file "${CONFIG_FILE}"
    ;;
  clean)
    rm -rf "${ARTIFACT_DIR}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
