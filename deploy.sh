#!/bin/bash
# ============================================================
# Proxy Stack Deploy Script
# VLESS-Reality + Hysteria2 + mtg (MTProxy) + Dashboard
# Supports: Ubuntu 20.04+, Debian 11+, CentOS/Rocky/Alma 8+
# ============================================================

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }
die()  { err "$*"; exit 1; }

# ---------- Pre-flight ----------
[ "$(id -u)" -eq 0 ] || die "Must run as root. Try: sudo bash deploy.sh"

log "=== Proxy Stack Deploy ==="
log "Working dir: $SCRIPT_DIR"

# ---------- Detect OS ----------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_VER=$VERSION_ID
    log "Detected OS: $PRETTY_NAME"
else
    die "Cannot detect OS"
fi

case "$OS_ID" in
    ubuntu|debian)
        PKG_MGR="apt-get"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="apt-get install -y"
        ;;
    centos|rhel|rocky|almalinux)
        PKG_MGR="yum"
        PKG_UPDATE="yum makecache -y"
        PKG_INSTALL="yum install -y"
        ;;
    *)
        warn "Untested OS: $OS_ID. Will try Debian-style commands."
        PKG_MGR="apt-get"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="apt-get install -y"
        ;;
esac

# ---------- Detect existing conflicting services ----------
check_conflicts() {
    local conflicts=()

    # systemd sing-box
    if systemctl list-units --type=service --all 2>/dev/null | grep -q "sing-box.service"; then
        conflicts+=("systemd sing-box service")
    fi
    if [ -f /etc/s-box/sing-box ] || [ -d /etc/s-box ]; then
        conflicts+=("/etc/s-box (yonggekkk script residue)")
    fi
    if [ -d /etc/sing-box ]; then
        conflicts+=("/etc/sing-box (other sing-box install)")
    fi

    # Old mtproxy containers (different from ours)
    if command -v docker >/dev/null 2>&1; then
        local old_mtp
        old_mtp=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(mtproxy|tg-proxy|mtproto)$' | grep -v '^proxy-mtg$' || true)
        [ -n "$old_mtp" ] && conflicts+=("Old mtproxy container: $old_mtp")
    fi

    if [ ${#conflicts[@]} -gt 0 ]; then
        warn "Detected existing services that may conflict:"
        for c in "${conflicts[@]}"; do echo "    - $c"; done
        echo
        read -p "Clean them up before continuing? [y/N] " -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            cleanup_old
        else
            warn "Continuing without cleanup. Port conflicts may occur."
        fi
    fi
}

cleanup_old() {
    log "Cleaning old services..."

    # Stop and disable systemd sing-box
    if systemctl list-units --all 2>/dev/null | grep -q "sing-box.service"; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        ok "Removed systemd sing-box"
    fi

    # Remove s-box / sing-box dirs
    [ -d /etc/s-box ] && rm -rf /etc/s-box && ok "Removed /etc/s-box"
    [ -d /etc/sing-box ] && rm -rf /etc/sing-box && ok "Removed /etc/sing-box"

    # Remove old mtproxy containers
    if command -v docker >/dev/null 2>&1; then
        for name in mtproxy tg-proxy mtproto; do
            if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
                docker rm -f "$name" >/dev/null 2>&1 && ok "Removed container: $name"
            fi
        done
    fi
}

# ---------- BBR + sysctl tuning ----------
enable_bbr() {
    log "Enabling BBR + network tuning..."

    local kernel_major
    kernel_major=$(uname -r | cut -d. -f1)
    local kernel_minor
    kernel_minor=$(uname -r | cut -d. -f2)

    if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
        warn "Kernel $kernel_major.$kernel_minor is too old for BBR (need 4.9+). Skipping BBR."
        return
    fi

    # Remove old entries we previously added (idempotent)
    sed -i '/# >>> proxy-stack tuning >>>/,/# <<< proxy-stack tuning <<</d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<'EOF'

# >>> proxy-stack tuning >>>
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=2097152
net.core.wmem_default=2097152
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_forward=1
# <<< proxy-stack tuning <<<
EOF

    sysctl -p >/dev/null 2>&1 || warn "sysctl -p had warnings (usually safe to ignore)"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$cc" = "bbr" ]; then
        ok "BBR enabled (current: $cc)"
    else
        warn "BBR not active (current: $cc). May need reboot."
    fi
}

# ---------- Install Docker ----------
install_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "Docker already installed: $(docker --version)"
    else
        log "Installing Docker via get.docker.com..."
        curl -fsSL https://get.docker.com | sh || die "Docker install failed"
        systemctl enable --now docker
        ok "Docker installed: $(docker --version)"
    fi

    # Compose plugin (v2)
    if docker compose version >/dev/null 2>&1; then
        ok "docker compose v2 available"
    elif command -v docker-compose >/dev/null 2>&1; then
        ok "docker-compose v1 available (will use 'docker-compose')"
    else
        log "Installing docker compose plugin..."
        case "$OS_ID" in
            ubuntu|debian)
                $PKG_INSTALL docker-compose-plugin || {
                    warn "Plugin install failed, falling back to standalone"
                    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                        -o /usr/local/bin/docker-compose
                    chmod +x /usr/local/bin/docker-compose
                }
                ;;
            *)
                curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                    -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
                ;;
        esac
    fi
}

