#!/usr/bin/env python3
"""
Read-only proxy dashboard.

- Shows node info, subscription links, QR codes, container health.
- Basic Auth on all routes except /sub (which uses token in query).
- /sub returns base64-encoded aggregated subscription for clients.
"""
import os
import io
import base64
import subprocess
import urllib.parse
from functools import wraps
from flask import Flask, render_template, request, Response, jsonify, abort, send_file
import qrcode

app = Flask(__name__)

# ---------- Config from env ----------
CFG = {
    "SERVER_IP":          os.environ.get("SERVER_IP", "0.0.0.0"),
    "NODE_NAME":          os.environ.get("NODE_NAME", "node"),
    "VLESS_PORT":         os.environ.get("VLESS_PORT", "443"),
    "VLESS_UUID":         os.environ.get("VLESS_UUID", ""),
    "REALITY_PUBLIC_KEY": os.environ.get("REALITY_PUBLIC_KEY", ""),
    "REALITY_SHORT_ID":   os.environ.get("REALITY_SHORT_ID", ""),
    "REALITY_SNI":        os.environ.get("REALITY_SNI", "www.microsoft.com"),
    "HY2_PORT":           os.environ.get("HY2_PORT", "8443"),
    "HY2_PASSWORD":       os.environ.get("HY2_PASSWORD", ""),
    "ANYTLS_PORT":        os.environ.get("ANYTLS_PORT", "9443"),
    "ANYTLS_PASSWORD":    os.environ.get("ANYTLS_PASSWORD", ""),
    "TUIC_PORT":          os.environ.get("TUIC_PORT", "9444"),
    "TUIC_UUID":          os.environ.get("TUIC_UUID", ""),
    "TUIC_PASSWORD":      os.environ.get("TUIC_PASSWORD", ""),
    "MTG_PORT":           os.environ.get("MTG_PORT", "8888"),
    "MTG_SECRET":         os.environ.get("MTG_SECRET", ""),
}
DASH_USER = os.environ.get("DASHBOARD_USER", "admin")
DASH_PASS = os.environ.get("DASHBOARD_PASS", "")


# ---------- Build subscription links ----------
def vless_link():
    tag = urllib.parse.quote(f"{CFG['NODE_NAME']}-Reality")
    return (
        f"vless://{CFG['VLESS_UUID']}@{CFG['SERVER_IP']}:{CFG['VLESS_PORT']}"
        f"?encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={CFG['REALITY_SNI']}&fp=chrome"
        f"&pbk={CFG['REALITY_PUBLIC_KEY']}&sid={CFG['REALITY_SHORT_ID']}"
        f"&type=tcp&headerType=none#{tag}"
    )


def hy2_link():
    tag = urllib.parse.quote(f"{CFG['NODE_NAME']}-Hy2")
    return (
        f"hysteria2://{CFG['HY2_PASSWORD']}@{CFG['SERVER_IP']}:{CFG['HY2_PORT']}"
        f"?sni=bing.com&insecure=1#{tag}"
    )


def anytls_link():
    tag = urllib.parse.quote(f"{CFG['NODE_NAME']}-AnyTLS")
    password = urllib.parse.quote(CFG["ANYTLS_PASSWORD"], safe="")
    return (
        f"anytls://{password}@{CFG['SERVER_IP']}:{CFG['ANYTLS_PORT']}"
        f"?sni=bing.com&insecure=1#{tag}"
    )


def tuic_link():
    tag = urllib.parse.quote(f"{CFG['NODE_NAME']}-TUIC")
    return (
        f"tuic://{CFG['TUIC_UUID']}:{CFG['TUIC_PASSWORD']}@{CFG['SERVER_IP']}:{CFG['TUIC_PORT']}"
        f"?congestion_control=bbr&udp_relay_mode=native&sni=bing.com"
        f"&alpn=h3&allow_insecure=1#{tag}"
    )


def mtg_links():
    base = (
        f"server={CFG['SERVER_IP']}&port={CFG['MTG_PORT']}"
        f"&secret={CFG['MTG_SECRET']}"
    )
    return {
        "tg":    f"tg://proxy?{base}",
        "https": f"https://t.me/proxy?{base}",
    }


def all_links():
    mtg = mtg_links()
    return {
        "vless":     vless_link(),
        "hy2":       hy2_link(),
        "anytls":    anytls_link(),
        "tuic":      tuic_link(),
        "mtg_tg":    mtg["tg"],
        "mtg_https": mtg["https"],
    }


