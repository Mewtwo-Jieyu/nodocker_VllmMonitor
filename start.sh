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

"${SCRIPT_DIR}/render_configs.sh" --env-file "${ENV_FILE}"

subpath="${GRAFANA_SUBPATH%/}"
if [[ -z "${subpath}" ]]; then
  subpath="/"
fi

if [[ "${subpath}" == "/" ]]; then
  login_path="/login"
else
  login_path="${subpath}/login"
fi

mkdir -p \
  "${INSTALL_ROOT}/run" \
  "${INSTALL_ROOT}/prometheus/logs" \
  "${INSTALL_ROOT}/grafana/logs" \
  "${INSTALL_ROOT}/prometheus/data" \
  "${INSTALL_ROOT}/grafana/data" \
  "${INSTALL_ROOT}/grafana/plugins"

prom_pid_file="${INSTALL_ROOT}/run/prometheus.pid"
grafana_pid_file="${INSTALL_ROOT}/run/grafana.pid"

if [[ -f "${prom_pid_file}" ]] && kill -0 "$(cat "${prom_pid_file}")" 2>/dev/null; then
  echo "Prometheus 已在运行，PID=$(cat "${prom_pid_file}")"
else
  nohup "${INSTALL_ROOT}/prometheus/app/prometheus" \
    --config.file="${INSTALL_ROOT}/prometheus/conf/prometheus.yml" \
    --storage.tsdb.path="${INSTALL_ROOT}/prometheus/data" \
    --web.listen-address="127.0.0.1:${PROMETHEUS_PORT}" \
    > "${INSTALL_ROOT}/prometheus/logs/prometheus.log" 2>&1 &
  echo $! > "${prom_pid_file}"
  echo "Prometheus 已启动，PID=$!"
fi

if [[ -f "${grafana_pid_file}" ]] && kill -0 "$(cat "${grafana_pid_file}")" 2>/dev/null; then
  echo "Grafana 已在运行，PID=$(cat "${grafana_pid_file}")"
else
  nohup "${INSTALL_ROOT}/grafana/app/bin/grafana" server \
    --homepath "${INSTALL_ROOT}/grafana/app" \
    --config "${INSTALL_ROOT}/grafana/conf/grafana.ini" \
    > "${INSTALL_ROOT}/grafana/logs/grafana.log" 2>&1 &
  echo $! > "${grafana_pid_file}"
  echo "Grafana 已启动，PID=$!"
fi

if ! curl -fsSI "http://127.0.0.1:${GRAFANA_PORT}${login_path}" | grep -qi '^Cache-Control: no-store'; then
  echo "Grafana 本机健康检查失败: http://127.0.0.1:${GRAFANA_PORT}${login_path}"
  echo "很可能是 ${GRAFANA_PORT} 端口被别的进程占了，或者 Grafana 没真正启动成功。"
  echo "最近日志:"
  tail -50 "${INSTALL_ROOT}/grafana/logs/grafana.log" || true
  exit 1
fi
