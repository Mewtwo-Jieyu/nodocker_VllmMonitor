#!/usr/bin/env python3
"""
Alertmanager -> Feishu webhook relay.
Only requires Python stdlib. No Flask, no requests, no pip.

Usage:
  FEISHU_ROUTES_FILE=routes.tsv FEISHU_RELAY_PORT=19093 python3 feishu_relay.py
"""
import sys, os, json, hashlib, hmac, base64, time, csv
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

ROUTES = {}
SERVICE_IDS = {}
LOG_FILE = None

def load_routes(path):
    routes = {}
    if not os.path.exists(path):
        print(f"[relay] routes file not found: {path}", file=sys.stderr)
        return routes
    with open(path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f, delimiter='\t')
        for row in reader:
            if not row or not row[0] or row[0].startswith('#'):
                continue
            if len(row) < 3:
                continue
            name = row[0].strip()
            matchers = row[1].strip() if len(row) > 1 else ''
            webhook = row[2].strip()
            secret = row[3].strip() if len(row) > 3 else ''
            if webhook:
                routes[name] = {'matchers': matchers, 'webhook': webhook, 'secret': secret}
    return routes

def load_service_ids(path):
    service_ids = {}
    if not path:
        return service_ids
    if not os.path.exists(path):
        print(f"[relay] service id file not found: {path}", file=sys.stderr)
        return service_ids
    with open(path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f, delimiter='\t')
        for row in reader:
            if not row or not row[0] or row[0].startswith('#'):
                continue
            if len(row) < 2:
                continue
            service = row[0].strip()
            service_id = row[1].strip()
            if service and service_id:
                service_ids[service] = service_id
    return service_ids

def gen_sign(timestamp_str, secret):
    string_to_sign = f'{timestamp_str}\n{secret}'
    hmac_code = hmac.new(secret.encode('utf-8'), string_to_sign.encode('utf-8'), hashlib.sha256).digest()
    return base64.b64encode(hmac_code).decode()

def send_feishu(webhook, secret, payload):
    if secret:
        ts = str(int(time.time()))
        sign = gen_sign(ts, secret)
        payload['timestamp'] = ts
        payload['sign'] = sign

    data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    req = Request(webhook, data=data, headers={'Content-Type': 'application/json; charset=utf-8'})
    try:
        resp = urlopen(req, timeout=10)
        return resp.status, resp.read().decode('utf-8')
    except HTTPError as e:
        return e.code, e.read().decode('utf-8')
    except URLError as e:
        return None, str(e.reason)

def redact_webhook(url):
    if len(url) <= 50:
        return url
    return url[:40] + '...' + url[-8:]

def text_payload(text):
    return {"msg_type": "text", "content": {"text": text}}

def alert_display_status(alert_status):
    return "Firing" if alert_status == "firing" else "Resolved"

def service_display_id(labels):
    return labels.get('service_id') or SERVICE_IDS.get(labels.get('service', ''), '')

def alert_lines(alert):
    labels = alert.get('labels', {})
    annotations = alert.get('annotations', {})
    lines = [alert_display_status(alert.get('status', 'unknown'))]

    lines.append(f"告警: {labels.get('alertname', 'unknown')}")
    if labels.get('severity'):
        lines.append(f"级别: {labels['severity']}")
    if labels.get('service'):
        lines.append(f"服务: {labels['service']}")
    service_id = service_display_id(labels)
    if service_id:
        lines.append(f"服务ID: {service_id}")
    if labels.get('instance'):
        lines.append(f"实例: {labels['instance']}")
    if annotations.get('summary'):
        lines.append(f"摘要: {annotations['summary']}")
    if annotations.get('description'):
        lines.append(f"描述: {annotations['description']}")
    if alert.get('startsAt'):
        lines.append(f"开始: {alert['startsAt']}")

    return lines

def card_template(data):
    status = data.get('status', 'unknown')
    if status == 'resolved':
        return 'green'
    for alert in data.get('alerts', []):
        labels = alert.get('labels', {})
        if alert.get('status') == 'firing' and labels.get('alertname') == 'VLLMTargetDown':
            return 'red'
    return 'orange'

