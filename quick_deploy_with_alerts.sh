#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_DIR="$(cd "${SCRIPT_DIR}/alertmanager_feishu" && pwd)"
ENV_EXAMPLE="${SCRIPT_DIR}/env.example"

# shellcheck source=lib/service_config.sh
source "${SCRIPT_DIR}/lib/service_config.sh"

usage() {
  cat <<'EOF'
用法:
  # 部署 Prometheus + Grafana，不启用飞书告警
  bash quick_deploy_with_alerts.sh deploy \
    --install-root /opt/vllm-monitor-demo \
    --env-file env.multi-test.local \
    --service-domain monitor.example.com \
    --admin-password admin \
    --metrics-service kimi25 http kimi-metrics.example.com /metrics

  # 部署普通服务；metrics 经代理入口访问 backend
  bash quick_deploy_with_alerts.sh deploy \
    --install-root /opt/vllm-monitor-proxy \
    --env-file env.proxy.local \
    --service-domain monitor.example.com \
    --admin-password admin \
    --metrics-proxy-service qwen3-opd http://10.140.158.149:8133/metrics http://10.119.1.215:8000

  # 部署 PD 分离服务；direct 和 proxy 可以混用
  bash quick_deploy_with_alerts.sh deploy \
    --install-root /opt/vllm-monitor-pd \
    --env-file env.glm5-pd.local \
    --service-domain monitor.example.com \
    --admin-password admin \
    --pd-service GLM-5-w8a8 prefill glm5-p-79-7100 http://10.119.11.79:7100/metrics \
    --pd-proxy-service GLM-5-w8a8 decode glm5-d-83-7100 http://10.140.158.149:8133/metrics http://10.119.11.83:7100

  # 部署 Prometheus + Grafana + Alertmanager + Feishu relay
  bash quick_deploy_with_alerts.sh deploy \
    --install-root /opt/vllm-monitor-demo \
    --env-file env.multi-test.local \
    --service-domain monitor.example.com \
    --admin-password admin \
    --metrics-service kimi25 http kimi-metrics.example.com /metrics \
    --service-id kimi25 'h200 kimi' \
    --enable-alerts true \
    --feishu-webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/xxx' \
    --proxy-setup-url 'http://proxy.example.com/setup_proxy.sh'

  # 检查监控；如果 env 里启用了告警，也检查告警链路
  bash quick_deploy_with_alerts.sh check --env-file env.multi-test.local --send-test

deploy 参数:
  --install-root              当前监控实例独立安装目录
  --env-file                  生成的监控 env 文件
  --service-domain            当前监控实例平台域名
  --admin-password            Grafana 密码
  --metrics-service           服务名 + http|https + 指标域名 + metrics_path；可重复
  --metrics-proxy-service     服务名 + 完整 proxy_metrics_url + backend_url；可重复
  --pd-service                pd_group + prefill|decode|router + 服务名 + 完整 metrics_url；可重复
  --pd-proxy-service          pd_group + prefill|decode|router + 服务名 + 完整 proxy_metrics_url + backend_url；可重复
  --service-id                服务名 + 手动显示 ID；可重复，例如 '华为a3 kimi'
  --target-down-for           服务名 + TargetDown 判定时间；可重复，例如 qwen3 5m
  --enable-alerts             true 或 false，默认 false
  --feishu-webhook            启用告警时必填
  --proxy-setup-url           可选；Feishu 出网需要代理时填写
  --services-file             可选；默认按 env 文件名生成
  --grafana-subpath           可选；默认 /grafana
  --admin-user                可选；默认 admin
  --prometheus-job-prefix     可选；默认 vllm
  --prometheus-port           可选；默认 9090
  --grafana-port              可选；默认 3000
  --alertmanager-port         可选；默认 19093
  --feishu-relay-port         可选；默认 19094
  --offline-bundle-dir        可选；默认 dist
  --allow-download            可选；默认 false

check 参数:
  --env-file                  监控 env 文件
  --send-test                 发送飞书测试消息
  --route                     飞书测试路由，默认 default
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

require_value() {
  local key="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    usage
    die "缺少参数: ${key}"
  fi
}

resolve_env_file() {
  local env_path="$1"
  if [[ "${env_path}" == /* ]]; then
    printf '%s\n' "${env_path}"
  else
    printf '%s/%s\n' "${SCRIPT_DIR}" "${env_path}"
  fi
}

derive_env_key() {
  local env_path="$1"
  local env_base key
  env_base="$(basename "${env_path}")"
  if [[ "${env_base}" == env.*.local ]]; then
    key="${env_base#env.}"
    printf '%s\n' "${key%.local}"
  else
    printf '%s\n' "generated"
  fi
}

validate_bool() {
  local key="$1"
  local value="$2"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    die "${key} 只能是 true 或 false"
  fi
}

validate_simple_name() {
  local key="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "${key} 只能用字母、数字、下划线、短横线: ${value}"
  fi
}

validate_service_id() {
  local service_name="$1"
  local service_id="$2"

  validate_simple_name "--service-id <服务名>" "${service_name}"
  if [[ -z "${service_id}" ]]; then
    die "--service-id ${service_name} 缺少显示 ID"
  fi
  if [[ "${service_id}" == *$'\t'* || "${service_id}" == *$'\n'* || "${service_id}" == *$'\r'* ]]; then
    die "--service-id ${service_name} 不能包含 tab 或换行"
  fi
}

validate_alert_duration() {
  local key="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*(ms|s|m|h|d|w|y)$ ]]; then
    die "${key} 必须是 Prometheus 时间格式，例如 30s、2m、5m、1h: ${value}"
  fi
}

service_exists() {
  local wanted="$1"
  local service_line service_name rest

  for service_line in "${SERVICE_LINES[@]}"; do
    service_name="${service_line%%$'\t'*}"
    rest="${service_line#*$'\t'}"
    if [[ "${service_name}" == "${wanted}" && "${rest}" != "${service_line}" ]]; then
      return 0
    fi
  done
  return 1
}

add_service_id() {
  local service_name="$1"
  local service_id="$2"
  local index

  validate_service_id "${service_name}" "${service_id}"
  index=0
  while [[ "${index}" -lt "${#SERVICE_ID_NAMES[@]}" ]]; do
    if [[ "${SERVICE_ID_NAMES[${index}]}" == "${service_name}" ]]; then
      die "--service-id 重复: ${service_name}"
    fi
    index=$((index + 1))
  done

  SERVICE_ID_NAMES+=("${service_name}")
  SERVICE_ID_VALUES+=("${service_id}")
}

add_target_down_for() {
  local service_name="$1"
  local duration="$2"
  local index

  validate_simple_name "--target-down-for <服务名>" "${service_name}"
  validate_alert_duration "--target-down-for ${service_name}" "${duration}"
  index=0
  while [[ "${index}" -lt "${#TARGET_DOWN_FOR_NAMES[@]}" ]]; do
    if [[ "${TARGET_DOWN_FOR_NAMES[${index}]}" == "${service_name}" ]]; then
      die "--target-down-for 重复: ${service_name}"
    fi
    index=$((index + 1))
  done

  TARGET_DOWN_FOR_NAMES+=("${service_name}")
  TARGET_DOWN_FOR_VALUES+=("${duration}")
}

validate_service_ids_match_services() {
  local index service_name

  index=0
  while [[ "${index}" -lt "${#SERVICE_ID_NAMES[@]}" ]]; do
    service_name="${SERVICE_ID_NAMES[${index}]}"
    if ! service_exists "${service_name}"; then
      die "--service-id 指向了不存在的服务: ${service_name}"
    fi
    index=$((index + 1))
  done
}

validate_target_down_for_match_services() {
  local index service_name

  index=0
  while [[ "${index}" -lt "${#TARGET_DOWN_FOR_NAMES[@]}" ]]; do
    service_name="${TARGET_DOWN_FOR_NAMES[${index}]}"
    if ! service_exists "${service_name}"; then
      die "--target-down-for 指向了不存在的服务: ${service_name}"
    fi
    index=$((index + 1))
  done
}

ensure_no_proxy() {
  local current
  current="${no_proxy:-${NO_PROXY:-}}"
  case ",${current}," in
    *,127.0.0.1,*) ;;
    *) current="127.0.0.1,localhost,${current}" ;;
  esac
  export no_proxy="${current}"
  export NO_PROXY="${current}"
}

apply_proxy_if_configured() {
  local proxy_setup_url="$1"
  local proxy_tmp proxy_status

  if [[ -z "${proxy_setup_url}" ]]; then
    ensure_no_proxy
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    die "配置了 --proxy-setup-url，但系统缺少 curl"
  fi

  proxy_tmp="$(mktemp "${TMPDIR:-/tmp}/feishu-proxy.XXXXXX")"
  if ! curl -fsSL "${proxy_setup_url}" -o "${proxy_tmp}"; then
    rm -f "${proxy_tmp}"
    die "下载代理脚本失败: ${proxy_setup_url}"
  fi

  set +e +u
  # shellcheck source=/dev/null
  source "${proxy_tmp}"
  proxy_status=$?
  set -euo pipefail
  rm -f "${proxy_tmp}"

  if [[ "${proxy_status}" -ne 0 ]]; then
    die "加载代理脚本失败: ${proxy_setup_url}"
  fi

  ensure_no_proxy
}

write_monitor_env() {
  local output="$1"
  local tmp="${output}.tmp"
  local key line wrote_alertmanager_target wrote_prometheus_rules_file

  wrote_alertmanager_target=false
  wrote_prometheus_rules_file=false

  rm -f "${tmp}"
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
      ALERTMANAGER_TARGET)
        wrote_alertmanager_target=true
        printf '%s=%q\n' "${key}" "${ALERTMANAGER_TARGET}" >> "${tmp}" ;;
      PROMETHEUS_RULES_FILE)
        wrote_prometheus_rules_file=true
        printf '%s=%q\n' "${key}" "${PROMETHEUS_RULES_FILE}" >> "${tmp}" ;;
      *) printf '%s\n' "${line}" >> "${tmp}" ;;
    esac
  done < "${ENV_EXAMPLE}"

  {
    echo
    if [[ "${wrote_alertmanager_target}" != "true" ]]; then
      printf '%s=%q\n' ALERTMANAGER_TARGET "${ALERTMANAGER_TARGET}"
    fi
    if [[ "${wrote_prometheus_rules_file}" != "true" ]]; then
      printf '%s=%q\n' PROMETHEUS_RULES_FILE "${PROMETHEUS_RULES_FILE}"
    fi
    printf '%s=%q\n' ALERTS_ENABLED "${ENABLE_ALERTS}"
    printf '%s=%q\n' ALERTMANAGER_ENV_FILE "${ALERT_ENV_FILE}"
    printf '%s=%q\n' ALERTMANAGER_INSTALL_ROOT "${ALERT_INSTALL_ROOT}"
    printf '%s=%q\n' FEISHU_PROXY_SETUP_URL "${PROXY_SETUP_URL}"
    printf '%s=%q\n' FEISHU_RELAY_PORT "${FEISHU_RELAY_PORT}"
  } >> "${tmp}"

  mv "${tmp}" "${output}"
}

write_services_file() {
  {
    printf '# service_name\tscheme\ttarget\tmetrics_path\tpd_group\tpd_role\tpd_instance\tbackend_url\n'
    for service_line in "${SERVICE_LINES[@]}"; do
      printf '%s\n' "${service_line}"
    done
  } > "${SERVICES_FILE}"
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

write_service_ids_file() {
  local index

  if [[ "${#SERVICE_ID_NAMES[@]}" -eq 0 || -z "${SERVICE_IDS_FILE}" ]]; then
    return 0
  fi

  {
    printf '# service_name\tdisplay_id\n'
    index=0
    while [[ "${index}" -lt "${#SERVICE_ID_NAMES[@]}" ]]; do
      printf '%s\t%s\n' "${SERVICE_ID_NAMES[${index}]}" "${SERVICE_ID_VALUES[${index}]}"
      index=$((index + 1))
    done
  } > "${SERVICE_IDS_FILE}"
}

append_alert_env_service_ids_file() {
  if [[ "${#SERVICE_ID_NAMES[@]}" -eq 0 || -z "${SERVICE_IDS_FILE}" ]]; then
    return 0
  fi
  printf '%s=%q\n' FEISHU_SERVICE_IDS_FILE "${SERVICE_IDS_FILE}" >> "${ALERT_ENV_FILE}"
}

target_down_exclusion_matcher() {
  local index regex service_name

  if [[ "${#TARGET_DOWN_FOR_NAMES[@]}" -eq 0 ]]; then
    return 0
  fi

  regex=""
  index=0
  while [[ "${index}" -lt "${#TARGET_DOWN_FOR_NAMES[@]}" ]]; do
    service_name="${TARGET_DOWN_FOR_NAMES[${index}]}"
    if [[ -n "${regex}" ]]; then
      regex="${regex}|"
    fi
    regex="${regex}${service_name}"
    index=$((index + 1))
  done

  printf ',service!~"^(%s)$"' "${regex}"
}

write_target_down_alert_rules() {
  local matcher index service_name duration

  matcher="$(target_down_exclusion_matcher)"
  cat <<EOF
  - alert: VLLMTargetDown
    expr: up{job=~"${PROMETHEUS_JOB_PREFIX}-.*"${matcher}} == 0
    for: 2m
    labels:
      severity: critical
      target_down_scope: default
    annotations:
      summary: "vLLM metrics 抓取失败"
      description: "ALERT 监控机抓取服务 {{ \$labels.service }} 的 /metrics 失败超过 2 分钟，不等同于 /v1/chat/completions 必然不可用"
EOF

  index=0
  while [[ "${index}" -lt "${#TARGET_DOWN_FOR_NAMES[@]}" ]]; do
    service_name="${TARGET_DOWN_FOR_NAMES[${index}]}"
    duration="${TARGET_DOWN_FOR_VALUES[${index}]}"
    cat <<EOF

  - alert: VLLMTargetDown
    expr: up{job=~"${PROMETHEUS_JOB_PREFIX}-.*",service="${service_name}"} == 0
    for: ${duration}
    labels:
      severity: critical
      target_down_scope: ${service_name}
    annotations:
      summary: "vLLM metrics 抓取失败"
      description: "ALERT 监控机抓取服务 {{ \$labels.service }} 的 /metrics 失败超过 ${duration}，不等同于 /v1/chat/completions 必然不可用"
EOF
    index=$((index + 1))
  done
}

write_vllm_rules_file() {
  cat > "${RULES_FILE}" <<EOF
groups:
- name: simucraft-vllm-recording
  rules:
  - record: simucraft:vllm_request_error_rate:ratio5m
    expr: |
      sum by(service) (
        rate(vllm:request_success_total{job=~"${PROMETHEUS_JOB_PREFIX}-.*",finished_reason!~"stop|length"}[5m])
      )
      /
      clamp_min(
        sum by(service) (
          rate(vllm:request_success_total{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
        ),
        0.001
      )

  - record: simucraft:vllm_avg_tpot_seconds:ratio5m
    expr: |
      (
        sum by(service) (
          rate(vllm:request_time_per_output_token_seconds_sum{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
        )
        /
        clamp_min(
          sum by(service) (
            rate(vllm:request_time_per_output_token_seconds_count{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
          ),
          0.001
        )
      )
      or on(service)
      (
        sum by(service) (
          rate(vllm:time_per_output_token_seconds_sum{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
        )
        /
        clamp_min(
          sum by(service) (
            rate(vllm:time_per_output_token_seconds_count{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
          ),
          0.001
        )
      )

  - record: simucraft:vllm_queue_latency_avg_seconds:ratio5m
    expr: |
      sum by(service) (
        rate(vllm:request_queue_time_seconds_sum{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
      )
      /
      clamp_min(
        sum by(service) (
          rate(vllm:request_queue_time_seconds_count{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
        ),
        0.001
      )

  - record: simucraft:vllm_waiting_requests:avg5m
    expr: |
      avg by(service) (
        avg_over_time(vllm:num_requests_waiting{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
      )

  - record: simucraft:vllm_prefix_cache_hit_rate:ratio5m
    expr: |
      sum by(service) (
        rate(vllm:prefix_cache_hits_total{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
      )
      /
      clamp_min(
        sum by(service) (
          rate(vllm:prefix_cache_queries_total{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
        ),
        1
      )

  - record: simucraft:vllm_prefix_cache_queries:rate5m
    expr: |
      sum by(service) (
        rate(vllm:prefix_cache_queries_total{job=~"${PROMETHEUS_JOB_PREFIX}-.*"}[5m])
      )

- name: simucraft-vllm-alerts
  rules:
EOF
  write_target_down_alert_rules >> "${RULES_FILE}"
  cat >> "${RULES_FILE}" <<EOF

  - alert: VLLMHighErrorRateWarning
    expr: simucraft:vllm_request_error_rate:ratio5m > 0.01
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "vLLM 请求失败率超过 1%"
      description: "ALERT 服务 {{ \$labels.service }} 最近 5 分钟请求失败率为 {{ \$value | humanizePercentage }}"

  - alert: VLLMHighErrorRateCritical
    expr: simucraft:vllm_request_error_rate:ratio5m > 0.05
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "vLLM 请求失败率超过 5%"
      description: "ALERT 服务 {{ \$labels.service }} 最近 5 分钟请求失败率为 {{ \$value | humanizePercentage }}"

  # Low-traffic services make historical spike rules noisy. Keep the rule text
  # here for later recovery, but do not load these alerts into Prometheus.
  # - alert: VLLMAvgTPOTSpikeWarning
  #   expr: |
  #     simucraft:vllm_avg_tpot_seconds:ratio5m
  #     > 2 * avg_over_time(simucraft:vllm_avg_tpot_seconds:ratio5m[1h])
  #   for: 5m
  #   labels:
  #     severity: warning
  #   annotations:
  #     summary: "vLLM avg TPOT 超过历史基线 2 倍"
  #     description: "ALERT 服务 {{ \$labels.service }} avg TPOT 当前值 {{ \$value }}s，超过过去 1h 平均值 2 倍"

  # - alert: VLLMAvgTPOTSpikeCritical
  #   expr: |
  #     simucraft:vllm_avg_tpot_seconds:ratio5m
  #     > 3 * avg_over_time(simucraft:vllm_avg_tpot_seconds:ratio5m[1h])
  #   for: 5m
  #   labels:
  #     severity: critical
  #   annotations:
  #     summary: "vLLM avg TPOT 超过历史基线 3 倍"
  #     description: "ALERT 服务 {{ \$labels.service }} avg TPOT 当前值 {{ \$value }}s，超过过去 1h 平均值 3 倍"

  - alert: VLLMQueueLatencyHighWarning
    expr: |
      simucraft:vllm_queue_latency_avg_seconds:ratio5m > 2
      and on(service)
      simucraft:vllm_waiting_requests:avg5m > 20
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "vLLM queue 平均时长超过 2s 且 waiting > 20"
      description: "ALERT 服务 {{ \$labels.service }} queue 平均时长为 {{ \$value }}s，且 waiting 5m 均值超过 20"

  - alert: VLLMQueueLatencyHighCritical
    expr: |
      simucraft:vllm_queue_latency_avg_seconds:ratio5m > 5
      and on(service)
      simucraft:vllm_waiting_requests:avg5m > 20
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "vLLM queue 平均时长超过 5s 且 waiting > 20"
      description: "ALERT 服务 {{ \$labels.service }} queue 平均时长为 {{ \$value }}s，且 waiting 5m 均值超过 20"

  # - alert: VLLMQueueBacklogGrowing
  #   expr: |
  #     simucraft:vllm_waiting_requests:avg5m > 0
  #     and
  #     simucraft:vllm_waiting_requests:avg5m
  #       > avg_over_time(simucraft:vllm_waiting_requests:avg5m[5m] offset 15m)
  #   for: 10m
  #   labels:
  #     severity: warning
  #   annotations:
  #     summary: "vLLM waiting 队列持续增长"
  #     description: "ALERT 服务 {{ \$labels.service }} waiting 请求数持续增长，当前 5m 均值为 {{ \$value }}"

  # - alert: VLLMPrefixCacheHitRateDropWarning
  #   expr: |
  #     simucraft:vllm_prefix_cache_hit_rate:ratio5m
  #       < 0.5 * avg_over_time(simucraft:vllm_prefix_cache_hit_rate:ratio5m[1h])
  #     and on(service)
  #     simucraft:vllm_prefix_cache_queries:rate5m > 0.1
  #   for: 10m
  #   labels:
  #     severity: warning
  #   annotations:
  #     summary: "vLLM prefix cache 命中率低于历史基线 50%"
  #     description: "ALERT 服务 {{ \$labels.service }} prefix cache hit rate 为 {{ \$value | humanizePercentage }}"

  # - alert: VLLMPrefixCacheHitRateLowCritical
  #   expr: |
  #     simucraft:vllm_prefix_cache_hit_rate:ratio5m < 0.20
  #     and on(service)
  #     simucraft:vllm_prefix_cache_queries:rate5m > 0.1
  #   for: 10m
  #   labels:
  #     severity: critical
  #   annotations:
  #     summary: "vLLM prefix cache 命中率低于 20%"
  #     description: "ALERT 服务 {{ \$labels.service }} prefix cache hit rate 为 {{ \$value | humanizePercentage }}"

  # - alert: VLLMPrefixCacheHitRateSpikeWarning
  #   expr: |
  #     simucraft:vllm_prefix_cache_hit_rate:ratio5m
  #       > 2 * avg_over_time(simucraft:vllm_prefix_cache_hit_rate:ratio5m[1h])
  #     and on(service)
  #     simucraft:vllm_prefix_cache_queries:rate5m > 0.1
  #   for: 10m
  #   labels:
  #     severity: warning
  #   annotations:
  #     summary: "vLLM prefix cache 命中率超过历史基线 2 倍"
  #     description: "ALERT 服务 {{ \$labels.service }} prefix cache hit rate 为 {{ \$value | humanizePercentage }}"
EOF
}

deploy_action() {
  if [[ ! -f "${ENV_EXAMPLE}" ]]; then
    die "缺少 ${ENV_EXAMPLE}"
  fi
  if [[ ! -x "${ALERT_DIR}/deploy.sh" && ! -f "${ALERT_DIR}/deploy.sh" ]]; then
    die "缺少告警部署脚本: ${ALERT_DIR}/deploy.sh"
  fi

  validate_bool "--enable-alerts" "${ENABLE_ALERTS}"
  validate_bool "--allow-download" "${ALLOW_DOWNLOAD}"
  validate_simple_name "--prometheus-job-prefix" "${PROMETHEUS_JOB_PREFIX}"

  require_value "--install-root" "${INSTALL_ROOT}"
  require_value "--env-file" "${ENV_FILE}"
  require_value "--service-domain" "${SERVICE_DOMAIN}"
  require_value "--admin-password" "${GRAFANA_ADMIN_PASSWORD}"

  if [[ "${#SERVICE_LINES[@]}" -eq 0 ]]; then
    usage
    die "至少传一个 --metrics-service / --metrics-proxy-service / --pd-service / --pd-proxy-service"
  fi
  validate_service_ids_match_services
  validate_target_down_for_match_services

  ENV_FILE="$(resolve_env_file "${ENV_FILE}")"
  ENV_DIR="$(cd "$(dirname "${ENV_FILE}")" && pwd)"
  ENV_KEY="$(derive_env_key "${ENV_FILE}")"

  if [[ -z "${SERVICES_FILE}" ]]; then
    SERVICES_FILE="services.${ENV_KEY}.tsv"
  fi
  if [[ "${SERVICES_FILE}" == /* ]]; then
    SERVICES_FILE_VALUE="${SERVICES_FILE}"
  else
    SERVICES_FILE_VALUE="${SERVICES_FILE}"
    SERVICES_FILE="${ENV_DIR}/${SERVICES_FILE}"
  fi

  if [[ "${ENABLE_ALERTS}" == "true" ]]; then
    require_value "--feishu-webhook" "${FEISHU_WEBHOOK}"
    ALERT_INSTALL_ROOT="${INSTALL_ROOT}-alertmanager"
    ALERT_ENV_FILE="${ENV_DIR}/env.${ENV_KEY}.alert.local"
    RULES_FILE="${ENV_DIR}/rules.${ENV_KEY}.alerts.yml"
    SERVICE_IDS_FILE="${ENV_DIR}/service_ids.${ENV_KEY}.tsv"
    ALERTMANAGER_TARGET="127.0.0.1:${ALERTMANAGER_PORT}"
    PROMETHEUS_RULES_FILE="${RULES_FILE}"
  else
    ALERT_INSTALL_ROOT=""
    ALERT_ENV_FILE=""
    RULES_FILE=""
    SERVICE_IDS_FILE=""
    ALERTMANAGER_TARGET=""
    PROMETHEUS_RULES_FILE=""
  fi

  write_services_file
  write_service_ids_file
  if [[ "${ENABLE_ALERTS}" == "true" ]]; then
    write_vllm_rules_file
  fi
  write_monitor_env "${ENV_FILE}"

  echo "已生成监控 env: ${ENV_FILE}"
  echo "已生成服务列表: ${SERVICES_FILE}"
  echo "服务数量: ${#SERVICE_LINES[@]}"

  if [[ "${ENABLE_ALERTS}" == "true" ]]; then
    echo "已生成告警规则: ${RULES_FILE}"
    apply_proxy_if_configured "${PROXY_SETUP_URL}"

    bash "${ALERT_DIR}/quick_deploy.sh" \
      --install-root "${ALERT_INSTALL_ROOT}" \
      --env-file "${ALERT_ENV_FILE}" \
      --feishu-route default "${FEISHU_WEBHOOK}" \
      --rules-file "${RULES_FILE}" \
      --alertmanager-port "${ALERTMANAGER_PORT}" \
      --feishu-relay-port "${FEISHU_RELAY_PORT}"

    append_alert_env_service_ids_file
    bash "${ALERT_DIR}/stop.sh" --env-file "${ALERT_ENV_FILE}" || true
    wait_alert_ports_free
    bash "${ALERT_DIR}/deploy.sh" --env-file "${ALERT_ENV_FILE}"
  fi

  run_monitor_deploy
  if [[ "${ENABLE_ALERTS}" == "true" ]]; then
    finalize_prometheus_alert_config
  fi
}

check_relay_proxy_env() {
  local pid_file pid env_file

  if [[ -z "${FEISHU_PROXY_SETUP_URL:-}" ]]; then
    return 0
  fi
  if [[ -z "${ALERTMANAGER_INSTALL_ROOT:-}" ]]; then
    die "env 里缺少 ALERTMANAGER_INSTALL_ROOT，无法检查 relay 代理环境"
  fi

  pid_file="${ALERTMANAGER_INSTALL_ROOT}/run/feishu-relay.pid"
  if [[ ! -f "${pid_file}" ]]; then
    die "缺少 feishu-relay pid 文件: ${pid_file}"
  fi

  pid="$(cat "${pid_file}")"
  if ! kill -0 "${pid}" 2>/dev/null; then
    die "feishu-relay 未运行，pid=${pid}"
  fi

  env_file="/proc/${pid}/environ"
  if [[ ! -r "${env_file}" ]]; then
    die "无法读取 relay 进程环境: ${env_file}"
  fi

  if ! tr '\0' '\n' < "${env_file}" | grep -Eq '^(https_proxy|HTTPS_PROXY)='; then
    die "配置了 FEISHU_PROXY_SETUP_URL，但 feishu-relay 进程没有 https_proxy/HTTPS_PROXY"
  fi
}

local_curl() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    curl --noproxy '*' -fsS "$@"
}

port_listener() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :${port}" 2>/dev/null | sed '1d'
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
    return 0
  fi
}

wait_alert_ports_free() {
  local attempt listener

  attempt=1
  while [[ "${attempt}" -le 10 ]]; do
    listener="$(
      {
        port_listener "${ALERTMANAGER_PORT}"
        port_listener "${FEISHU_RELAY_PORT}"
      } | sed '/^[[:space:]]*$/d'
    )"
    if [[ -z "${listener}" ]]; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  echo "Alertmanager/Feishu relay 端口仍被占用:"
  echo "${listener}"
  die "先停止旧进程，或换 --alertmanager-port / --feishu-relay-port"
}

grafana_login_path() {
  local subpath
  subpath="${GRAFANA_SUBPATH%/}"
  if [[ -z "${subpath}" ]]; then
    subpath="/"
  fi
  if [[ "${subpath}" == "/" ]]; then
    printf '%s\n' "/login"
  else
    printf '%s\n' "${subpath}/login"
  fi
}

wait_monitor_health() {
  local login_path attempt
  login_path="$(grafana_login_path)"

  attempt=1
  while [[ "${attempt}" -le 10 ]]; do
    if local_curl "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy" >/dev/null 2>&1 \
      && local_curl -I "http://127.0.0.1:${GRAFANA_PORT}${login_path}" 2>/dev/null | grep -qi '^Cache-Control: no-store'; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  return 1
}

run_monitor_deploy() {
  local deploy_status

  set +e
  bash "${SCRIPT_DIR}/deploy.sh" --env-file "${ENV_FILE}"
  deploy_status=$?
  set -e

  if [[ "${deploy_status}" -eq 0 ]]; then
    return 0
  fi

  echo "监控 deploy 返回失败，检查是否是 Grafana 刚启动的健康检查竞态..."
  if wait_monitor_health; then
    echo "Prometheus/Grafana 已健康，继续。"
    return 0
  fi

  return "${deploy_status}"
}

restart_prometheus() {
  local pid_file pid attempt

  pid_file="${INSTALL_ROOT}/run/prometheus.pid"
  if [[ -f "${pid_file}" ]]; then
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}"
      attempt=1
      while [[ "${attempt}" -le 20 ]] && kill -0 "${pid}" 2>/dev/null; do
        sleep 1
        attempt=$((attempt + 1))
      done
      if kill -0 "${pid}" 2>/dev/null; then
        die "Prometheus 停止超时，PID=${pid}"
      fi
    fi
    rm -f "${pid_file}"
  fi

  nohup "${INSTALL_ROOT}/prometheus/app/prometheus" \
    --config.file="${INSTALL_ROOT}/prometheus/conf/prometheus.yml" \
    --storage.tsdb.path="${INSTALL_ROOT}/prometheus/data" \
    --web.listen-address="127.0.0.1:${PROMETHEUS_PORT}" \
    > "${INSTALL_ROOT}/prometheus/logs/prometheus.log" 2>&1 &
  echo $! > "${pid_file}"
  echo "Prometheus 已按告警配置重启，PID=$!"
}

finalize_prometheus_alert_config() {
  local prom_conf rules_dst

  prom_conf="${INSTALL_ROOT}/prometheus/conf/prometheus.yml"
  rules_dst="${INSTALL_ROOT}/prometheus/rules/alerts.yml"

  if [[ ! -f "${prom_conf}" ]]; then
    die "缺少 Prometheus 配置: ${prom_conf}"
  fi

  mkdir -p "${INSTALL_ROOT}/prometheus/rules"
  cp "${RULES_FILE}" "${rules_dst}"

  if grep -q '^alerting:' "${prom_conf}"; then
    if ! grep -Fq "${ALERTMANAGER_TARGET}" "${prom_conf}"; then
      die "prometheus.yml 已有 alerting，但没有目标 ${ALERTMANAGER_TARGET}"
    fi
  else
    cat >> "${prom_conf}" <<EOF

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['${ALERTMANAGER_TARGET}']
EOF
  fi

  if grep -q '^rule_files:' "${prom_conf}"; then
    if ! grep -Fq "${INSTALL_ROOT}/prometheus/rules" "${prom_conf}"; then
      die "prometheus.yml 已有 rule_files，但没有 ${INSTALL_ROOT}/prometheus/rules"
    fi
  else
    cat >> "${prom_conf}" <<EOF

rule_files:
  - '${INSTALL_ROOT}/prometheus/rules/*.yml'
EOF
  fi

  if ! grep -q 'VLLMTargetDown' "${rules_dst}"; then
    die "告警规则文件缺少 VLLMTargetDown: ${rules_dst}"
  fi

  restart_prometheus
  if ! wait_monitor_health; then
    echo "最近 Prometheus 日志:"
    tail -50 "${INSTALL_ROOT}/prometheus/logs/prometheus.log" || true
    die "Prometheus 重启后健康检查失败"
  fi
}

resolve_services_file_from_env() {
  local env_dir services_file

  if [[ -z "${METRICS_SERVICES_FILE:-}" ]]; then
    die "env 里缺少 METRICS_SERVICES_FILE"
  fi

  env_dir="$(cd "$(dirname "${ENV_FILE}")" && pwd)"
  services_file="${METRICS_SERVICES_FILE}"
  if [[ "${services_file}" != /* ]]; then
    services_file="${env_dir}/${services_file}"
  fi
  if [[ ! -f "${services_file}" ]]; then
    die "缺少服务列表: ${services_file}"
  fi
  printf '%s\n' "${services_file}"
}

check_monitor_stack() {
  local service pid_file services_file login_path grafana_headers service_name metrics_scheme metrics_target metrics_path field5 field6 field7 field8 extra target_url target_failed

  echo "[PID]"
  for service in prometheus grafana; do
    pid_file="${INSTALL_ROOT}/run/${service}.pid"
    if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
      echo "${service}: running, pid=$(cat "${pid_file}")"
    else
      die "${service}: not running"
    fi
  done

  echo
  echo "[HTTP]"
  local_curl "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
  echo

  login_path="$(grafana_login_path)"
  grafana_headers="$(local_curl -I "http://127.0.0.1:${GRAFANA_PORT}${login_path}")"
  echo "${grafana_headers}"
  if ! printf '%s\n' "${grafana_headers}" | grep -qi '^Cache-Control: no-store'; then
    die "Grafana 响应不对，不像 Grafana 登录页: http://127.0.0.1:${GRAFANA_PORT}${login_path}"
  fi

  services_file="$(resolve_services_file_from_env)"
  echo
  echo "[METRICS TARGETS]"
  target_failed=false
  while IFS=$'\t' read -r service_name metrics_scheme metrics_target metrics_path field5 field6 field7 field8 extra; do
    if [[ -z "${service_name}" || "${service_name}" == \#* ]]; then
      continue
    fi
    normalize_service_metadata "${field5:-}" "${field6:-}" "${field7:-}" "${field8:-}" "${extra:-}"
    validate_service_row "${service_name}" "${metrics_scheme}" "${metrics_target}" "${metrics_path}" "${ROW_PD_GROUP}" "${ROW_PD_ROLE}" "${ROW_PD_INSTANCE}" "${ROW_BACKEND_URL}" "${ROW_EXTRA}"
    target_url="$(service_target_url "${metrics_scheme}" "${metrics_target}" "${metrics_path}" "${ROW_BACKEND_URL}")"
    if local_curl "${target_url}" >/dev/null 2>&1; then
      echo "${service_name}: healthy ${target_url}"
    else
      echo "${service_name}: unreachable ${target_url}"
      target_failed=true
    fi
  done < "${services_file}"

  if [[ "${target_failed}" == "true" ]]; then
    echo "存在不可达 metrics target；这会触发 Prometheus up=0/TargetDown，继续检查告警链路。"
  fi
}

check_prometheus_alert_rules() {
  local rules_json alert_name
  local alert_names=(
    VLLMTargetDown
    VLLMHighErrorRateWarning
    VLLMHighErrorRateCritical
    VLLMQueueLatencyHighWarning
    VLLMQueueLatencyHighCritical
  )

  echo
  echo "[PROMETHEUS ALERT RULES]"
  rules_json="$(local_curl "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/rules")"
  for alert_name in "${alert_names[@]}"; do
    if ! printf '%s\n' "${rules_json}" | grep -q "\"name\":\"${alert_name}\""; then
      die "Prometheus 未加载告警规则: ${alert_name}"
    fi
    echo "${alert_name}: loaded"
  done
}

check_prometheus_services_up() {
  local services_file up_json service_name metrics_scheme metrics_target metrics_path field5 field6 field7 field8 extra

  services_file="$(resolve_services_file_from_env)"
  echo
  echo "[PROMETHEUS SERVICE LABELS]"
  up_json="$(local_curl "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/query?query=up")"

  while IFS=$'\t' read -r service_name metrics_scheme metrics_target metrics_path field5 field6 field7 field8 extra; do
    if [[ -z "${service_name}" || "${service_name}" == \#* ]]; then
      continue
    fi
    normalize_service_metadata "${field5:-}" "${field6:-}" "${field7:-}" "${field8:-}" "${extra:-}"
    validate_service_row "${service_name}" "${metrics_scheme}" "${metrics_target}" "${metrics_path}" "${ROW_PD_GROUP}" "${ROW_PD_ROLE}" "${ROW_PD_INSTANCE}" "${ROW_BACKEND_URL}" "${ROW_EXTRA}"
    if ! printf '%s\n' "${up_json}" | grep -q "\"service\":\"${service_name}\""; then
      die "Prometheus up 查询未看到 service=${service_name}"
    fi
    echo "service=${service_name}: present"
  done < "${services_file}"
}

check_action() {
  local alert_check_args

  require_value "--env-file" "${ENV_FILE}"
  ENV_FILE="$(resolve_env_file "${ENV_FILE}")"
  if [[ ! -f "${ENV_FILE}" ]]; then
    die "缺少 ${ENV_FILE}"
  fi

  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  ensure_no_proxy

  check_monitor_stack

  if [[ "${ALERTS_ENABLED:-false}" != "true" ]]; then
    echo
    echo "[ALERTS]"
    echo "未启用告警。"
    return 0
  fi

  if [[ -z "${ALERTMANAGER_ENV_FILE:-}" ]]; then
    die "ALERTS_ENABLED=true，但 env 里缺少 ALERTMANAGER_ENV_FILE"
  fi

  check_relay_proxy_env
  check_prometheus_alert_rules
  check_prometheus_services_up

  alert_check_args=(--env-file "${ALERTMANAGER_ENV_FILE}")
  if [[ "${SEND_TEST}" == "true" ]]; then
    alert_check_args+=(--send-test --route "${TEST_ROUTE}")
  fi

  echo
  echo "[ALERTS]"
  bash "${ALERT_DIR}/check.sh" "${alert_check_args[@]}"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

ACTION="$1"
shift

INSTALL_ROOT=""
ENV_FILE=""
ENV_DIR=""
ENV_KEY=""
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
ENABLE_ALERTS="false"
FEISHU_WEBHOOK=""
PROXY_SETUP_URL=""
ALERTMANAGER_PORT="19093"
FEISHU_RELAY_PORT="19094"
ALERT_INSTALL_ROOT=""
ALERT_ENV_FILE=""
RULES_FILE=""
SERVICE_IDS_FILE=""
ALERTMANAGER_TARGET=""
PROMETHEUS_RULES_FILE=""
SERVICE_LINES=()
SERVICE_ID_NAMES=()
SERVICE_ID_VALUES=()
TARGET_DOWN_FOR_NAMES=()
TARGET_DOWN_FOR_VALUES=()
SEND_TEST=false
TEST_ROUTE=default

case "${ACTION}" in
  deploy)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --install-root)
          INSTALL_ROOT="${2:-}"; shift 2 ;;
        --env-file)
          ENV_FILE="${2:-}"; shift 2 ;;
        --services-file)
          SERVICES_FILE="${2:-}"; shift 2 ;;
        --service-domain)
          SERVICE_DOMAIN="${2:-}"; shift 2 ;;
        --admin-password)
          GRAFANA_ADMIN_PASSWORD="${2:-}"; shift 2 ;;
        --grafana-subpath)
          GRAFANA_SUBPATH="${2:-}"; shift 2 ;;
        --admin-user)
          GRAFANA_ADMIN_USER="${2:-}"; shift 2 ;;
        --prometheus-job-prefix)
          PROMETHEUS_JOB_PREFIX="${2:-}"; shift 2 ;;
        --prometheus-port)
          PROMETHEUS_PORT="${2:-}"; shift 2 ;;
        --grafana-port)
          GRAFANA_PORT="${2:-}"; shift 2 ;;
        --offline-bundle-dir)
          OFFLINE_BUNDLE_DIR="${2:-}"; shift 2 ;;
        --allow-download)
          ALLOW_DOWNLOAD="${2:-}"; shift 2 ;;
        --enable-alerts)
          ENABLE_ALERTS="${2:-}"; shift 2 ;;
        --feishu-webhook)
          FEISHU_WEBHOOK="${2:-}"; shift 2 ;;
        --proxy-setup-url)
          PROXY_SETUP_URL="${2:-}"; shift 2 ;;
        --alertmanager-port)
          ALERTMANAGER_PORT="${2:-}"; shift 2 ;;
        --feishu-relay-port)
          FEISHU_RELAY_PORT="${2:-}"; shift 2 ;;
        --metrics-service)
          require_value "--metrics-service <服务名>" "${2:-}"
          require_value "--metrics-service <scheme>" "${3:-}"
          require_value "--metrics-service <target>" "${4:-}"
          require_value "--metrics-service <path>" "${5:-}"
          add_metrics_service "$2" "$3" "$4" "$5"
          shift 5 ;;
        --metrics-proxy-service)
          require_value "--metrics-proxy-service <服务名>" "${2:-}"
          require_value "--metrics-proxy-service <proxy_metrics_url>" "${3:-}"
          require_value "--metrics-proxy-service <backend_url>" "${4:-}"
          add_metrics_proxy_service "$2" "$3" "$4"
          shift 4 ;;
        --pd-service)
          require_value "--pd-service <pd_group>" "${2:-}"
          require_value "--pd-service <prefill|decode|router>" "${3:-}"
          require_value "--pd-service <服务名>" "${4:-}"
          require_value "--pd-service <metrics_url>" "${5:-}"
          add_pd_service "$2" "$3" "$4" "$5"
          shift 5 ;;
        --pd-proxy-service)
          require_value "--pd-proxy-service <pd_group>" "${2:-}"
          require_value "--pd-proxy-service <prefill|decode|router>" "${3:-}"
          require_value "--pd-proxy-service <服务名>" "${4:-}"
          require_value "--pd-proxy-service <proxy_metrics_url>" "${5:-}"
          require_value "--pd-proxy-service <backend_url>" "${6:-}"
          add_pd_proxy_service "$2" "$3" "$4" "$5" "$6"
          shift 6 ;;
        --service-id)
          require_value "--service-id <服务名>" "${2:-}"
          require_value "--service-id <显示ID>" "${3:-}"
          add_service_id "$2" "$3"
          shift 3 ;;
        --target-down-for)
          require_value "--target-down-for <服务名>" "${2:-}"
          require_value "--target-down-for <duration>" "${3:-}"
          add_target_down_for "$2" "$3"
          shift 3 ;;
        -h|--help)
          usage; exit 0 ;;
        *)
          usage
          die "未知参数: $1" ;;
      esac
    done
    deploy_action
    ;;
  check)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --env-file)
          ENV_FILE="${2:-}"; shift 2 ;;
        --send-test)
          SEND_TEST=true; shift ;;
        --route)
          TEST_ROUTE="${2:-}"; shift 2 ;;
        -h|--help)
          usage; exit 0 ;;
        *)
          usage
          die "未知参数: $1" ;;
      esac
    done
    check_action
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    die "未知动作: ${ACTION}" ;;
esac
