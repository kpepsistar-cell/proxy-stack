#!/bin/bash
# ============================================================
# Proxy Stack - Interactive Installer & Manager
# Repo: https://github.com/kpepsistar-cell/proxy-stack
#
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/kpepsistar-cell/proxy-stack/main/install.sh)
#   or after install:
#   proxy
# ============================================================

set -e

REPO_USER="kpepsistar-cell"
REPO_NAME="proxy-stack"
REPO_BRANCH="main"
INSTALL_DIR="/opt/proxy"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${REPO_BRANCH}"
GIT_URL="https://github.com/${REPO_USER}/${REPO_NAME}.git"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Logging ----------
log()  { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }
die()  { err "$*"; exit 1; }

# ---------- Pre-flight ----------
[ "$(id -u)" -eq 0 ] || die "Must run as root. Try: sudo bash install.sh"

# ---------- Compose helper ----------
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ---------- Install required tools ----------
install_prereqs() {
    if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        log "Installing prerequisites (git, curl)..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y git curl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y git curl >/dev/null 2>&1
        else
            die "Cannot install git/curl - unsupported OS"
        fi
    fi
}

# ---------- Fetch / update repo ----------
fetch_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "Updating existing repo at $INSTALL_DIR..."
        cd "$INSTALL_DIR"
        # Stash any local changes (user might have edited config.env)
        git stash --include-untracked >/dev/null 2>&1 || true
        git pull origin "$REPO_BRANCH" >/dev/null 2>&1 || warn "git pull failed, continuing with existing files"
        git stash pop >/dev/null 2>&1 || true
    elif [ -d "$INSTALL_DIR" ] && [ "$(ls -A $INSTALL_DIR 2>/dev/null)" ]; then
        log "$INSTALL_DIR exists but is not a git repo. Backing up to ${INSTALL_DIR}.bak..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
        git clone "$GIT_URL" "$INSTALL_DIR" >/dev/null 2>&1 || die "git clone failed"
    else
        log "Cloning repo to $INSTALL_DIR..."
        mkdir -p "$(dirname $INSTALL_DIR)"
        git clone "$GIT_URL" "$INSTALL_DIR" >/dev/null 2>&1 || die "git clone failed"
    fi
    cd "$INSTALL_DIR"
    chmod +x *.sh 2>/dev/null || true
    ok "Repo ready at $INSTALL_DIR"
}

# ---------- Symlink to /usr/local/bin/proxy ----------
install_shortcut() {
    local target="/usr/local/bin/proxy"
    if [ ! -L "$target" ] || [ "$(readlink $target)" != "$INSTALL_DIR/install.sh" ]; then
        ln -sf "$INSTALL_DIR/install.sh" "$target"
        chmod +x "$target"
        ok "Shortcut installed: run 'proxy' anywhere to open this menu"
    fi
}

# ============================================================
# Menu Actions
# ============================================================

action_deploy() {
    cd "$INSTALL_DIR"
    log "Running full deploy..."
    bash deploy.sh
}

action_info() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "Not deployed yet. Run option 1 first."; return; }
    bash info.sh
}

action_restart() {
    cd "$INSTALL_DIR"
    [ -f docker-compose.yml ] || { warn "Not deployed yet."; return; }
    log "Restarting services..."
    compose restart
    sleep 2
    compose ps
}

action_update() {
    cd "$INSTALL_DIR"
    log "Pulling latest from GitHub..."
    git stash --include-untracked >/dev/null 2>&1 || true
    git pull origin "$REPO_BRANCH" || warn "git pull had issues"
    git stash pop >/dev/null 2>&1 || true
    chmod +x *.sh

    log "Pulling latest docker images..."
    compose pull

    log "Rebuilding and restarting..."
    compose up -d --build

    sleep 2
    compose ps
    ok "Update complete"
}

