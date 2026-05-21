#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-}"

if [[ "${1:-}" == "--env-file" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "--env-file 缺少参数"
    exit 1
  fi
  ENV_FILE="$2"
  shift 2
fi

if [[ -z "${ENV_FILE}" ]]; then
  echo "请显式传 --env-file env.<monitor>.local"
  exit 1
fi

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${SCRIPT_DIR}/env.example" "${ENV_FILE}"
  echo "已生成 ${ENV_FILE}，先把变量改对，再重新执行。"
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

required_vars=(
  INSTALL_ROOT
  ALERTMANAGER_VERSION
  ALERTMANAGER_URL
  ALERTMANAGER_PORT
  FEISHU_RELAY_PORT
  FEISHU_ROUTES_FILE
  OFFLINE_BUNDLE_DIR
  ALLOW_DOWNLOAD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "${ENV_FILE} 缺少变量: ${var_name}"
    exit 1
  fi
done

download_dir="${INSTALL_ROOT}/downloads"
bundle_dir="${OFFLINE_BUNDLE_DIR}"
if [[ "${bundle_dir}" != /* ]]; then
  bundle_dir="${SCRIPT_DIR}/${bundle_dir}"
fi
mkdir -p \
  "${download_dir}" \
  "${INSTALL_ROOT}/alertmanager/app"

am_tar="${download_dir}/$(basename "${ALERTMANAGER_URL}")"

calc_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
    return 0
  fi
  return 1
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  if [[ -z "${expected}" ]]; then
    return 0
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "未找到 sha256sum，跳过校验: ${file}"
    return 0
  fi
  local actual
  actual="$(calc_sha256 "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "SHA256 不匹配: ${file}"
    echo "expected=${expected}"
    echo "actual=${actual}"
    return 1
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local expected_sha="$3"
  local filename bundle_file
  filename="$(basename "${output}")"
  bundle_file="${bundle_dir}/${filename}"

  if [[ -f "${output}" ]] && verify_sha256 "${output}" "${expected_sha}"; then
    echo "已存在且校验通过: ${output}"
    return 0
  fi

  if [[ -f "${bundle_file}" ]] && verify_sha256 "${bundle_file}" "${expected_sha}"; then
    cp -f "${bundle_file}" "${output}"
    echo "已从离线包目录复制: ${bundle_file} -> ${output}"
    return 0
  fi

  if [[ "${ALLOW_DOWNLOAD}" != "true" ]]; then
    echo "离线包不存在，且 ALLOW_DOWNLOAD=false，不联网下载。"
    echo "缺少文件: ${bundle_file}"
    echo "请先下载 $(basename "${url}") 放到 ${bundle_dir}/"
    exit 1
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "${output}" "${url}"
  elif command -v curl >/dev/null 2>&1; then
    curl -L "${url}" -o "${output}"
  else
    echo "缺少 wget/curl，无法下载 ${url}"
    exit 1
  fi

  verify_sha256 "${output}" "${expected_sha}"
}

download_file "${ALERTMANAGER_URL}" "${am_tar}" "${ALERTMANAGER_SHA256:-}"

"${SCRIPT_DIR}/stop.sh" --env-file "${ENV_FILE}" || true

rm -rf "${INSTALL_ROOT}/alertmanager/app"/*
tar -xzf "${am_tar}" -C "${INSTALL_ROOT}/alertmanager/app" --strip-components=1

"${SCRIPT_DIR}/start.sh" --env-file "${ENV_FILE}"

echo
echo "部署完成。"
echo "Alertmanager  API: http://127.0.0.1:${ALERTMANAGER_PORT}"
echo "Feishu relay:    http://127.0.0.1:${FEISHU_RELAY_PORT}/healthz"
