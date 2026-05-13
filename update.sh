#!/bin/bash
# Pull latest images and restart

set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
NC='\033[0m'

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

ensure_config_defaults() {
    [ -f config.env ] || return 0
    local changed=0

    if ! grep -q '^ANYTLS_PORT=' config.env; then
        echo "ANYTLS_PORT=9443" >> config.env
        changed=1
    fi
    if ! grep -q '^ANYTLS_PASSWORD=' config.env; then
        echo "ANYTLS_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')" >> config.env
        changed=1
    fi
    if ! grep -q '^TUIC_PORT=' config.env; then
        echo "TUIC_PORT=9444" >> config.env
        changed=1
    fi
    if ! grep -q '^TUIC_UUID=' config.env; then
        echo "TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)" >> config.env
        changed=1
    fi
    if ! grep -q '^TUIC_PASSWORD=' config.env; then
        echo "TUIC_PASSWORD=$(openssl rand -hex 16)" >> config.env
        changed=1
    fi

    [ "$changed" -eq 1 ] && chmod 600 config.env
}

render_singbox_config() {
    [ -f config.env ] || return 0
    [ -f sing-box/config.json.tpl ] || return 0

    ensure_config_defaults
    # shellcheck disable=SC1091
    . ./config.env
    export SERVER_IP VLESS_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_SHORT_ID REALITY_SNI \
           HY2_PORT HY2_PASSWORD ANYTLS_PORT ANYTLS_PASSWORD TUIC_PORT TUIC_UUID TUIC_PASSWORD

    envsubst < sing-box/config.json.tpl > sing-box/config.json
    jq empty sing-box/config.json
}

echo -e "${GREEN}[1/3]${NC} Pulling latest images..."
compose pull

echo -e "${GREEN}[2/4]${NC} Rendering sing-box config..."
render_singbox_config

echo -e "${GREEN}[3/4]${NC} Rebuilding dashboard..."
compose build dashboard

echo -e "${GREEN}[4/4]${NC} Restarting services..."
compose up -d

sleep 2
compose ps

echo
echo -e "${GREEN}Update complete.${NC}"
echo "Run 'bash info.sh' to see node info."
