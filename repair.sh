#!/bin/bash
# ============================================================
# 修复脚本 - 重建单个服务,不影响其他
# ============================================================

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*"; }

[ -f config.env ] || { err "config.env 不存在,请先部署"; exit 1; }

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

echo
echo "需要修复哪个服务?"
echo "  1) sing-box (VLESS-Reality + Hysteria2)"
echo "  2) mtg (Telegram MTProxy)"
echo "  3) dashboard (Web 面板)"
echo "  4) 全部三个"
echo "  5) 重新生成 sing-box 配置文件并重启 sing-box"
echo "  6) 重新生成 Hysteria2 自签证书"
echo "  0) 取消"
read -p "请选择 [0-6]: " choice

case "$choice" in
    1)
        log "停止 sing-box..."
        compose stop singbox 2>/dev/null || true
        compose rm -f singbox 2>/dev/null || true
        log "拉取最新镜像..."
        compose pull singbox
        log "启动 sing-box..."
        compose up -d singbox
        sleep 2
        compose ps singbox
        ok "sing-box 已重建"
        ;;
    2)
        log "停止 mtg..."
        compose stop mtg 2>/dev/null || true
        compose rm -f mtg 2>/dev/null || true
        log "拉取最新镜像..."
        compose pull mtg
        log "启动 mtg..."
        compose up -d mtg
        sleep 2
        compose ps mtg
        ok "mtg 已重建"
        ;;
    3)
        log "停止 dashboard..."
        compose stop dashboard 2>/dev/null || true
        compose rm -f dashboard 2>/dev/null || true
        log "重新构建并启动 dashboard..."
        compose up -d --build dashboard
        sleep 2
        compose ps dashboard
        ok "dashboard 已重建"
        ;;
    4)
        log "停止所有服务..."
        compose down
        log "拉取最新镜像..."
        compose pull
        log "重新构建并启动..."
        compose up -d --build
        sleep 3
        compose ps
        ok "全部服务已重建"
        ;;
    5)
        log "重新渲染 sing-box 配置..."
        # shellcheck disable=SC1091
        . ./config.env
        export SERVER_IP VLESS_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_SHORT_ID REALITY_SNI HY2_PORT HY2_PASSWORD
        envsubst < sing-box/config.json.tpl > sing-box/config.json
        if jq empty sing-box/config.json 2>/dev/null; then
            ok "JSON 合法"
        else
            err "渲染后的 JSON 不合法,中止"
            exit 1
        fi
        log "重启 sing-box..."
        compose restart singbox
        sleep 2
        compose ps singbox
        ok "sing-box 配置已重新渲染并重启"
        ;;
    6)
        log "重新生成 Hysteria2 自签证书..."
        rm -f sing-box/hy2.crt sing-box/hy2.key
        openssl ecparam -genkey -name prime256v1 -out sing-box/hy2.key 2>/dev/null
        openssl req -new -x509 -days 3650 -key sing-box/hy2.key \
            -out sing-box/hy2.crt -subj "/CN=bing.com" 2>/dev/null
        chmod 644 sing-box/hy2.crt sing-box/hy2.key
        ok "证书已重新生成"
        log "重启 sing-box..."
        compose restart singbox
        sleep 2
        ok "sing-box 已重启"
        warn "客户端不需要重新订阅(因为我们用 insecure=1,客户端不验证证书)"
        ;;
    0)
        echo "取消"
        exit 0
        ;;
    *)
        err "无效选项"
        exit 1
        ;;
esac
