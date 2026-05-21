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
  echo "缺少 ${ENV_FILE}，先从 env.example 复制一份。"
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

for service in grafana prometheus; do
  pid_file="${INSTALL_ROOT}/run/${service}.pid"
  if [[ -f "${pid_file}" ]]; then
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}"
      echo "已停止 ${service}，PID=${pid}"
    else
      echo "${service} pid 文件存在，但进程已不在。"
    fi
    rm -f "${pid_file}"
  else
    echo "${service} 未运行。"
  fi
done
