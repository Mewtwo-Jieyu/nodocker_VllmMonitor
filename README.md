# No-Docker vLLM Monitor

一套不依赖 Docker 的 vLLM 多服务监控与飞书告警脚本。核心组件是 Prometheus、Grafana、Alertmanager 和一个轻量 Feishu relay。

## 使用场景

| 场景 | 适用性 |
|---|---|
| 一台机器监控一个 vLLM 服务 | 适合，传一条 `--metrics-service` |
| 一台机器监控多个 vLLM 服务 | 适合，传多条 `--metrics-service` |
| 用一个 Grafana 入口查看多个服务 | 适合，通过 `service` 标签区分 |
| 服务异常时推送飞书群 | 适合，开启 `--enable-alerts true` |
| 机器没有 Docker / docker-compose | 适合 |
| 需要 Kubernetes Operator | 不适合，这套是裸机脚本 |

## 需要的工具

| 工具 | 用途 |
|---|---|
| `bash` | 执行部署、检查、启停脚本 |
| `curl` 或 `wget` | 下载离线包、健康检查、发送测试请求 |
| `tar` | 解压 Prometheus / Grafana / Alertmanager |
| `python3` | 运行 Feishu relay |
| `nohup` | 后台运行服务，关闭 shell 后不退出 |
| `ss` / `lsof` / `netstat` | 检查端口占用，三者有一个即可 |

## 文件说明

| 文件/目录 | 用途 |
|---|---|
| `quick_deploy_with_alerts.sh` | 推荐入口；一键部署多服务监控，可选部署飞书告警 |
| `quick_deploy.sh` | 只部署 Prometheus + Grafana，不处理告警 |
| `deploy.sh` | 解压二进制包、渲染配置、启动 Prometheus/Grafana |
| `start.sh` / `stop.sh` | 启动/停止 Prometheus 和 Grafana |
| `check.sh` | 检查 Prometheus、Grafana 和 metrics target |
| `render_configs.sh` | 根据 env 和 services 文件生成 `prometheus.yml` / `grafana.ini` |
| `env.example` | 监控实例配置模板 |
| `services.example.tsv` | 多服务 metrics 列表模板 |
| `dashboards/` | 预置 Grafana dashboard |
| `alertmanager_feishu/` | Alertmanager + Feishu relay 子模块 |
| `alertmanager_feishu/feishu_relay.py` | 接收 Alertmanager webhook，并转发到飞书机器人 |
| `dist/` | Prometheus / Grafana 离线包目录，不把大二进制提交进 Git |
| `alertmanager_feishu/dist/` | Alertmanager 离线包目录，不把大二进制提交进 Git |

## 离线包

默认不联网下载，先把这些文件放好：

| 目录 | 文件 |
|---|---|
| `dist/` | `prometheus-3.11.1.linux-amd64.tar.gz` |
| `dist/` | `grafana-enterprise_12.4.1_22846628243_linux_amd64.tar.gz` |
| `alertmanager_feishu/dist/` | `alertmanager-0.28.1.linux-amd64.tar.gz` |

如果机器可以访问公网，可以部署时加：

```bash
--allow-download true
```

## 快速部署

不启用告警：

```bash
bash quick_deploy_with_alerts.sh deploy \
  --install-root /opt/vllm-monitor \
  --env-file env.demo.local \
  --service-domain monitor.example.com \
  --admin-password change-this-password \
  --metrics-service kimi25 http kimi-metrics.example.com /metrics
```

启用飞书告警：

```bash
FEISHU_WEBHOOK='https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-webhook'

bash quick_deploy_with_alerts.sh deploy \
  --install-root /opt/vllm-monitor \
  --env-file env.demo.local \
  --service-domain monitor.example.com \
  --admin-password change-this-password \
  --metrics-service kimi25 http kimi-metrics.example.com /metrics \
  --service-id kimi25 'cluster-a kimi25' \
  --enable-alerts true \
  --feishu-webhook "${FEISHU_WEBHOOK}"
```

多服务就是重复 `--metrics-service`：

```bash
--metrics-service kimi25 http kimi-metrics.example.com /metrics \
--metrics-service qwen35 http qwen-metrics.example.com /metrics
```

如果飞书出网需要代理，再加：

```bash
--proxy-setup-url 'http://proxy.example.com/setup_proxy.sh'
```

## 检查

```bash
bash quick_deploy_with_alerts.sh check --env-file env.demo.local --send-test
```

| 输出 | 含义 |
|---|---|
| `VLLM...: loaded` | Prometheus 已加载告警规则 |
| `service=<name>: present` | Prometheus `up` 里有这个服务 |
| `[TEST]` 飞书消息 | webhook / 代理 / relay 链路正常 |
| `metrics target unreachable` | 监控机访问不到该服务 `/metrics` |

## 当前告警规则

| 告警 | 条件 | 持续时间 |
|---|---|---|
| `VLLMTargetDown` | Prometheus 抓不到服务 `/metrics`，即 `up == 0` | `2m` |
| `VLLMHighErrorRateWarning` | 最近 5 分钟请求失败率 `> 1%` | `2m` |
| `VLLMHighErrorRateCritical` | 最近 5 分钟请求失败率 `> 5%` | `2m` |
| `VLLMQueueLatencyHighWarning` | queue 平均时长 `> 2s`，且 waiting 5 分钟均值 `> 20` | `5m` |
| `VLLMQueueLatencyHighCritical` | queue 平均时长 `> 5s`，且 waiting 5 分钟均值 `> 20` | `5m` |

低流量阶段暂时关闭了 TPOT spike、waiting 持续增长、prefix cache 相关告警。

## 飞书消息

| 状态 | 卡片颜色 |
|---|---|
| `Firing + VLLMTargetDown` | 红色 |
| 其它 `Firing` | 橙色 |
| `Resolved` | 绿色 |

飞书机器人建议配置关键词：`ALERT`。

## 生成的运行文件

部署后会在 `--install-root` 指定目录下生成：

| 路径 | 用途 |
|---|---|
| `prometheus/conf/prometheus.yml` | Prometheus 配置 |
| `prometheus/rules/alerts.yml` | 告警规则 |
| `prometheus/logs/prometheus.log` | Prometheus 日志 |
| `grafana/conf/grafana.ini` | Grafana 配置 |
| `grafana/logs/grafana.log` | Grafana 日志 |
| `run/*.pid` | 后台进程 pid 文件 |

启用告警时，还会生成 `${install_root}-alertmanager/`，里面包含 Alertmanager 和 Feishu relay 的配置、日志、pid。