action_change_port() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "Not deployed yet."; return; }

    echo
    echo "Current ports:"
    grep -E '_PORT=' config.env | sed 's/^/  /'
    echo
    echo "Which port to change?"
    echo "  1) VLESS-Reality (TCP)"
    echo "  2) Hysteria2 (UDP)"
    echo "  3) MTProxy (TCP)"
    echo "  4) Dashboard (TCP)"
    echo "  0) Cancel"
    read -p "Choice [0-4]: " choice

    local var=""
    case "$choice" in
        1) var="VLESS_PORT" ;;
        2) var="HY2_PORT" ;;
        3) var="MTG_PORT" ;;
        4) var="DASHBOARD_PORT" ;;
        0) return ;;
        *) warn "Invalid"; return ;;
    esac

    local current
    current=$(grep "^${var}=" config.env | cut -d= -f2)
    read -p "New port for $var (current: $current): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        err "Invalid port number"
        return
    fi

    sed -i "s|^${var}=.*|${var}=${new_port}|" config.env
    ok "Updated $var=$new_port"

    read -p "Re-deploy now? [Y/n] " confirm
    [[ ! "$confirm" =~ ^[Nn]$ ]] && bash deploy.sh
}

action_logs() {
    cd "$INSTALL_DIR"
    [ -f docker-compose.yml ] || { warn "Not deployed yet."; return; }
    echo
    echo "Which service's logs?"
    echo "  1) sing-box (VLESS + Hy2)"
    echo "  2) mtg (MTProxy)"
    echo "  3) dashboard"
    echo "  4) all"
    echo "  0) Cancel"
    read -p "Choice [0-4]: " choice
    case "$choice" in
        1) compose logs -f --tail=50 singbox ;;
        2) compose logs -f --tail=50 mtg ;;
        3) compose logs -f --tail=50 dashboard ;;
        4) compose logs -f --tail=20 ;;
        0) return ;;
        *) warn "Invalid" ;;
    esac
}

action_change_sni() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "Not deployed yet."; return; }

    local current
    current=$(grep "^REALITY_SNI=" config.env | cut -d= -f2)
    echo
    echo "Current Reality SNI: $current"
    echo
    echo "Common SNI options (must be a real HTTPS site that supports TLS 1.3):"
    echo "  1) www.microsoft.com    (default, very stable)"
    echo "  2) www.cloudflare.com   (CF, sometimes blocked in CN)"
    echo "  3) www.apple.com        (Apple)"
    echo "  4) addons.mozilla.org   (Mozilla)"
    echo "  5) www.amazon.com       (Amazon)"
    echo "  6) Custom (enter your own)"
    echo "  0) Cancel"
    read -p "Choice [0-6]: " choice

    local new_sni=""
    case "$choice" in
        1) new_sni="www.microsoft.com" ;;
        2) new_sni="www.cloudflare.com" ;;
        3) new_sni="www.apple.com" ;;
        4) new_sni="addons.mozilla.org" ;;
        5) new_sni="www.amazon.com" ;;
        6) read -p "Enter SNI domain (e.g., www.example.com): " new_sni ;;
        0) return ;;
        *) warn "Invalid"; return ;;
    esac

    [ -z "$new_sni" ] && { warn "Empty SNI"; return; }

    sed -i "s|^REALITY_SNI=.*|REALITY_SNI=${new_sni}|" config.env
    ok "Updated REALITY_SNI=$new_sni"
    log "Re-deploying to apply..."
    bash deploy.sh
    warn "All clients must re-import the VLESS link (SNI changed)."
}

action_regen_mtg_secret() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "Not deployed yet."; return; }

    log "Generating new mtg secret (hex format for iOS compatibility)..."
    local fake_host="www.cloudflare.com"
    local host_hex
    host_hex=$(echo -n "$fake_host" | od -An -tx1 | tr -d ' \n')
    local new_secret="ee$(openssl rand -hex 16)${host_hex}"

    sed -i "s|^MTG_SECRET=.*|MTG_SECRET=${new_secret}|" config.env
    ok "New secret: $new_secret"

    log "Restarting mtg..."
    compose up -d mtg

    sleep 2
    log "New Telegram links:"
    # shellcheck disable=SC1091
    . ./config.env
    echo "  tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${new_secret}"
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${new_secret}"
    warn "Re-add proxy in Telegram (delete old one first)."
}

