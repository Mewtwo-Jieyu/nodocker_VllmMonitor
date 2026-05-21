# Alertmanager + Feishu Relay

这个目录是 `No-Docker vLLM Monitor` 的告警子模块。通常不需要单独操作，推荐由上层 `quick_deploy_with_alerts.sh` 自动调用。

## 文件说明

| 文件 | 用途 |
|---|---|
| `quick_deploy.sh` | 生成告警 env 和飞书路由文件 |
| `deploy.sh` | 解压 Alertmanager、渲染配置、启动服务 |
| `start.sh` / `stop.sh` | 启动/停止 Alertmanager 和 Feishu relay |
| `check.sh` | 检查 Alertmanager、relay 和飞书测试消息 |
| `render_configs.sh` | 生成 `alertmanager.yml` 和 relay 路由配置 |
| `feishu_relay.py` | 接收 Alertmanager webhook，转成飞书消息 |
| `env.example` | 告警实例配置模板 |
| `routes.example.tsv` | 飞书 webhook 路由模板 |
| `rules.example.yml` | 独立测试用告警规则示例 |
| `dist/` | Alertmanager 离线包目录 |

## 单独部署示例

```bash
FEISHU_WEBHOOK='https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-webhook'

bash quick_deploy.sh \
  --install-root /opt/vllm-monitor-alertmanager \
  --env-file env.alert.local \
  --feishu-route default "${FEISHU_WEBHOOK}" \
  --alertmanager-port 19093 \
  --feishu-relay-port 19094

bash deploy.sh --env-file env.alert.local
bash check.sh --env-file env.alert.local --send-test
```

如果机器访问飞书需要代理，请先在当前 shell 设置 `http_proxy` / `https_proxy`，并确保 `127.0.0.1,localhost` 在 `no_proxy` 里。
