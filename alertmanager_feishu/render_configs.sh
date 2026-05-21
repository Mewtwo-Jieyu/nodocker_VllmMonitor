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

required_vars=(
  INSTALL_ROOT
  ALERTMANAGER_PORT
  FEISHU_RELAY_PORT
  FEISHU_ROUTES_FILE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "${ENV_FILE} 缺少变量: ${var_name}"
    exit 1
  fi
done

routes_file="${FEISHU_ROUTES_FILE}"
if [[ "${routes_file}" != /* ]]; then
  routes_file="${ENV_DIR}/${routes_file}"
fi

if [[ ! -f "${routes_file}" ]]; then
  echo "缺少路由文件: ${routes_file}"
  exit 1
fi

am_conf_dir="${INSTALL_ROOT}/alertmanager/conf"
relay_conf_dir="${INSTALL_ROOT}/feishu-relay/conf"
rules_dir="${INSTALL_ROOT}/rules"

mkdir -p "${am_conf_dir}" "${relay_conf_dir}" "${rules_dir}"

# copy routes file to run dir for relay
cp "${routes_file}" "${relay_conf_dir}/routes.tsv"

# copy rules file if configured
if [[ -n "${FEISHU_RULES_FILE:-}" ]]; then
  rules_file="${FEISHU_RULES_FILE}"
  if [[ "${rules_file}" != /* ]]; then
    rules_file="${ENV_DIR}/${rules_file}"
  fi
  if [[ -f "${rules_file}" ]]; then
    cp "${rules_file}" "${rules_dir}/alerts.yml"
    echo "已复制告警规则: ${rules_file}"
  fi
fi

# --- build alertmanager.yml ---

listen_addr="${ALERTMANAGER_LISTEN_ADDR:-127.0.0.1}"
cluster_addr="${ALERTMANAGER_CLUSTER_LISTEN_ADDR:-}"

cat > "${am_conf_dir}/alertmanager.yml" <<'HEADER'
global:
  resolve_timeout: 5m

route:
HEADER

# find default route and named routes
default_webhook=""
route_names=()
route_matchers=()
route_count=0

tab=$'\t'
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ -z "${line}" || "${line}" == \#* ]]; then
    continue
  fi

  if [[ "${line}" != *"${tab}"* ]]; then
    echo "路由文件字段过少，至少需要 route_name、matchers、feishu_webhook: ${line}"
    exit 1
  fi

  route_name="${line%%${tab}*}"
  rest="${line#*${tab}}"
  if [[ "${rest}" != *"${tab}"* ]]; then
    echo "路由文件字段过少，至少需要 route_name、matchers、feishu_webhook: ${route_name}"
    exit 1
  fi

  matchers="${rest%%${tab}*}"
  rest="${rest#*${tab}}"
  if [[ "${rest}" == *"${tab}"* ]]; then
    webhook="${rest%%${tab}*}"
    secret="${rest#*${tab}}"
    if [[ "${secret}" == *"${tab}"* ]]; then
      echo "路由文件字段过多，最多 4 列: ${route_name}"
      exit 1
    fi
  else
    webhook="${rest}"
    secret=""
  fi

  if [[ -z "${route_name}" || "${route_name}" == \#* ]]; then
    continue
  fi
  if [[ ! "${route_name}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "route_name 只能用字母、数字、下划线、短横线: ${route_name}"
    exit 1
  fi
  if [[ -z "${webhook}" ]]; then
    echo "路由 ${route_name} 缺少 feishu_webhook"
    exit 1
  fi

  if [[ -z "${matchers}" ]]; then
    if [[ "${route_name}" != "default" ]]; then
      echo "matchers 为空的默认路由必须命名为 default"
      exit 1
    fi
    if [[ -n "${default_webhook}" ]]; then
      echo "只能有一个 matchers 为空的 default 路由"
      exit 1
    fi
    default_webhook="${webhook}"
  else
    route_names+=("${route_name}")
    route_matchers+=("${matchers}")
    route_count=$((route_count + 1))
  fi
done < "${routes_file}"

if [[ -z "${default_webhook}" ]]; then
  echo "必须有一个 matchers 为空的 default 路由"
  exit 1
fi

{
  echo "  receiver: feishu-default"
  echo "  group_by: ['alertname', 'service']"
  echo "  group_wait: 30s"
  echo "  group_interval: 5m"
  echo "  repeat_interval: 1h"

  if [[ ${route_count} -gt 0 ]]; then
    echo "  routes:"
    route_index=0
    while [[ ${route_index} -lt ${route_count} ]]; do
      name="${route_names[${route_index}]}"
      matchers="${route_matchers[${route_index}]}"
      key="${matchers%%=*}"
      val="${matchers#*=}"
      echo "    - match:"
      echo "        ${key}: '${val}'"
      echo "      receiver: feishu-${name}"
      route_index=$((route_index + 1))
    done
  fi
} >> "${am_conf_dir}/alertmanager.yml"

# receivers section
{
  echo ""
  echo "receivers:"
  echo "- name: feishu-default"
  echo "  webhook_configs:"
  echo "  - url: http://${FEISHU_RELAY_LISTEN_ADDR:-127.0.0.1}:${FEISHU_RELAY_PORT}/alert/default"
  echo "    send_resolved: true"

  route_index=0
  while [[ ${route_index} -lt ${route_count} ]]; do
    name="${route_names[${route_index}]}"
    echo "- name: feishu-${name}"
    echo "  webhook_configs:"
    echo "  - url: http://${FEISHU_RELAY_LISTEN_ADDR:-127.0.0.1}:${FEISHU_RELAY_PORT}/alert/${name}"
    echo "    send_resolved: true"
    route_index=$((route_index + 1))
  done
} >> "${am_conf_dir}/alertmanager.yml"

echo "配置已生成。"
echo "路由数量: $(( route_count + 1 )) (含 default)"

# validate with amtool if available
amtool_bin="${INSTALL_ROOT}/alertmanager/app/amtool"
if [[ -x "${amtool_bin}" ]]; then
  if "${amtool_bin}" check-config "${am_conf_dir}/alertmanager.yml" 2>&1; then
    echo "alertmanager.yml 校验通过"
  else
    echo "alertmanager.yml 校验失败"
    exit 1
  fi
fi
