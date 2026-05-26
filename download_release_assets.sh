#!/usr/bin/env bash
set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:-v0.1.0}"
BASE_URL="${BASE_URL:-https://github.com/Mewtwo-Jieyu/nodocker_VllmMonitor/releases/download/${RELEASE_TAG}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

download_one() {
  local output="$1"
  local sha256="$2"
  local url="${BASE_URL}/$(basename "${output}")"

  mkdir -p "$(dirname "${output}")"
  if [[ -f "${output}" ]] && echo "${sha256}  ${output}" | sha256sum -c - >/dev/null 2>&1 && gzip -t "${output}" >/dev/null 2>&1; then
    echo "已存在且校验通过: ${output}"
    return 0
  fi

  echo "下载: ${url}"
  curl -fL --retry 3 -o "${output}.tmp" "${url}"
  echo "${sha256}  ${output}.tmp" | sha256sum -c -
  gzip -t "${output}.tmp"
  mv "${output}.tmp" "${output}"
  echo "已保存: ${output}"
}

cd "${SCRIPT_DIR}"

download_one \
  "dist/prometheus-3.11.1.linux-amd64.tar.gz" \
  "85ee3dd6e3674c7fdad5cffa69a8d7b5ccc93a595227204a0153796a98ee46a4"

download_one \
  "dist/grafana-enterprise_12.4.1_22846628243_linux_amd64.tar.gz" \
  "b68f755858bbcb5d7ae315bc34d1f4d6f116cd71cef8630da30a7fa2a02643b4"

download_one \
  "alertmanager_feishu/dist/alertmanager-0.28.1.linux-amd64.tar.gz" \
  "5ac7ab5e4b8ee5ce4d8fb0988f9cb275efcc3f181b4b408179fafee121693311"

echo "离线包准备完成。"
