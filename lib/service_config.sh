#!/usr/bin/env bash

service_config_die() {
  if declare -F die >/dev/null 2>&1; then
    die "$*"
  fi
  echo "$*" >&2
  exit 1
}

service_config_validate_simple_name() {
  local key="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    service_config_die "${key} 只能用字母、数字、下划线、短横线: ${value}"
  fi
}

service_config_validate_pd_role() {
  local role="$1"
  case "${role}" in
    prefill|decode|router) ;;
    *) service_config_die "pd_role 只能是 prefill、decode 或 router: ${role}" ;;
  esac
}

service_config_validate_label_value() {
  local key="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    service_config_die "${key} 不能为空"
  fi
  if [[ "${value}" == *"'"* || "${value}" == *$'\t'* || "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    service_config_die "${key} 不能包含单引号、tab 或换行"
  fi
}

parse_metrics_url() {
  local key="$1"
  local url="$2"

  if [[ "${url}" == *"'"* || "${url}" == *$'\t'* || "${url}" == *" "* || "${url}" == *$'\n'* || "${url}" == *$'\r'* ]]; then
    service_config_die "${key} 不能包含空格、单引号、tab 或换行: ${url}"
  fi
  if [[ "${url}" == *"?"* ]]; then
    service_config_die "${key} 不能包含 query 参数；proxy backend 必须单独传: ${url}"
  fi
  if [[ ! "${url}" =~ ^(https?)://([^/?#]+)(/[^?#]*)$ ]]; then
    service_config_die "${key} 必须是完整 http/https URL，且包含 path: ${url}"
  fi

  PARSED_SCHEME="${BASH_REMATCH[1]}"
  PARSED_TARGET="${BASH_REMATCH[2]}"
  PARSED_PATH="${BASH_REMATCH[3]}"
}

validate_backend_url() {
  local backend_url="$1"
  if [[ "${backend_url}" == *"'"* || "${backend_url}" == *$'\t'* || "${backend_url}" == *" "* || "${backend_url}" == *$'\n'* || "${backend_url}" == *$'\r'* ]]; then
    service_config_die "backend_url 不能包含空格、单引号、tab 或换行: ${backend_url}"
  fi
  if [[ ! "${backend_url}" =~ ^https?://[^/?#]+(/[^?#]*)?$ ]]; then
    service_config_die "backend_url 必须是完整 http/https URL: ${backend_url}"
  fi
}

validate_service_target() {
  local service_name="$1"
  local metrics_scheme="$2"
  local metrics_target="$3"
  local metrics_path="$4"

  service_config_validate_simple_name "service_name" "${service_name}"
  if [[ "${metrics_scheme}" != "http" && "${metrics_scheme}" != "https" ]]; then
    service_config_die "${service_name} 的 scheme 只能是 http 或 https"
  fi
  if [[ "${metrics_target}" == *"'"* || "${metrics_target}" == *" "* || "${metrics_target}" == *$'\t'* || -z "${metrics_target}" ]]; then
    service_config_die "${service_name} 的 target 不能为空，且不能包含空格、tab 或单引号"
  fi
  if [[ "${metrics_path}" != /* || "${metrics_path}" == *"'"* || "${metrics_path}" == *" "* || "${metrics_path}" == *$'\t'* ]]; then
    service_config_die "${service_name} 的 metrics_path 必须以 / 开头，且不能包含空格、tab 或单引号"
  fi
}

validate_service_row() {
  local service_name="$1"
  local metrics_scheme="$2"
  local metrics_target="$3"
  local metrics_path="$4"
  local pd_group="${5:-}"
  local pd_role="${6:-}"
  local pd_instance="${7:-}"
  local backend_url="${8:-}"
  local extra="${9:-}"

  if [[ -n "${extra}" ]]; then
    service_config_die "服务列表字段过多，必须是 4、5、7 或 8 列: ${service_name}"
  fi

  validate_service_target "${service_name}" "${metrics_scheme}" "${metrics_target}" "${metrics_path}"

  if [[ -z "${pd_group}${pd_role}${pd_instance}${backend_url}" ]]; then
    return 0
  fi

  if [[ -z "${pd_group}${pd_role}${pd_instance}" ]]; then
    validate_backend_url "${backend_url}"
    return 0
  fi

  if [[ -z "${pd_group}" || -z "${pd_role}" || -z "${pd_instance}" ]]; then
    service_config_die "PD 服务行必须包含 pd_group、pd_role、pd_instance: ${service_name}"
  fi
  service_config_validate_label_value "pd_group" "${pd_group}"
  service_config_validate_pd_role "${pd_role}"
  service_config_validate_label_value "pd_instance" "${pd_instance}"
  if [[ "${metrics_path}" != *"/metrics"* ]]; then
    service_config_die "PD 服务 metrics_path 必须包含 /metrics: ${service_name}"
  fi
  if [[ "${metrics_path}" == *"?"* ]]; then
    service_config_die "PD 服务 metrics_path 不能包含 query 参数；proxy backend 必须放在 backend_url 列: ${service_name}"
  fi

  if [[ -n "${backend_url}" ]]; then
    validate_backend_url "${backend_url}"
  fi
}

normalize_service_metadata() {
  local field5="${1:-}"
  local field6="${2:-}"
  local field7="${3:-}"
  local field8="${4:-}"
  local extra="${5:-}"

  ROW_PD_GROUP="${field5}"
  ROW_PD_ROLE="${field6}"
  ROW_PD_INSTANCE="${field7}"
  ROW_BACKEND_URL="${field8}"
  ROW_EXTRA="${extra}"

  if [[ -n "${field5}" && -z "${field6}${field7}${field8}" && "${field5}" =~ ^https?:// ]]; then
    ROW_PD_GROUP=""
    ROW_PD_ROLE=""
    ROW_PD_INSTANCE=""
    ROW_BACKEND_URL="${field5}"
  fi
}

service_target_url() {
  local metrics_scheme="$1"
  local metrics_target="$2"
  local metrics_path="$3"
  local backend_url="${4:-}"

  if [[ -n "${backend_url}" ]]; then
    printf '%s://%s%s?_backend=%s\n' "${metrics_scheme}" "${metrics_target}" "${metrics_path}" "${backend_url}"
  else
    printf '%s://%s%s\n' "${metrics_scheme}" "${metrics_target}" "${metrics_path}"
  fi
}

write_prometheus_scrape_job() {
  local output_file="$1"
  local job_prefix="$2"
  local service_name="$3"
  local metrics_scheme="$4"
  local metrics_target="$5"
  local metrics_path="$6"
  local pd_group="${7:-}"
  local pd_role="${8:-}"
  local pd_instance="${9:-}"
  local backend_url="${10:-}"

  {
    cat <<EOF
  - job_name: '${job_prefix}-${service_name}'
    scheme: '${metrics_scheme}'
    metrics_path: '${metrics_path}'
EOF
    if [[ -n "${backend_url}" ]]; then
      cat <<EOF
    params:
      _backend: ['${backend_url}']
EOF
    fi
    cat <<EOF
    static_configs:
      - targets: ['${metrics_target}']
        labels:
          service: '${service_name}'
EOF
    if [[ -n "${pd_group}" ]]; then
      cat <<EOF
          pd_group: '${pd_group}'
          pd_role: '${pd_role}'
          pd_instance: '${pd_instance}'
EOF
    fi
  } >> "${output_file}"
}
