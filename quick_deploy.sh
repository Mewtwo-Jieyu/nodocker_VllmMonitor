#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE="${SCRIPT_DIR}/env.example"
ENV_FILE="${ENV_FILE:-}"

# shellcheck source=lib/service_config.sh
source "${SCRIPT_DIR}/lib/service_config.sh"

usage() {
  cat <<'EOF'
用法:
  bash quick_deploy.sh \
    --install-root <当前监控实例独立安装目录> \
    --env-file env.<monitor>.local \
    --service-domain <当前监控实例平台域名> \
    --admin-password <Grafana密码> \
    --metrics-service <服务名> <http|https> <指标域名> </metrics> \
    [--metrics-service <服务名> <http|https> <指标域名> </metrics>] \
    [--metrics-proxy-service <服务名> <完整proxy_metrics_url> <backend_url>] \
    [--pd-service <pd_group> <prefill|decode|router> <服务名> <完整metrics_url>] \
    [--pd-proxy-service <pd_group> <prefill|decode|router> <服务名> <完整proxy_metrics_url> <backend_url>] \
    [--services-file services.<monitor>.tsv] \
    [--grafana-subpath /grafana] \
    [--admin-user admin] \
    [--prometheus-job-prefix vllm] \
    [--prometheus-port 9090] \
    [--grafana-port 3000] \
    [--offline-bundle-dir dist] \
    [--allow-download false]

例子:
  bash quick_deploy.sh \
    --install-root /opt/vllm-monitor \
    --env-file env.qwen-kimi.local \
    --service-domain monitor.example.com \
    --admin-password 'change-this-password' \
    --metrics-service qwen35 http qwen-metrics.example.com /metrics \
    --metrics-service kimi25 http kimi-metrics.example.com /metrics

  bash quick_deploy.sh \
    --install-root /opt/vllm-monitor-proxy \
    --env-file env.proxy.local \
    --service-domain monitor.example.com \
    --admin-password 'change-this-password' \
    --metrics-proxy-service qwen3-opd http://10.140.158.149:8133/metrics http://10.119.1.215:8000

  bash quick_deploy.sh \
    --install-root /opt/vllm-monitor-pd \
    --env-file env.glm5-pd.local \
    --service-domain monitor.example.com \
    --admin-password 'change-this-password' \
    --pd-service GLM-5-w8a8 prefill glm5-p-79-7100 http://10.119.11.79:7100/metrics \
    --pd-proxy-service GLM-5-w8a8 decode glm5-d-83-7100 http://10.140.158.149:8133/metrics http://10.119.11.83:7100
EOF
}

require_value() {
  local key="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "缺少参数: ${key}"
    usage
    exit 1
  fi
}

derive_services_file() {
  local env_path="$1"
  local env_base
  env_base="$(basename "${env_path}")"
  if [[ "${env_base}" == env.*.local ]]; then
    echo "services.${env_base#env.}" | sed 's/\.local$/.tsv/'
  else
    echo "services.generated.tsv"
  fi
}

write_env_file() {
  local output="$1"
  local tmp="${output}.tmp"
  local key

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" || "${line}" != *=* ]]; then
      printf '%s\n' "${line}" >> "${tmp}"
      continue
    fi

    key="${line%%=*}"
    case "${key}" in
      INSTALL_ROOT) printf '%s=%q\n' "${key}" "${INSTALL_ROOT}" >> "${tmp}" ;;
      PROMETHEUS_PORT) printf '%s=%q\n' "${key}" "${PROMETHEUS_PORT}" >> "${tmp}" ;;
      PROMETHEUS_JOB_PREFIX) printf '%s=%q\n' "${key}" "${PROMETHEUS_JOB_PREFIX}" >> "${tmp}" ;;
      METRICS_SERVICES_FILE) printf '%s=%q\n' "${key}" "${SERVICES_FILE_VALUE}" >> "${tmp}" ;;
      OFFLINE_BUNDLE_DIR) printf '%s=%q\n' "${key}" "${OFFLINE_BUNDLE_DIR}" >> "${tmp}" ;;
      ALLOW_DOWNLOAD) printf '%s=%q\n' "${key}" "${ALLOW_DOWNLOAD}" >> "${tmp}" ;;
      GRAFANA_PORT) printf '%s=%q\n' "${key}" "${GRAFANA_PORT}" >> "${tmp}" ;;
      GRAFANA_ADMIN_USER) printf '%s=%q\n' "${key}" "${GRAFANA_ADMIN_USER}" >> "${tmp}" ;;
      GRAFANA_ADMIN_PASSWORD) printf '%s=%q\n' "${key}" "${GRAFANA_ADMIN_PASSWORD}" >> "${tmp}" ;;
      SERVICE_DOMAIN) printf '%s=%q\n' "${key}" "${SERVICE_DOMAIN}" >> "${tmp}" ;;
      GRAFANA_SUBPATH) printf '%s=%q\n' "${key}" "${GRAFANA_SUBPATH}" >> "${tmp}" ;;
      *) printf '%s\n' "${line}" >> "${tmp}" ;;
    esac
  done < "${ENV_EXAMPLE}"

  mv "${tmp}" "${output}"
}

