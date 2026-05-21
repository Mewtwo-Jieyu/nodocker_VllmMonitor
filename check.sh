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

ENV_DIR="$(cd "$(dirname "${ENV_FILE}")" && pwd)"

set -a
source "${ENV_FILE}"
set +a

services_file="${METRICS_SERVICES_FILE}"
if [[ "${services_file}" != /* ]]; then
  services_file="${ENV_DIR}/${services_file}"
fi

subpath="${GRAFANA_SUBPATH%/}"
if [[ -z "${subpath}" ]]; then
  subpath="/"
fi

if [[ "${subpath}" == "/" ]]; then
  login_path="/login"
else
  login_path="${subpath}/login"
fi

echo "[PID]"
for service in prometheus grafana; do
  pid_file="${INSTALL_ROOT}/run/${service}.pid"
  if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "${service}: running, pid=$(cat "${pid_file}")"
  else
    echo "${service}: not running"
  fi
done

echo
echo "[HTTP]"
curl -fsS "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
echo
grafana_headers="$(curl -fsSI "http://127.0.0.1:${GRAFANA_PORT}${login_path}")"
echo "${grafana_headers}"
if ! echo "${grafana_headers}" | grep -qi '^Cache-Control: no-store'; then
  echo
  echo "Grafana 响应不对，不像 Grafana 登录页。先查 ${GRAFANA_PORT} 端口被谁占了。"
  exit 1
fi

echo
echo "[METRICS TARGETS]"
while IFS=$'\t' read -r service_name metrics_scheme metrics_target metrics_path extra; do
  if [[ -z "${service_name}" || "${service_name}" == \#* ]]; then
    continue
  fi
  if [[ -n "${extra:-}" ]]; then
    echo "服务列表字段过多，必须是 4 列: ${service_name}"
    exit 1
  fi
  echo "${service_name}: ${metrics_scheme}://${metrics_target}${metrics_path}"
  curl -fsS "${metrics_scheme}://${metrics_target}${metrics_path}" >/dev/null
done < "${services_file}"
