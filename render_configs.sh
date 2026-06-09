#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-}"

# shellcheck source=lib/service_config.sh
source "${SCRIPT_DIR}/lib/service_config.sh"

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
  PROMETHEUS_PORT
  PROMETHEUS_JOB_PREFIX
  METRICS_SERVICES_FILE
  GRAFANA_PORT
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
  SERVICE_DOMAIN
  GRAFANA_SUBPATH
  DASHBOARD_SOURCE_DIR
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "${ENV_FILE} 缺少变量: ${var_name}"
    exit 1
  fi
done

services_file="${METRICS_SERVICES_FILE}"
if [[ "${services_file}" != /* ]]; then
  services_file="${ENV_DIR}/${services_file}"
fi

dashboard_source_dir="${DASHBOARD_SOURCE_DIR}"
if [[ "${dashboard_source_dir}" != /* ]]; then
  dashboard_source_dir="${SCRIPT_DIR}/${dashboard_source_dir}"
fi

if [[ ! -f "${services_file}" ]]; then
  echo "缺少服务列表: ${services_file}"
  exit 1
fi

if [[ ! -d "${dashboard_source_dir}" ]]; then
  echo "缺少 dashboard 目录: ${dashboard_source_dir}"
  exit 1
fi

subpath="${GRAFANA_SUBPATH%/}"
if [[ -z "${subpath}" ]]; then
  subpath="/"
fi

if [[ "${subpath}" == "/" ]]; then
  root_url="http://${SERVICE_DOMAIN}/"
  serve_from_sub_path="false"
  login_path="/login"
else
  root_url="http://${SERVICE_DOMAIN}${subpath}/"
  serve_from_sub_path="true"
  login_path="${subpath}/login"
fi

mkdir -p \
  "${INSTALL_ROOT}/prometheus/conf" \
  "${INSTALL_ROOT}/grafana/conf" \
  "${INSTALL_ROOT}/grafana/provisioning/datasources" \
  "${INSTALL_ROOT}/grafana/provisioning/dashboards" \
  "${INSTALL_ROOT}/grafana/dashboards"

cat > "${INSTALL_ROOT}/prometheus/conf/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
EOF

service_count=0
while IFS=$'\t' read -r service_name metrics_scheme metrics_target metrics_path field5 field6 field7 field8 extra; do
  if [[ -z "${service_name}" || "${service_name}" == \#* ]]; then
    continue
  fi
  normalize_service_metadata "${field5:-}" "${field6:-}" "${field7:-}" "${field8:-}" "${extra:-}"
  validate_service_row \
    "${service_name}" \
    "${metrics_scheme}" \
    "${metrics_target}" \
    "${metrics_path}" \
    "${ROW_PD_GROUP}" \
    "${ROW_PD_ROLE}" \
    "${ROW_PD_INSTANCE}" \
    "${ROW_BACKEND_URL}" \
    "${ROW_EXTRA}"

  write_prometheus_scrape_job \
    "${INSTALL_ROOT}/prometheus/conf/prometheus.yml" \
    "${PROMETHEUS_JOB_PREFIX}" \
    "${service_name}" \
    "${metrics_scheme}" \
    "${metrics_target}" \
    "${metrics_path}" \
    "${ROW_PD_GROUP}" \
    "${ROW_PD_ROLE}" \
    "${ROW_PD_INSTANCE}" \
    "${ROW_BACKEND_URL}"
  service_count=$((service_count + 1))
done < "${services_file}"

if [[ "${service_count}" -eq 0 ]]; then
  echo "服务列表为空: ${services_file}"
  exit 1
fi

if [[ -n "${ALERTMANAGER_TARGET:-}" ]]; then
  cat >> "${INSTALL_ROOT}/prometheus/conf/prometheus.yml" <<EOF

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['${ALERTMANAGER_TARGET}']

rule_files:
  - '${INSTALL_ROOT}/prometheus/rules/*.yml'
EOF
fi

if [[ -n "${PROMETHEUS_RULES_FILE:-}" ]]; then
  mkdir -p "${INSTALL_ROOT}/prometheus/rules"
  cp "${PROMETHEUS_RULES_FILE}" "${INSTALL_ROOT}/prometheus/rules/alerts.yml"
  echo "已复制告警规则: ${PROMETHEUS_RULES_FILE}"
fi

cat > "${INSTALL_ROOT}/grafana/conf/grafana.ini" <<EOF
[paths]
data = ${INSTALL_ROOT}/grafana/data
logs = ${INSTALL_ROOT}/grafana/logs
plugins = ${INSTALL_ROOT}/grafana/plugins
provisioning = ${INSTALL_ROOT}/grafana/provisioning

[server]
http_addr = 0.0.0.0
http_port = ${GRAFANA_PORT}
domain = ${SERVICE_DOMAIN}
root_url = ${root_url}
serve_from_sub_path = ${serve_from_sub_path}
enable_gzip = true

[security]
admin_user = ${GRAFANA_ADMIN_USER}
admin_password = ${GRAFANA_ADMIN_PASSWORD}

[users]
allow_sign_up = false

[analytics]
check_for_updates = false
check_for_plugin_updates = false
reporting_enabled = false

[log]
mode = file
level = info
EOF

cat > "${INSTALL_ROOT}/grafana/provisioning/datasources/prometheus.yaml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:${PROMETHEUS_PORT}
    isDefault: true
    editable: true
EOF

cat > "${INSTALL_ROOT}/grafana/provisioning/dashboards/dashboard.yaml" <<EOF
apiVersion: 1

providers:
  - name: vllm-dashboards
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: ${INSTALL_ROOT}/grafana/dashboards
EOF

rm -f "${INSTALL_ROOT}/grafana/dashboards/"*.json

dashboard_count=0
for src_dashboard in "${dashboard_source_dir}/"*.json; do
  if [[ ! -f "${src_dashboard}" ]]; then
    continue
  fi
  dst_dashboard="${INSTALL_ROOT}/grafana/dashboards/$(basename "${src_dashboard}")"
  sed 's/\${DS_PROMETHEUS}/prometheus/g' "${src_dashboard}" > "${dst_dashboard}"
  dashboard_count=$((dashboard_count + 1))
done

if [[ "${dashboard_count}" -eq 0 ]]; then
  echo "未找到任何 dashboard json: ${dashboard_source_dir}"
  exit 1
fi

echo "配置已生成。"
echo "服务数量: ${service_count}"
echo "Grafana 本机登录页: http://127.0.0.1:${GRAFANA_PORT}${login_path}"
echo "已同步 dashboard 数量: ${dashboard_count}"
