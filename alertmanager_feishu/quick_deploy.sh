#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法:
  bash quick_deploy.sh \
    --install-root /opt/vllm-monitor-alertmanager \
    --env-file env.my.local \
    --feishu-route default https://open.feishu.cn/open-apis/bot/v2/hook/xxx \
    [--feishu-route critical https://open.feishu.cn/open-apis/bot/v2/hook/yyy secret severity=critical]

  参数:
    --install-root           运行实例目录（必填）
    --env-file               生成的 env 文件路径（必填）
    --feishu-route           路由名 + webhook + [secret] + [matchers]
                             secret 和 matchers 可选，按顺序跟在 webhook 后面
    --rules-file             可选告警规则 yml 文件
    --alertmanager-port      可选 Alertmanager 端口（默认 9093）
    --feishu-relay-port      可选 Feishu relay 端口（默认 19093）
EOF
  exit 1
}

INSTALL_ROOT=""
ENV_FILE=""
ROUTES_ARGS=()
RULES_FILE=""
AM_PORT=9093
RELAY_PORT=19093

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root)
      INSTALL_ROOT="$2"; shift 2 ;;
    --env-file)
      ENV_FILE="$2"; shift 2 ;;
    --feishu-route)
      name_arg="${2:-}"
      webhook_arg="${3:-}"
      if [[ -z "${name_arg}" || -z "${webhook_arg}" ]]; then
        echo "--feishu-route 必须至少跟 route_name webhook_url 两个参数"
        exit 1
      fi
      shift 3
      secret_arg=""
      matchers_arg=""
      if [[ $# -gt 0 && "${1:-}" != -* ]]; then
        secret_arg="$1"; shift
      fi
      if [[ $# -gt 0 && "${1:-}" != -* ]]; then
        matchers_arg="$1"; shift
      fi
      ROUTES_ARGS+=("${name_arg}" "${webhook_arg}" "${secret_arg}" "${matchers_arg}")
      ;;
    --rules-file)
      RULES_FILE="$2"; shift 2 ;;
    --alertmanager-port)
      AM_PORT="$2"; shift 2 ;;
    --feishu-relay-port)
      RELAY_PORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -z "${INSTALL_ROOT}" || -z "${ENV_FILE}" || ${#ROUTES_ARGS[@]} -eq 0 ]]; then
  usage
fi

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
fi
ENV_DIR="$(cd "$(dirname "${ENV_FILE}")" && pwd)"
ENV_BASENAME="$(basename "${ENV_FILE}" .local)"

# --- generate env file ---
cat > "${ENV_FILE}" <<ENVEOF
INSTALL_ROOT=${INSTALL_ROOT}

ALERTMANAGER_VERSION=0.28.1
ALERTMANAGER_URL=https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.linux-amd64.tar.gz
ALERTMANAGER_SHA256=5ac7ab5e4b8ee5ce4d8fb0988f9cb275efcc3f181b4b408179fafee121693311
ALERTMANAGER_LISTEN_ADDR=127.0.0.1
ALERTMANAGER_PORT=${AM_PORT}
ALERTMANAGER_CLUSTER_LISTEN_ADDR=

FEISHU_RELAY_LISTEN_ADDR=127.0.0.1
FEISHU_RELAY_PORT=${RELAY_PORT}
FEISHU_ROUTES_FILE=routes.${ENV_BASENAME}.tsv

FEISHU_RULES_FILE=${RULES_FILE:-rules.example.yml}

OFFLINE_BUNDLE_DIR=dist
ALLOW_DOWNLOAD=false
ENVEOF

# --- generate routes file ---
routes_file="${ENV_DIR}/routes.${ENV_BASENAME}.tsv"
{
  printf '%s\t%s\t%s\t%s\n' '# route_name' 'matchers' 'feishu_webhook' 'feishu_secret'
  i=0
  while [[ $i -lt ${#ROUTES_ARGS[@]} ]]; do
    name="${ROUTES_ARGS[$i]}"
    webhook="${ROUTES_ARGS[$((i+1))]}"
    secret="${ROUTES_ARGS[$((i+2))]}"
    matchers="${ROUTES_ARGS[$((i+3))]}"
    printf '%s\t%s\t%s\t%s\n' "${name}" "${matchers}" "${webhook}" "${secret}"
    i=$((i + 4))
  done
} > "${routes_file}"

echo "已生成:"
echo "  env:    ${ENV_FILE}"
echo "  routes: ${routes_file}"
echo
echo "检查一遍再执行:"
echo "  bash deploy.sh --env-file ${ENV_FILE}"