add_metrics_service() {
  local service_name="$1"
  local metrics_scheme="$2"
  local metrics_target="$3"
  local metrics_path="$4"

  validate_service_row "${service_name}" "${metrics_scheme}" "${metrics_target}" "${metrics_path}"
  SERVICE_LINES+=("${service_name}"$'\t'"${metrics_scheme}"$'\t'"${metrics_target}"$'\t'"${metrics_path}")
}

add_metrics_proxy_service() {
  local service_name="$1"
  local proxy_metrics_url="$2"
  local backend_url="$3"

  parse_metrics_url "--metrics-proxy-service <proxy_metrics_url>" "${proxy_metrics_url}"
  validate_backend_url "${backend_url}"
  validate_service_row "${service_name}" "${PARSED_SCHEME}" "${PARSED_TARGET}" "${PARSED_PATH}" "" "" "" "${backend_url}"
  SERVICE_LINES+=("${service_name}"$'\t'"${PARSED_SCHEME}"$'\t'"${PARSED_TARGET}"$'\t'"${PARSED_PATH}"$'\t'"${backend_url}")
}

add_pd_service() {
  local pd_group="$1"
  local pd_role="$2"
  local service_name="$3"
  local metrics_url="$4"

  parse_metrics_url "--pd-service <metrics_url>" "${metrics_url}"
  validate_service_row "${service_name}" "${PARSED_SCHEME}" "${PARSED_TARGET}" "${PARSED_PATH}" "${pd_group}" "${pd_role}" "${service_name}"
  SERVICE_LINES+=("${service_name}"$'\t'"${PARSED_SCHEME}"$'\t'"${PARSED_TARGET}"$'\t'"${PARSED_PATH}"$'\t'"${pd_group}"$'\t'"${pd_role}"$'\t'"${service_name}")
}

add_pd_proxy_service() {
  local pd_group="$1"
  local pd_role="$2"
  local service_name="$3"
  local proxy_metrics_url="$4"
  local backend_url="$5"

  parse_metrics_url "--pd-proxy-service <proxy_metrics_url>" "${proxy_metrics_url}"
  validate_backend_url "${backend_url}"
  validate_service_row "${service_name}" "${PARSED_SCHEME}" "${PARSED_TARGET}" "${PARSED_PATH}" "${pd_group}" "${pd_role}" "${service_name}" "${backend_url}"
  SERVICE_LINES+=("${service_name}"$'\t'"${PARSED_SCHEME}"$'\t'"${PARSED_TARGET}"$'\t'"${PARSED_PATH}"$'\t'"${pd_group}"$'\t'"${pd_role}"$'\t'"${service_name}"$'\t'"${backend_url}")
}

