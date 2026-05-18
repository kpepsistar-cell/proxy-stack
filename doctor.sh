#!/bin/bash
# Proxy Stack health check.

set +e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info() { echo -e "  ${BLUE}[INFO]${NC} $*"; }
section() { echo; echo -e "${BOLD}${CYAN}== $* ==${NC}"; }

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

check_tcp_port() {
    local port="$1" name="$2"
    [ -z "$port" ] && { warn "$name port is not configured"; return; }

    if ss -tlnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
        pass "$name TCP port $port is listening"
    else
        fail "$name TCP port $port is not listening"
    fi
}

check_udp_port() {
    local port="$1" name="$2"
    [ -z "$port" ] && { warn "$name port is not configured"; return; }

    if ss -ulnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
        pass "$name UDP port $port is listening"
    else
        fail "$name UDP port $port is not listening"
    fi
}

tcp_probe() {
    local port="$1" name="$2"
    [ -z "$port" ] && return

    if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        pass "Local TCP probe to $name port $port succeeded"
    else
        fail "Local TCP probe to $name port $port failed"
    fi
}

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  KStar Proxy Health Check"
echo "============================================================"
echo -e "${NC}"

section "1. System"

if [ "$(id -u)" -eq 0 ]; then
    pass "Running as root"
else
    warn "Not running as root; some checks may be incomplete"
fi

if has_cmd docker; then
    pass "Docker found: $(docker --version | head -1)"
else
    fail "Docker is not installed"
fi

if docker compose version >/dev/null 2>&1; then
    pass "docker compose v2 is available"
elif has_cmd docker-compose; then
    pass "docker-compose v1 is available"
else
    fail "Docker Compose is not available"
fi

for cmd in curl jq openssl ss; do
    if has_cmd "$cmd"; then
        pass "$cmd found"
    else
        warn "$cmd not found"
    fi
done

mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$((mem_used * 100 / mem_total))
    if [ "$mem_pct" -lt 85 ]; then
        pass "Memory usage ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
    else
        warn "High memory usage ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
    fi
fi

disk_pct=$(df -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
if [ -n "$disk_pct" ]; then
    if [ "$disk_pct" -lt 85 ]; then
        pass "Disk usage ${disk_pct}%"
    else
        warn "High disk usage ${disk_pct}%"
    fi
fi

section "2. Config"

if [ ! -f config.env ]; then
    fail "config.env not found. Run: bash deploy.sh"
    exit 1
fi

pass "config.env exists"
perm=$(stat -c %a config.env 2>/dev/null)
if [ "$perm" = "600" ]; then
    pass "config.env permission is 600"
else
    warn "config.env permission is $perm; recommended: chmod 600 config.env"
fi

# shellcheck disable=SC1091
. ./config.env

for var in SERVER_IP VLESS_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI HY2_PORT HY2_PASSWORD MTG_PORT MTG_SECRET DASHBOARD_PORT DASHBOARD_PASS; do
    if [ -n "${!var}" ]; then
        pass "$var is set"
    else
        fail "$var is missing"
    fi
done

if [ -n "${SERVER_HOST:-}" ]; then
    pass "SERVER_HOST is set to $SERVER_HOST"
else
    warn "SERVER_HOST is missing; links will fall back to SERVER_IP"
fi

for var in ANYTLS_PORT ANYTLS_PASSWORD TUIC_PORT TUIC_UUID TUIC_PASSWORD; do
    if [ -n "${!var}" ]; then
        pass "$var is set"
    else
        warn "$var is missing; run bash update.sh or bash deploy.sh to migrate old config.env"
    fi
done

if [ -L .env ] && [ "$(readlink .env)" = "config.env" ]; then
    pass ".env -> config.env link exists"
else
    warn ".env link is missing; docker compose may not read config.env"
fi

if [ -f sing-box/config.json ]; then
    if jq empty sing-box/config.json 2>/dev/null; then
        pass "sing-box/config.json is valid JSON"
    else
        fail "sing-box/config.json is invalid JSON"
    fi
else
    fail "sing-box/config.json not found"
fi

if [ -f sing-box/hy2.crt ] && [ -f sing-box/hy2.key ]; then
    pass "TLS certificate files exist"
else
    fail "TLS certificate files are missing"
fi

section "3. Containers"

for c in proxy-singbox proxy-mtg proxy-dashboard; do
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
    if [ "$state" = "running" ]; then
        restarts=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)
        uptime=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | cut -dT -f1,2 | tr T ' ' | cut -d. -f1)
        if [ "$restarts" -gt 5 ] 2>/dev/null; then
            warn "$c is running but restarted $restarts times"
        else
            pass "$c is running since $uptime"
        fi
    elif [ -z "$state" ]; then
        fail "$c container not found"
    else
        fail "$c state is $state"
    fi