def card_title(data):
    status = alert_display_status(data.get('status', 'unknown'))
    alerts = data.get('alerts', [])
    if not alerts:
        return f"ALERT {status}"

    alert_names = []
    for alert in alerts:
        alert_name = alert.get('labels', {}).get('alertname', 'unknown')
        if alert_name not in alert_names:
            alert_names.append(alert_name)
    if len(alert_names) == 1:
        return f"ALERT {status} · {alert_names[0]}"
    return f"ALERT {status} · {len(alerts)} 条告警"

def alert_card_payload(data):
    alerts = data.get('alerts', [])
    elements = []

    if not alerts:
        lines = [f"状态变更: {data.get('status', 'unknown')}"]
        summary = data.get('commonAnnotations', {}).get('summary')
        if summary:
            lines.append(f"摘要: {summary}")
        elements.append({"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(lines)}})
    else:
        for index, alert in enumerate(alerts):
            if index > 0:
                elements.append({"tag": "hr"})
            elements.append({
                "tag": "div",
                "text": {
                    "tag": "lark_md",
                    "content": "\n".join(alert_lines(alert)),
                },
            })

    return {
        "msg_type": "interactive",
        "card": {
            "config": {"wide_screen_mode": True},
            "header": {
                "template": card_template(data),
                "title": {
                    "tag": "plain_text",
                    "content": card_title(data),
                },
            },
            "elements": elements,
        },
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        if LOG_FILE:
            with open(LOG_FILE, 'a') as f:
                f.write(f"[relay] {self.client_address[0]} - {format % args}\n")
        else:
            print(f"[relay] {self.client_address[0]} - {format % args}", file=sys.stderr)

    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.rstrip('/')
        parts = [p for p in path.split('/') if p]

        if len(parts) >= 2 and parts[0] in ('alert', 'test'):
            action = parts[0]
            route_name = parts[1]

            content_len = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_len) if content_len > 0 else b'{}'

            route = ROUTES.get(route_name)
            if not route:
                route = ROUTES.get('default')
                if not route:
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(b'no route configured')
                    return

            if action == 'test':
                text = f"ALERT [TEST] Feishu route '{route_name}' 链路正常\n时间: {time.strftime('%Y-%m-%d %H:%M:%S')}"
                payload = text_payload(text)
            else:
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'invalid JSON')
                    return
                payload = alert_card_payload(data)

            print(f"[relay] route={route_name} webhook={redact_webhook(route['webhook'])}", file=sys.stderr)

            status, resp = send_feishu(route['webhook'], route.get('secret', ''), payload)
            if status and 200 <= status < 300:
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'ok')
            else:
                print(f"[relay] feishu error: status={status} resp={resp}", file=sys.stderr)
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f'feishu error: {resp}'.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

def main():
    global ROUTES, SERVICE_IDS, LOG_FILE

    routes_file = os.environ.get('FEISHU_ROUTES_FILE', 'routes.tsv')
    if not os.path.isabs(routes_file):
        routes_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), routes_file)
    service_ids_file = os.environ.get('FEISHU_SERVICE_IDS_FILE', '')

    port = int(os.environ.get('FEISHU_RELAY_PORT', '19093'))
    log_dir = os.environ.get('FEISHU_RELAY_LOG_DIR', '')

    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
        LOG_FILE = os.path.join(log_dir, 'feishu_relay.log')

    ROUTES = load_routes(routes_file)
    if not ROUTES:
        print("[relay] WARNING: no routes loaded", file=sys.stderr)
    else:
        print(f"[relay] loaded {len(ROUTES)} route(s): {list(ROUTES.keys())}", file=sys.stderr)
    SERVICE_IDS = load_service_ids(service_ids_file)
    if SERVICE_IDS:
        print(f"[relay] loaded {len(SERVICE_IDS)} service id(s)", file=sys.stderr)

    listen_addr = os.environ.get('FEISHU_RELAY_LISTEN_ADDR', '127.0.0.1')
    server = HTTPServer((listen_addr, port), Handler)
    print(f"[relay] listening on {listen_addr}:{port}", file=sys.stderr)
    server.serve_forever()

if __name__ == '__main__':
    main()