def aggregated_b64():
    """Aggregate proxy URI links (mtproxy is TG-specific, kept separate)."""
    plain = "\n".join([vless_link(), hy2_link(), anytls_link(), tuic_link()])
    return base64.b64encode(plain.encode()).decode()


# ---------- Container status ----------
def container_status():
    targets = ["proxy-singbox", "proxy-mtg", "proxy-dashboard"]
    result = {}
    try:
        out = subprocess.run(
            ["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}|{{.State}}"],
            capture_output=True, text=True, timeout=5
        )
        rows = {}
        for line in out.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 3:
                rows[parts[0]] = {"status": parts[1], "state": parts[2]}
        for t in targets:
            if t in rows:
                result[t] = rows[t]
            else:
                result[t] = {"status": "not found", "state": "missing"}
    except Exception as e:
        for t in targets:
            result[t] = {"status": f"error: {e}", "state": "unknown"}
    return result


# ---------- Auth ----------
def check_auth(u, p):
    return u == DASH_USER and p == DASH_PASS and DASH_PASS != ""


def require_auth(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return Response(
                "Authentication required", 401,
                {"WWW-Authenticate": 'Basic realm="Proxy Dashboard"'}
            )
        return fn(*args, **kwargs)
    return wrapper


# ---------- Routes ----------
@app.route("/")
@require_auth
def index():
    return render_template(
        "index.html",
        cfg=CFG,
        links=all_links(),
        aggregated=aggregated_b64(),
        containers=container_status(),
        token=DASH_PASS,
        sub_url=f"/sub?token={DASH_PASS}",
    )


@app.route("/api/status")
@require_auth
def api_status():
    return jsonify(container_status())


@app.route("/qr")
@require_auth
def qr():
    """Return PNG QR code for ?text=..."""
    text = request.args.get("text", "")
    if not text:
        abort(400)
    img = qrcode.make(text)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@app.route("/sub")
def sub():
    """Subscription endpoint - token in query, returns base64."""
    token = request.args.get("token", "")
    if token != DASH_PASS or not DASH_PASS:
        abort(403)
    return Response(
        aggregated_b64(),
        mimetype="text/plain",
        headers={"Content-Disposition": "inline; filename=subscribe.txt"},
    )


@app.route("/sub/raw")
def sub_raw():
    """Plain-text aggregated links (one per line)."""
    token = request.args.get("token", "")
    if token != DASH_PASS or not DASH_PASS:
        abort(403)
    return Response(
        "\n".join([vless_link(), hy2_link(), anytls_link(), tuic_link()]),
        mimetype="text/plain",
    )


@app.route("/sub/clash")
def sub_clash():
    """Clash / Mihomo (Clash.Meta) YAML config."""
    token = request.args.get("token", "")
    if token != DASH_PASS or not DASH_PASS:
        abort(403)

    name_vless = f"{CFG['NODE_NAME']}-Reality"
    name_hy2 = f"{CFG['NODE_NAME']}-Hy2"
    name_tuic = f"{CFG['NODE_NAME']}-TUIC"

    yaml_text = f"""# Clash / Mihomo subscription
# Generated by proxy-stack dashboard
# Node: {CFG['NODE_NAME']}

proxies:
  - name: "{name_vless}"
    type: vless
    server: {CFG['SERVER_IP']}
    port: {CFG['VLESS_PORT']}
    uuid: {CFG['VLESS_UUID']}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {CFG['REALITY_SNI']}
    client-fingerprint: chrome
    reality-opts:
      public-key: {CFG['REALITY_PUBLIC_KEY']}
      short-id: {CFG['REALITY_SHORT_ID']}

  - name: "{name_hy2}"
    type: hysteria2
    server: {CFG['SERVER_IP']}
    port: {CFG['HY2_PORT']}
    password: {CFG['HY2_PASSWORD']}
    sni: bing.com
    skip-cert-verify: true
    alpn:
      - h3

  - name: "{name_tuic}"
    type: tuic
    server: {CFG['SERVER_IP']}
    port: {CFG['TUIC_PORT']}
    uuid: {CFG['TUIC_UUID']}
    password: {CFG['TUIC_PASSWORD']}
    sni: bing.com
    skip-cert-verify: true
    alpn:
      - h3
    congestion-controller: bbr
    udp-relay-mode: native

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "Auto"
      - "{name_vless}"
      - "{name_hy2}"
      - "{name_tuic}"
      - DIRECT

  - name: "Auto"
    type: url-test
    proxies:
      - "{name_vless}"
      - "{name_hy2}"
      - "{name_tuic}"
    url: "http://www.gstatic.com/generate_204"
    interval: 600
    tolerance: 50

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
"""
    return Response(yaml_text, mimetype="text/yaml")


@app.route("/sub/singbox")
def sub_singbox():
    """sing-box client config (JSON)."""
    token = request.args.get("token", "")
    if token != DASH_PASS or not DASH_PASS:
        abort(403)

    import json as _json
    cfg = {
        "log": {"level": "info"},
        "outbounds": [
            {
                "type": "selector",
                "tag": "PROXY",
                "outbounds": [
                    "Auto",
                    f"{CFG['NODE_NAME']}-Reality",
                    f"{CFG['NODE_NAME']}-Hy2",
                    f"{CFG['NODE_NAME']}-AnyTLS",
                    f"{CFG['NODE_NAME']}-TUIC",
                    "direct",
                ],
                "default": "Auto",
            },
            {
                "type": "urltest",
                "tag": "Auto",
                "outbounds": [
                    f"{CFG['NODE_NAME']}-Reality",
                    f"{CFG['NODE_NAME']}-Hy2",
                    f"{CFG['NODE_NAME']}-AnyTLS",
                    f"{CFG['NODE_NAME']}-TUIC",
                ],
                "url": "http://www.gstatic.com/generate_204",
                "interval": "10m",
                "tolerance": 50,
            },
            {
                "type": "vless",
                "tag": f"{CFG['NODE_NAME']}-Reality",
                "server": CFG["SERVER_IP"],
                "server_port": int(CFG["VLESS_PORT"]),
                "uuid": CFG["VLESS_UUID"],
                "flow": "xtls-rprx-vision",
                "tls": {
                    "enabled": True,
                    "server_name": CFG["REALITY_SNI"],
                    "utls": {"enabled": True, "fingerprint": "chrome"},
                    "reality": {
                        "enabled": True,
                        "public_key": CFG["REALITY_PUBLIC_KEY"],
                        "short_id": CFG["REALITY_SHORT_ID"],
                    },
                },
            },
            {
                "type": "hysteria2",
                "tag": f"{CFG['NODE_NAME']}-Hy2",
                "server": CFG["SERVER_IP"],
                "server_port": int(CFG["HY2_PORT"]),
                "password": CFG["HY2_PASSWORD"],
                "tls": {
                    "enabled": True,
                    "server_name": "bing.com",
                    "insecure": True,
                    "alpn": ["h3"],
                },
            },
            {
                "type": "anytls",
                "tag": f"{CFG['NODE_NAME']}-AnyTLS",
                "server": CFG["SERVER_IP"],
                "server_port": int(CFG["ANYTLS_PORT"]),
                "password": CFG["ANYTLS_PASSWORD"],
                "idle_session_check_interval": "30s",
                "idle_session_timeout": "30s",
                "min_idle_session": 5,
                "tls": {
                    "enabled": True,
                    "server_name": "bing.com",
                    "insecure": True,
                    "alpn": ["h2", "http/1.1"],
                },
            },
            {
                "type": "tuic",
                "tag": f"{CFG['NODE_NAME']}-TUIC",
                "server": CFG["SERVER_IP"],
                "server_port": int(CFG["TUIC_PORT"]),
                "uuid": CFG["TUIC_UUID"],
                "password": CFG["TUIC_PASSWORD"],
                "congestion_control": "bbr",
                "udp_relay_mode": "native",
                "zero_rtt_handshake": False,
                "heartbeat": "10s",
                "tls": {
                    "enabled": True,
                    "server_name": "bing.com",
                    "insecure": True,
                    "alpn": ["h3"],
                },
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "rules": [
                {"domain_suffix": [".cn"], "outbound": "direct"},
                {"geoip": ["cn", "private"], "outbound": "direct"},
            ],
            "final": "PROXY",
        },
    }
    return Response(
        _json.dumps(cfg, indent=2, ensure_ascii=False),
        mimetype="application/json",
    )


@app.route("/sub/shadowrocket")
def sub_shadowrocket():
    """Shadowrocket subscription (base64 of vless+hy2 links).
    Shadowrocket auto-detects this format from base64 content."""
    token = request.args.get("token", "")
    if token != DASH_PASS or not DASH_PASS:
        abort(403)
    return Response(
        aggregated_b64(),
        mimetype="text/plain",
    )


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
