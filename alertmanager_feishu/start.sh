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

mkdir -p \
  "${INSTALL_ROOT}/run" \
  "${INSTALL_ROOT}/alertmanager/logs" \
  "${INSTALL_ROOT}/alertmanager/data" \
  "${INSTALL_ROOT}/feishu-relay/logs"

# --- start feishu relay first ---
relay_pid_file="${INSTALL_ROOT}/run/feishu-relay.pid"

if [[ -f "${relay_pid_file}" ]] && kill -0 "$(cat "${relay_pid_file}")" 2>/dev/null; then
  echo "Feishu relay 已在运行，PID=$(cat "${relay_pid_file}")"
else
  FEISHU_RELAY_LISTEN_ADDR="${FEISHU_RELAY_LISTEN_ADDR:-127.0.0.1}" \
  FEISHU_RELAY_PORT="${FEISHU_RELAY_PORT:-19093}" \
  FEISHU_ROUTES_FILE="${INSTALL_ROOT}/feishu-relay/conf/routes.tsv" \
  FEISHU_RELAY_LOG_DIR="${INSTALL_ROOT}/feishu-relay/logs" \
  nohup python3 "${SCRIPT_DIR}/feishu_relay.py" \
    > "${INSTALL_ROOT}/feishu-relay/logs/stdout.log" 2>&1 &
  echo $! > "${relay_pid_file}"
  echo "Feishu relay 已启动，PID=$!"
fi

# --- start alertmanager ---
am_pid_file="${INSTALL_ROOT}/run/alertmanager.pid"
am_listen="${ALERTMANAGER_LISTEN_ADDR:-127.0.0.1}:${ALERTMANAGER_PORT:-9093}"
am_cluster="${ALERTMANAGER_CLUSTER_LISTEN_ADDR:-}"

if [[ -f "${am_pid_file}" ]] && kill -0 "$(cat "${am_pid_file}")" 2>/dev/null; then
  echo "Alertmanager 已在运行，PID=$(cat "${am_pid_file}")"
else
  am_args=(
    --config.file="${INSTALL_ROOT}/alertmanager/conf/alertmanager.yml"
    --storage.path="${INSTALL_ROOT}/alertmanager/data"
    --web.listen-address="${am_listen}"
  )
  if [[ -n "${am_cluster}" ]]; then
    am_args+=(--cluster.listen-address="${am_cluster}")
  fi

  nohup "${INSTALL_ROOT}/alertmanager/app/alertmanager" "${am_args[@]}" \
    > "${INSTALL_ROOT}/alertmanager/logs/alertmanager.log" 2>&1 &
  echo $! > "${am_pid_file}"
  echo "Alertmanager 已启动，PID=$!"
fi

# --- health check ---
sleep 1

if ! curl -fsS "http://127.0.0.1:${FEISHU_RELAY_PORT:-19093}/healthz" >/dev/null 2>&1; then
  echo "Feishu relay 健康检查失败: http://127.0.0.1:${FEISHU_RELAY_PORT:-19093}/healthz"
  echo "最近日志:"
  tail -20 "${INSTALL_ROOT}/feishu-relay/logs/stdout.log" || true
  exit 1
fi

if ! curl -fsS "http://127.0.0.1:${ALERTMANAGER_PORT:-9093}/-/healthy" >/dev/null 2>&1; then
  echo "Alertmanager 健康检查失败: http://127.0.0.1:${ALERTMANAGER_PORT:-9093}/-/healthy"
  echo "最近日志:"
  tail -20 "${INSTALL_ROOT}/alertmanager/logs/alertmanager.log" || true
  exit 1
fi

echo "所有服务已启动。"