# ---------- Helper to call compose ----------
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ---------- Install required tools ----------
install_tools() {
    log "Installing required tools..."
    $PKG_UPDATE >/dev/null 2>&1 || true
    $PKG_INSTALL curl wget jq openssl ca-certificates gettext-base qrencode >/dev/null 2>&1 || {
        # gettext-base is Debian/Ubuntu name; on RHEL it's gettext
        $PKG_INSTALL curl wget jq openssl ca-certificates gettext qrencode >/dev/null 2>&1 || true
    }
    ok "Tools installed"
}

# ---------- Detect public IP ----------
detect_ip() {
    local ip
    ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
         curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || \
         curl -4 -s --max-time 5 ipv4.icanhazip.com 2>/dev/null || true)
    if [ -z "$ip" ]; then
        warn "Cannot auto-detect public IPv4. Will try IPv6."
        ip=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || true)
    fi
    [ -z "$ip" ] && die "Cannot detect public IP. Set SERVER_IP manually in config.env"
    echo "$ip"
}

# ---------- Generate config.env if not exists ----------
gen_config() {
    if [ -f config.env ]; then
        log "Existing config.env found, loading..."
        # shellcheck disable=SC1091
        . ./config.env
        ok "Loaded config (keys preserved)"
        return
    fi

    log "Generating fresh config.env..."

    local server_ip
    server_ip=$(detect_ip)
    log "Public IP: $server_ip"

    # VLESS UUID
    local vless_uuid
    vless_uuid=$(cat /proc/sys/kernel/random/uuid)

    # Reality keypair (use sing-box image to generate)
    log "Generating Reality keypair..."
    local reality_keys
    reality_keys=$(docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair 2>/dev/null) \
        || die "Failed to generate Reality keypair"
    local reality_private
    reality_private=$(echo "$reality_keys" | grep -i 'PrivateKey' | awk '{print $2}')
    local reality_public
    reality_public=$(echo "$reality_keys" | grep -i 'PublicKey' | awk '{print $2}')
    local reality_short_id
    reality_short_id=$(openssl rand -hex 8)

    # Hysteria2 password
    local hy2_password
    hy2_password=$(openssl rand -hex 16)

    # mtg secret in HEX format (ee + 16 random bytes + hex-encoded fake host).
    # mtg v2 generate-secret outputs base64, but Telegram iOS only accepts hex.
    # We construct hex secret manually for cross-client compatibility.
    log "Generating mtg secret (hex format for iOS compatibility)..."
    local mtg_fake_host="www.cloudflare.com"
    local mtg_host_hex
    # Use od (always present in coreutils), fallback to xxd if od fails
    mtg_host_hex=$(echo -n "$mtg_fake_host" | od -An -tx1 | tr -d ' \n' 2>/dev/null) \
        || mtg_host_hex=$(echo -n "$mtg_fake_host" | xxd -p | tr -d '\n')
    local mtg_secret
    mtg_secret="ee$(openssl rand -hex 16)${mtg_host_hex}"
    [ -z "$mtg_host_hex" ] && die "Failed to hex-encode fake host"
    log "mtg secret length: ${#mtg_secret} (expected ~70)"

    # Dashboard password
    local dash_pass
    dash_pass=$(openssl rand -hex 12)

    cat > config.env <<EOF
# ============================================================
# Proxy Stack Configuration
# Generated: $(date)
# ============================================================
# !!! KEEP THIS FILE SAFE - Contains keys/passwords !!!

# Server
SERVER_IP=$server_ip
NODE_NAME=$(hostname)

# VLESS-Reality
VLESS_PORT=443
VLESS_UUID=$vless_uuid
REALITY_PRIVATE_KEY=$reality_private
REALITY_PUBLIC_KEY=$reality_public
REALITY_SHORT_ID=$reality_short_id
REALITY_SNI=www.microsoft.com

# Hysteria2
HY2_PORT=8443
HY2_PASSWORD=$hy2_password

# MTProxy (mtg)
MTG_PORT=8888
MTG_SECRET=$mtg_secret
MTG_FAKE_HOST=www.cloudflare.com

# Dashboard
DASHBOARD_PORT=2053
DASHBOARD_USER=admin
DASHBOARD_PASS=$dash_pass
EOF

    chmod 600 config.env
    ok "Generated config.env (permissions 600)"
    # shellcheck disable=SC1091
    . ./config.env
}

