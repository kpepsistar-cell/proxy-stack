#!/bin/bash
# Print all node subscription links + QR codes

set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

[ -f config.env ] || { echo "config.env not found. Run deploy.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# URL encode (for node names)
urlencode() {
    local s="$1" out="" c
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    echo "$out"
}

NODE_TAG=$(urlencode "${NODE_NAME}")

# Build links
VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${NODE_TAG}-Reality"

HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?sni=bing.com&insecure=1#${NODE_TAG}-Hy2"

MTG_TG="tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"
MTG_HTTPS="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"

# QR helper
qr() {
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$1"
    else
        echo "(qrencode not installed, skipping QR)"
    fi
}

print_section() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

print_section "Server Info"
echo "  Node name : ${NODE_NAME}"
echo "  Public IP : ${SERVER_IP}"
echo

print_section "VLESS-Reality"
echo "  Port      : ${VLESS_PORT}"
echo "  UUID      : ${VLESS_UUID}"
echo "  PublicKey : ${REALITY_PUBLIC_KEY}"
echo "  ShortId   : ${REALITY_SHORT_ID}"
echo "  SNI       : ${REALITY_SNI}"
echo
echo -e "${GREEN}Subscribe link:${NC}"
echo "$VLESS_LINK"
echo
qr "$VLESS_LINK"
echo

print_section "Hysteria2"
echo "  Port      : ${HY2_PORT} (UDP)"
echo "  Password  : ${HY2_PASSWORD}"
echo "  SNI       : bing.com (insecure)"
echo
echo -e "${GREEN}Subscribe link:${NC}"
echo "$HY2_LINK"
echo
qr "$HY2_LINK"
echo

print_section "MTProxy (Telegram)"
echo "  Port      : ${MTG_PORT}"
echo "  Secret    : ${MTG_SECRET}"
echo
echo -e "${GREEN}Telegram links:${NC}"
echo "$MTG_TG"
echo "$MTG_HTTPS"
echo
qr "$MTG_HTTPS"
echo

print_section "Aggregated Subscription (base64)"
SUB_PLAIN=$(printf "%s\n%s\n" "$VLESS_LINK" "$HY2_LINK")
SUB_B64=$(echo -n "$SUB_PLAIN" | base64 -w 0 2>/dev/null || echo -n "$SUB_PLAIN" | base64)
echo "$SUB_B64"
echo
echo -e "${YELLOW}(Paste this base64 into clients that accept aggregated subscriptions)${NC}"
echo

print_section "Dashboard"
echo "  URL       : http://${SERVER_IP}:${DASHBOARD_PORT}"
echo "  User      : ${DASHBOARD_USER}"
echo "  Password  : ${DASHBOARD_PASS}"
echo
echo "  Subscribe URL (for clients): http://${SERVER_IP}:${DASHBOARD_PORT}/sub?token=${DASHBOARD_PASS}"
echo
