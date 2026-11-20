#!/usr/bin/env bash
set -euo pipefail

version=v1.5.1
download_retries=3
archive_name="foundry_${version}_linux_amd64.tar.gz"
archive="${RUNNER_TEMP:?}/${archive_name}"
sha256=73640b01bd9ed29fdb4965085099371f8cf0dbbec3e2086cf54564efc4dcfe88
bin_dir="${RUNNER_TEMP}/slot-recycling-foundry/bin"

curl --fail --silent --show-error --location --retry "${download_retries}" \
  "https://github.com/foundry-rs/foundry/releases/download/${version}/${archive_name}" --output "${archive}"
printf '%s  %s\n' "${sha256}" "${archive}" | sha256sum -c -
mkdir -p "${bin_dir}"
tar -xzf "${archive}" -C "${bin_dir}" forge
printf '%s\n' "${bin_dir}" >> "${GITHUB_PATH:?}"