# ---------- Render sing-box config ----------
render_singbox_config() {
    log "Rendering sing-box config..."
    # shellcheck disable=SC1091
    . ./config.env
    export SERVER_IP VLESS_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_SHORT_ID REALITY_SNI \
           HY2_PORT HY2_PASSWORD

    envsubst < sing-box/config.json.tpl > sing-box/config.json

    # Validate JSON
    if ! jq empty sing-box/config.json 2>/dev/null; then
        die "Generated sing-box/config.json is invalid JSON"
    fi
    ok "sing-box config rendered"
}

# ---------- Generate Hysteria2 self-signed cert ----------
gen_hy2_cert() {
    if [ -f sing-box/hy2.crt ] && [ -f sing-box/hy2.key ]; then
        ok "Hysteria2 cert exists, skipping"
        return
    fi
    log "Generating Hysteria2 self-signed cert..."
    openssl ecparam -genkey -name prime256v1 -out sing-box/hy2.key 2>/dev/null
    openssl req -new -x509 -days 3650 -key sing-box/hy2.key \
        -out sing-box/hy2.crt -subj "/CN=bing.com" 2>/dev/null
    chmod 644 sing-box/hy2.crt sing-box/hy2.key
    ok "Hysteria2 cert generated"
}

# ---------- Start services ----------
start_services() {
    log "Pulling images..."
    compose pull

    log "Starting services..."
    compose up -d

    sleep 3

    log "Service status:"
    compose ps
}

# ---------- Health check ----------
health_check() {
    log "Running health checks..."
    sleep 2

    local fail=0
    # shellcheck disable=SC1091
    . ./config.env

    # Container running
    for c in proxy-singbox proxy-mtg proxy-dashboard; do
        if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
            ok "Container $c: running"
        else
            err "Container $c: NOT running"
            fail=1
        fi
    done

    # Port listening
    if ss -tlnp 2>/dev/null | grep -q ":${VLESS_PORT} "; then
        ok "VLESS port $VLESS_PORT: listening"
    else
        warn "VLESS port $VLESS_PORT: not listening"
    fi
    if ss -ulnp 2>/dev/null | grep -q ":${HY2_PORT} "; then
        ok "Hysteria2 port $HY2_PORT (UDP): listening"
    else
        warn "Hysteria2 port $HY2_PORT (UDP): not listening"
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${MTG_PORT} "; then
        ok "mtg port $MTG_PORT: listening"
    else
        warn "mtg port $MTG_PORT: not listening"
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${DASHBOARD_PORT} "; then
        ok "Dashboard port $DASHBOARD_PORT: listening"
    else
        warn "Dashboard port $DASHBOARD_PORT: not listening"
    fi

    return $fail
}

# ---------- Ensure docker compose reads config.env ----------
# docker compose only auto-loads .env, not config.env, so symlink them
ensure_env_link() {
    if [ ! -L .env ] || [ "$(readlink .env)" != "config.env" ]; then
        ln -sf config.env .env
        ok ".env -> config.env (so docker compose reads our vars)"
    fi
}

# ---------- Main ----------
main() {
    check_conflicts
    install_tools
    enable_bbr
    install_docker
    gen_config
    ensure_env_link
    gen_hy2_cert
    render_singbox_config
    start_services
    health_check || warn "Some health checks failed. Check logs with: bash info.sh"

    echo
    echo "============================================================"
    ok "Deploy complete!"
    echo "============================================================"
    echo
    log "View subscription links and QR codes:"
    echo "    bash info.sh"
    echo
    # shellcheck disable=SC1091
    . ./config.env
    log "Dashboard:"
    echo "    URL:      http://${SERVER_IP}:${DASHBOARD_PORT}"
    echo "    User:     ${DASHBOARD_USER}"
    echo "    Password: ${DASHBOARD_PASS}"
    echo
    warn "Save the dashboard password - it's also in config.env"
    echo
}

main "$@"