action_bbr_status() {
    echo
    log "BBR / Network Tuning Status"
    echo "----------------------------------------"
    echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "Available:          $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    echo "Queue scheduler:    $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "TCP Fast Open:      $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    echo "rmem_max:           $(sysctl -n net.core.rmem_max 2>/dev/null) bytes"
    echo "wmem_max:           $(sysctl -n net.core.wmem_max 2>/dev/null) bytes"
    echo "----------------------------------------"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
        ok "BBR is active ✓"
    else
        warn "BBR is NOT active (current: $cc)"
        echo
        read -p "Enable BBR now? [Y/n] " confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            cd "$INSTALL_DIR"
            # Reuse deploy.sh's enable_bbr logic by running just that part
            # We'll source deploy.sh functions
            bash -c "source <(sed -n '/^enable_bbr()/,/^}/p' $INSTALL_DIR/deploy.sh) && enable_bbr"
        fi
    fi
}

action_uninstall() {
    cd "$INSTALL_DIR"
    [ -f uninstall.sh ] || { warn "uninstall.sh not found"; return; }
    bash uninstall.sh
}

# ============================================================
# Menu
# ============================================================

show_status_bar() {
    cd "$INSTALL_DIR" 2>/dev/null || return
    if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
        local running
        running=$(compose ps --status running 2>/dev/null | grep -c "proxy-" || echo "0")
        if [ "$running" = "3" ]; then
            echo -e "  ${GREEN}● Running${NC} (3/3 containers up)"
        elif [ "$running" -gt 0 ]; then
            echo -e "  ${YELLOW}● Partial${NC} ($running/3 containers up)"
        else
            echo -e "  ${RED}● Stopped${NC} (no containers running)"
        fi

        if [ -f config.env ]; then
            local ip
            ip=$(grep '^SERVER_IP=' config.env | cut -d= -f2)
            local dport
            dport=$(grep '^DASHBOARD_PORT=' config.env | cut -d= -f2)
            echo -e "  Dashboard: ${CYAN}http://${ip}:${dport}${NC}"
        fi
    else
        echo -e "  ${YELLOW}● Not deployed${NC}"
    fi
}

show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════╗
  ║       Proxy Stack — Manager                  ║
  ║       VLESS-Reality + Hysteria2 + MTProxy    ║
  ╚══════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    show_status_bar
    echo
    echo -e "  ${BOLD}Setup${NC}"
    echo "    1) Full deploy / Re-deploy"
    echo "    2) Show node info & subscription links"
    echo
    echo -e "  ${BOLD}Manage${NC}"
    echo "    3) Restart all services"
    echo "    4) Update to latest (pull from GitHub)"
    echo "    5) Change a port"
    echo "    6) View live logs"
    echo
    echo -e "  ${BOLD}Tweaks${NC}"
    echo "    7) Change Reality SNI"
    echo "    8) Regenerate Telegram MTProxy secret"
    echo "    9) Check / Enable BBR"
    echo
    echo -e "  ${BOLD}Other${NC}"
    echo "   10) Uninstall"
    echo "    0) Exit"
    echo
}

# ============================================================
# Main
# ============================================================

main() {
    install_prereqs
    fetch_repo
    install_shortcut

    while true; do
        show_menu
        read -p "  Choice [0-10]: " choice
        echo
        case "$choice" in
            1)  action_deploy ;;
            2)  action_info ;;
            3)  action_restart ;;
            4)  action_update ;;
            5)  action_change_port ;;
            6)  action_logs ;;
            7)  action_change_sni ;;
            8)  action_regen_mtg_secret ;;
            9)  action_bbr_status ;;
            10) action_uninstall ;;
            0)  echo "Bye!"; exit 0 ;;
            *)  warn "Invalid choice" ;;
        esac
        echo
        read -p "  Press Enter to return to menu..." _
    done
}

main "$@"
