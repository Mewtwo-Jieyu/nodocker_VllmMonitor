#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-}"
SEND_TEST=false
TEST_ROUTE=default

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --send-test)
      SEND_TEST=true
      shift
      ;;
    --route)
      TEST_ROUTE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

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

am_port="${ALERTMANAGER_PORT:-9093}"
relay_port="${FEISHU_RELAY_PORT:-19093}"

echo "[PID]"
for service in feishu-relay alertmanager; do
  pid_file="${INSTALL_ROOT}/run/${service}.pid"
  if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "${service}: running, pid=$(cat "${pid_file}")"
  else
    echo "${service}: not running"
  fi
done

echo
echo "[HTTP]"

# Feishu relay health
if curl -fsS "http://127.0.0.1:${relay_port}/healthz" 2>/dev/null; then
  echo ""
  echo "Feishu relay: 健康"
else
  echo "Feishu relay: 不可达 http://127.0.0.1:${relay_port}/healthz"
fi

# Alertmanager health
if curl -fsS "http://127.0.0.1:${am_port}/-/healthy" 2>/dev/null; then
  echo "Alertmanager: 健康"
else
  echo "Alertmanager: 不可达 http://127.0.0.1:${am_port}/-/healthy"
fi

# Alertmanager config check
am_conf="${INSTALL_ROOT}/alertmanager/conf/alertmanager.yml"
amtool_bin="${INSTALL_ROOT}/alertmanager/app/amtool"
if [[ -x "${amtool_bin}" ]] && [[ -f "${am_conf}" ]]; then
  echo
  echo "[CONFIG]"
  "${amtool_bin}" check-config "${am_conf}" 2>&1 || true
fi

# Port binding check
echo
echo "[BIND]"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -E ":(${am_port}|${relay_port})" || echo "(未检测到监听端口)"
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | grep -E ":(${am_port}|${relay_port})" || echo "(未检测到监听端口)"
fi

# Test message
if [[ "${SEND_TEST}" == "true" ]]; then
  echo
  echo "[TEST] 发送测试消息到路由 '${TEST_ROUTE}'..."
  if curl -fsS -X POST "http://127.0.0.1:${relay_port}/test/${TEST_ROUTE}" 2>/dev/null; then
    echo
    echo "测试消息已发送，请检查飞书群是否收到。"
  else
    echo "测试消息发送失败，检查 relay 日志:"
    echo "  ${INSTALL_ROOT}/feishu-relay/logs/stdout.log"
  fi
fi