done

section "4. Ports"

check_tcp_port "$VLESS_PORT" "VLESS-Reality"
check_udp_port "$HY2_PORT" "Hysteria2"
check_tcp_port "$ANYTLS_PORT" "AnyTLS"
check_udp_port "$TUIC_PORT" "TUIC"
check_tcp_port "$MTG_PORT" "MTProxy"
check_tcp_port "$DASHBOARD_PORT" "Dashboard"

section "5. Local Probes"

tcp_probe "$VLESS_PORT" "VLESS-Reality"
tcp_probe "$ANYTLS_PORT" "AnyTLS"
tcp_probe "$MTG_PORT" "MTProxy"

if timeout 3 curl -fsS -o /dev/null "http://127.0.0.1:${DASHBOARD_PORT}/health" 2>/dev/null; then
    pass "Dashboard /health returned ok"
else
    fail "Dashboard /health failed"
fi

section "6. Firewall"

if has_cmd ufw; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -qi inactive; then
        pass "ufw is inactive"
    else
        warn "ufw is active; allow TCP $VLESS_PORT,$ANYTLS_PORT,$MTG_PORT,$DASHBOARD_PORT and UDP $HY2_PORT,$TUIC_PORT"
    fi
else
    info "ufw not installed"
fi

if has_cmd iptables; then
    drop_rules=$(iptables -L INPUT -n 2>/dev/null | grep -cE 'DROP|REJECT')
    if [ "$drop_rules" -gt 0 ] 2>/dev/null; then
        warn "iptables INPUT has $drop_rules DROP/REJECT rules"
    else
        pass "No obvious iptables INPUT DROP/REJECT rules"
    fi
fi

section "7. Network"

if timeout 3 nslookup github.com 1.1.1.1 >/dev/null 2>&1; then
    pass "DNS lookup works"
else
    warn "DNS lookup failed"
fi

if timeout 5 curl -fsS -o /dev/null https://www.cloudflare.com 2>/dev/null; then
    pass "Outbound HTTPS works"
else
    warn "Outbound HTTPS failed"
fi

my_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
if [ -n "$my_ip" ]; then
    if [ "$my_ip" = "$SERVER_IP" ]; then
        pass "Public IPv4 matches config.env: $my_ip"
    else
        warn "Detected public IPv4 is $my_ip, but config.env has $SERVER_IP"
    fi
else
    warn "Could not detect public IPv4"
fi

if [ -n "$REALITY_SNI" ] && timeout 5 curl -fsS -o /dev/null "https://${REALITY_SNI}" 2>/dev/null; then
    pass "Reality SNI target is reachable: $REALITY_SNI"
else
    warn "Reality SNI target may not be reachable: $REALITY_SNI"
fi

section "8. BBR"

cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$cc" = "bbr" ]; then
    pass "BBR is active"
else
    warn "BBR is not active; current congestion control: ${cc:-unknown}"
fi

qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$qdisc" = "fq" ]; then
    pass "default_qdisc is fq"
else
    warn "default_qdisc is ${qdisc:-unknown}; fq is recommended for BBR"
fi

section "9. Recent Logs"

for c in proxy-singbox proxy-mtg proxy-dashboard; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
        err_count=$(docker logs --since 10m "$c" 2>&1 | grep -ciE 'error|fatal|panic' || echo 0)
        if [ "$err_count" -eq 0 ] 2>/dev/null; then
            pass "$c has no recent error/fatal/panic logs"
        else
            warn "$c has $err_count recent error/fatal/panic log lines; check: docker logs $c"
        fi
    fi
done

echo
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}Health check summary${NC}"
echo -e "  ${GREEN}PASS ${PASS_COUNT}${NC}  ${YELLOW}WARN ${WARN_COUNT}${NC}  ${RED}FAIL ${FAIL_COUNT}${NC}"
echo

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}Action needed:${NC}"
    echo "  - If config is missing or invalid: bash update.sh"
    echo "  - If containers are down: docker compose up -d --build"
    echo "  - If ports fail: check VPS firewall/security group and local ufw/iptables"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Warnings found, but core services may still be usable.${NC}"
else
    echo -e "${GREEN}All checks passed.${NC}"
fi
echo
