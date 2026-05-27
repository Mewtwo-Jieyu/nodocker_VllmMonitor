# 开发机部署指南

这里的“开发机”指你本地可以 `ssh` 登录的一台远程 Linux 机器。下面用 `开发机` 举例，它只是本地 SSH 配置里的别名。

## 适用场景

| 场景 | 说明 |
|---|---|
| 监控服务跑在开发机上 | Prometheus/Grafana 在 `开发机` 上后台运行 |
| vLLM 服务跑在其它机器或同一机器 | 只要开发机能访问目标 `/metrics` 即可 |
| 本地电脑看 Grafana | 用 SSH tunnel 转发开发机端口 |
| 不启用飞书告警 | 只部署 Prometheus + Grafana |
| 没有 Docker 权限 | 适合，这套脚本不用 Docker |

## 需要准备

| 项目 | 要求 |
|---|---|
| SSH | 本地能执行 `ssh 开发机` |
| 端口 | 开发机上 Grafana/Prometheus 端口未被占用 |
| 网络 | 开发机能访问 vLLM 服务的 `/metrics` |
| 离线包 | 执行 `download_release_assets.sh` 下载，或本地下载后 `scp` 到开发机 |
| 安装目录 | 推荐用开发机本地盘或 `/tmp`，不要把 Prometheus 数据目录放在不支持 mmap 的共享盘上 |

## 一键部署流程

### 1. 登录开发机

```bash
ssh 开发机
```

### 2. 拉取仓库

如果开发机访问 GitHub 需要代理，先在当前 shell 执行：

```bash
source <(curl -sSL http://deploy.i.h.pjlab.org.cn/infra/scripts/setup_proxy.sh)
```

```bash
mkdir -p /mnt/shared-storage-user/ailab-sys/xxx
cd /mnt/shared-storage-user/ailab-sys/xxx

git clone https://github.com/Mewtwo-Jieyu/nodocker_VllmMonitor.git
cd nodocker_VllmMonitor
```

如果已经 clone 过：

```bash
cd /mnt/shared-storage-user/ailab-sys/xxx/nodocker_VllmMonitor
git pull
```

### 3. 准备离线包

如果上一步已经在同一个 shell 里加过代理，直接执行：

```bash
bash download_release_assets.sh
```

第一次下载三个离线包通常需要几分钟。后续重复执行会先校验本地缓存，校验通过就不会重新下载。

如果开发机不能下载，也可以在本地电脑下载后传过去：

```bash
git clone https://github.com/Mewtwo-Jieyu/nodocker_VllmMonitor.git
cd nodocker_VllmMonitor
bash download_release_assets.sh

scp -r nodocker_VllmMonitor 开发机:/mnt/shared-storage-user/ailab-sys/xxx
```

### 4. 部署监控服务

下面例子监控两个 vLLM 服务，不启用飞书告警：

```bash
cd /mnt/shared-storage-user/ailab-sys/xxx/nodocker_VllmMonitor

bash quick_deploy_with_alerts.sh deploy \
  --install-root /tmp/xxx/vllm-monitor/demo-monitor \
  --env-file env.demo.local \
  --service-domain localhost \
  --admin-password admin \
  --metrics-service service-a http 10.140.158.149:8140 /metrics \
  --metrics-service service-b http 10.140.158.149:8142 /metrics \
  --prometheus-port 19090 \
  --grafana-port 13000 \
  --enable-alerts false
```

注意：

| 参数 | 说明 |
|---|---|
| `--install-root` | Prometheus/Grafana 的实际运行目录。推荐放 `/tmp/<user>/...` 或本地盘 |
| `--env-file` | 本次部署生成的配置入口，后续检查/停止都用它 |
| `--service-domain localhost` | 通过 SSH tunnel 本地查看时填 `localhost` 即可 |
| `--metrics-service` | 一条服务一行：服务名、协议、metrics 地址、metrics path |
| `--prometheus-port` / `--grafana-port` | 如果默认 `9090/3000` 被占用，就换成其它端口 |

不要在反斜杠 `\` 后面加空格。

### 5. 检查部署

```bash
bash quick_deploy_with_alerts.sh check --env-file env.demo.local
```

看到下面几类输出才算正常：

| 输出 | 正常含义 |
|---|---|
| `prometheus: running` | Prometheus 后台进程还在 |
| `grafana: running` | Grafana 后台进程还在 |
| `Prometheus Server is Healthy` | Prometheus HTTP 健康 |
| `HTTP/1.1 200 OK` | Grafana 能打开 |
| `healthy http://.../metrics` | 开发机能抓到对应服务 metrics |

## 本地电脑打开 Grafana

在本地电脑新开一个终端：

```bash
ssh -N -L 13000:127.0.0.1:13000 开发机
```

然后浏览器打开：

```text
http://127.0.0.1:13000/grafana/
```

默认登录：

| 字段 | 值 |
|---|---|
| 用户名 | `admin` |
| 密码 | 部署时的 `--admin-password` |

看完面板后，可以在本地 tunnel 终端按 `Ctrl+C`。这只会关闭本地转发，不会停止开发机上的 Prometheus/Grafana。

## 停止和重启

停止当前监控实例：

```bash
cd /mnt/shared-storage-user/ailab-sys/xxx/nodocker_VllmMonitor
bash stop.sh --env-file env.demo.local
```

重启或改服务列表时，重新执行 `deploy` 命令即可。脚本会先停旧进程，再按新配置启动。

## 常见问题

| 现象 | 处理 |
|---|---|
| `set: pipefail: invalid option name` | 文件被转成 CRLF，执行 `sed -i 's/\r$//' *.sh alertmanager_feishu/*.sh alertmanager_feishu/feishu_relay.py` |
| 提示离线包不存在 | 先执行 `bash download_release_assets.sh`，或本地下载后 `scp` 整个仓库 |
| `Grafana 本机健康检查失败` | 先执行 `check` 再判断；Grafana 刚启动时可能慢几秒 |
| Prometheus 日志出现 `Unable to create mmap-ed active query log` | `--install-root` 所在文件系统不支持 mmap，换到 `/tmp/...` 或开发机本地盘 |
| 本地浏览器打不开 Grafana | 确认 SSH tunnel 还在运行，地址用 `http://127.0.0.1:13000/grafana/` |
| metrics target unreachable | 在开发机上直接 `curl http://目标地址/metrics`，确认开发机到服务网络可达 |