INSTALL_ROOT=""
SERVICES_FILE=""
SERVICES_FILE_VALUE=""
GRAFANA_SUBPATH="/grafana"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD=""
SERVICE_DOMAIN=""
PROMETHEUS_JOB_PREFIX="vllm"
PROMETHEUS_PORT="9090"
GRAFANA_PORT="3000"
OFFLINE_BUNDLE_DIR="dist"
ALLOW_DOWNLOAD="false"
SERVICE_LINES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --services-file)
      SERVICES_FILE="${2:-}"
      shift 2
      ;;
    --service-domain)
      SERVICE_DOMAIN="${2:-}"
      shift 2
      ;;
    --admin-password)
      GRAFANA_ADMIN_PASSWORD="${2:-}"
      shift 2
      ;;
    --install-root)
      INSTALL_ROOT="${2:-}"
      shift 2
      ;;
    --grafana-subpath)
      GRAFANA_SUBPATH="${2:-}"
      shift 2
      ;;
    --admin-user)
      GRAFANA_ADMIN_USER="${2:-}"
      shift 2
      ;;
    --prometheus-job-prefix)
      PROMETHEUS_JOB_PREFIX="${2:-}"
      shift 2
      ;;
    --prometheus-port)
      PROMETHEUS_PORT="${2:-}"
      shift 2
      ;;
    --grafana-port)
      GRAFANA_PORT="${2:-}"
      shift 2
      ;;
    --offline-bundle-dir)
      OFFLINE_BUNDLE_DIR="${2:-}"
      shift 2
      ;;
    --allow-download)
      ALLOW_DOWNLOAD="${2:-}"
      shift 2
      ;;
    --metrics-service)
      require_value "--metrics-service <服务名>" "${2:-}"
      require_value "--metrics-service <scheme>" "${3:-}"
      require_value "--metrics-service <target>" "${4:-}"
      require_value "--metrics-service <path>" "${5:-}"
      add_metrics_service "$2" "$3" "$4" "$5"
      shift 5
      ;;
    --metrics-proxy-service)
      require_value "--metrics-proxy-service <服务名>" "${2:-}"
      require_value "--metrics-proxy-service <proxy_metrics_url>" "${3:-}"
      require_value "--metrics-proxy-service <backend_url>" "${4:-}"
      add_metrics_proxy_service "$2" "$3" "$4"
      shift 4
      ;;
    --pd-service)
      require_value "--pd-service <pd_group>" "${2:-}"
      require_value "--pd-service <prefill|decode|router>" "${3:-}"
      require_value "--pd-service <服务名>" "${4:-}"
      require_value "--pd-service <metrics_url>" "${5:-}"
      add_pd_service "$2" "$3" "$4" "$5"
      shift 5
      ;;
    --pd-proxy-service)
      require_value "--pd-proxy-service <pd_group>" "${2:-}"
      require_value "--pd-proxy-service <prefill|decode|router>" "${3:-}"
      require_value "--pd-proxy-service <服务名>" "${4:-}"
      require_value "--pd-proxy-service <proxy_metrics_url>" "${5:-}"
      require_value "--pd-proxy-service <backend_url>" "${6:-}"
      add_pd_proxy_service "$2" "$3" "$4" "$5" "$6"
      shift 6
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

require_value "--install-root" "${INSTALL_ROOT}"
require_value "--env-file" "${ENV_FILE}"
require_value "--service-domain" "${SERVICE_DOMAIN}"
require_value "--admin-password" "${GRAFANA_ADMIN_PASSWORD}"

if [[ "${#SERVICE_LINES[@]}" -eq 0 ]]; then
  echo "至少传一个 --metrics-service / --metrics-proxy-service / --pd-service / --pd-proxy-service"
  usage
  exit 1
fi

if [[ "${ALLOW_DOWNLOAD}" != "true" && "${ALLOW_DOWNLOAD}" != "false" ]]; then
  echo "--allow-download 只能是 true 或 false"
  exit 1
fi

if [[ ! -f "${ENV_EXAMPLE}" ]]; then
  echo "缺少 ${ENV_EXAMPLE}"
  exit 1
fi

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
fi

if [[ -z "${SERVICES_FILE}" ]]; then
  SERVICES_FILE="$(derive_services_file "${ENV_FILE}")"
fi

if [[ "${SERVICES_FILE}" != /* ]]; then
  SERVICES_FILE_VALUE="${SERVICES_FILE}"
  SERVICES_FILE="${SCRIPT_DIR}/${SERVICES_FILE}"
else
  SERVICES_FILE_VALUE="${SERVICES_FILE}"
fi

rm -f "${ENV_FILE}.tmp"
write_env_file "${ENV_FILE}"

{
  printf '# service_name\tscheme\ttarget\tmetrics_path\tpd_group\tpd_role\tpd_instance\tbackend_url\n'
  for service_line in "${SERVICE_LINES[@]}"; do
    printf '%s\n' "${service_line}"
  done
} > "${SERVICES_FILE}"

echo "已生成 ${ENV_FILE}"
echo "已生成 ${SERVICES_FILE}"
echo "INSTALL_ROOT=${INSTALL_ROOT}"
echo "SERVICE_DOMAIN=${SERVICE_DOMAIN}"
echo "METRICS_SERVICES_FILE=${SERVICES_FILE_VALUE}"
echo "服务数量=${#SERVICE_LINES[@]}"

bash "${SCRIPT_DIR}/deploy.sh" --env-file "${ENV_FILE}"
