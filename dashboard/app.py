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
        "mtg_tg":    mtg["tg"],
        "mtg_https": mtg["https"],
    }


def aggregated_b64():
    """Aggregate VLESS + Hy2 (mtproxy is TG-specific, kept separate)."""
    plain = "\n".join([vless_link(), hy2_link()])
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
        "\n".join([vless_link(), hy2_link()]),
        mimetype="text/plain",
    )


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
