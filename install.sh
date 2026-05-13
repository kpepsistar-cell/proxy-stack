#!/bin/bash
# ============================================================
# Proxy Stack - 交互式安装与管理菜单
# 仓库: https://github.com/kpepsistar-cell/proxy-stack
#
# 使用方法:
#   bash <(curl -sL https://raw.githubusercontent.com/kpepsistar-cell/proxy-stack/main/install.sh)
#   或安装后直接输入:
#   proxy
# ============================================================

set -e

REPO_USER="kpepsistar-cell"
REPO_NAME="proxy-stack"
REPO_BRANCH="main"
INSTALL_DIR="/opt/proxy"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${REPO_BRANCH}"
GIT_URL="https://github.com/${REPO_USER}/${REPO_NAME}.git"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 日志函数 ----------
log()  { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*"; }
die()  { err "$*"; exit 1; }

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限运行,请用: sudo bash install.sh"

# ---------- docker compose 兼容 ----------
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ---------- 安装基础工具 ----------
install_prereqs() {
    if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        log "安装基础工具(git、curl)..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y git curl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y git curl >/dev/null 2>&1
        else
            die "无法安装 git/curl,系统不支持"
        fi
    fi
}

# ---------- 拉取/更新仓库 ----------
fetch_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "更新本地仓库 $INSTALL_DIR..."
        cd "$INSTALL_DIR"
        git stash --include-untracked >/dev/null 2>&1 || true
        git pull origin "$REPO_BRANCH" >/dev/null 2>&1 || warn "git pull 失败,继续用现有文件"
        git stash pop >/dev/null 2>&1 || true
    elif [ -d "$INSTALL_DIR" ] && [ "$(ls -A $INSTALL_DIR 2>/dev/null)" ]; then
        log "$INSTALL_DIR 已存在但不是 git 仓库,备份到 ${INSTALL_DIR}.bak..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
        git clone "$GIT_URL" "$INSTALL_DIR" >/dev/null 2>&1 || die "git clone 失败"
    else
        log "克隆仓库到 $INSTALL_DIR..."
        mkdir -p "$(dirname $INSTALL_DIR)"
        git clone "$GIT_URL" "$INSTALL_DIR" >/dev/null 2>&1 || die "git clone 失败"
    fi
    cd "$INSTALL_DIR"
    chmod +x *.sh 2>/dev/null || true
    ok "仓库已就绪 ($INSTALL_DIR)"
}

# ---------- 创建 proxy 命令快捷方式 ----------
install_shortcut() {
    local target="/usr/local/bin/proxy"
    if [ ! -L "$target" ] || [ "$(readlink $target)" != "$INSTALL_DIR/install.sh" ]; then
        ln -sf "$INSTALL_DIR/install.sh" "$target"
        chmod +x "$target"
        ok "快捷命令已创建: 任何位置输入 'proxy' 都能呼出菜单"
    fi
}

# ============================================================
# 菜单操作
# ============================================================

action_deploy() {
    cd "$INSTALL_DIR"
    log "开始全自动部署..."
    bash deploy.sh
}

action_info() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "尚未部署,请先选 1) 全新部署"; return; }
    bash info.sh
}

action_restart() {
    cd "$INSTALL_DIR"
    [ -f docker-compose.yml ] || { warn "尚未部署"; return; }
    log "重启所有服务..."
    compose restart
    sleep 2
    compose ps
}

action_update() {
    cd "$INSTALL_DIR"
    log "从 GitHub 拉取最新版本..."
    git stash --include-untracked >/dev/null 2>&1 || true
    git pull origin "$REPO_BRANCH" || warn "git pull 出错"
    git stash pop >/dev/null 2>&1 || true
    chmod +x *.sh
    bash update.sh
    return

    log "拉取最新 docker 镜像..."
    compose pull

    log "重新构建并重启..."
    compose up -d --build

    sleep 2
    compose ps
    ok "更新完成"
}

action_change_port() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "尚未部署"; return; }

    echo
    echo "当前端口配置:"
    grep -E '_PORT=' config.env | sed 's/^/  /'
    echo
    echo "要修改哪个端口?"
    echo "  1) VLESS-Reality (TCP)"
    echo "  2) Hysteria2 (UDP)"
    echo "  3) AnyTLS (TCP)"
    echo "  4) TUIC (UDP)"
    echo "  5) MTProxy (TCP)"
    echo "  6) Dashboard (TCP)"
    echo "  0) Cancel"
    read -p "Select [0-6]: " choice

    local var=""
    case "$choice" in
        1) var="VLESS_PORT" ;;
        2) var="HY2_PORT" ;;
        3) var="ANYTLS_PORT" ;;
        4) var="TUIC_PORT" ;;
        5) var="MTG_PORT" ;;
        6) var="DASHBOARD_PORT" ;;
        0) return ;;
        *) warn "无效选项"; return ;;
    esac

    local current
    current=$(grep "^${var}=" config.env | cut -d= -f2)
    read -p "$var 的新端口(当前: $current): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        err "端口号无效"
        return
    fi

    sed -i "s|^${var}=.*|${var}=${new_port}|" config.env
    ok "已更新 $var=$new_port"

    read -p "现在重新部署应用更改?[Y/n] " confirm
    [[ ! "$confirm" =~ ^[Nn]$ ]] && bash deploy.sh
}

action_logs() {
    cd "$INSTALL_DIR"
    [ -f docker-compose.yml ] || { warn "尚未部署"; return; }
    echo
    echo "查看哪个服务的日志?"
    echo "  1) sing-box (VLESS + Hy2)"
    echo "  2) mtg (MTProxy)"
    echo "  3) dashboard (面板)"
    echo "  4) 全部"
    echo "  0) 取消"
    echo
    echo "提示: 按 Ctrl+C 退出日志查看"
    read -p "请选择 [0-4]: " choice
    case "$choice" in
        1) compose logs -f --tail=50 singbox ;;
        2) compose logs -f --tail=50 mtg ;;
        3) compose logs -f --tail=50 dashboard ;;
        4) compose logs -f --tail=20 ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

action_change_sni() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "尚未部署"; return; }

    local current
    current=$(grep "^REALITY_SNI=" config.env | cut -d= -f2)
    echo
    echo "当前 Reality 伪装域名: $current"
    echo
    echo "常用伪装域名(必须是真实存在且支持 TLS 1.3 的网站):"
    echo "  1) www.microsoft.com    (默认,稳定)"
    echo "  2) www.cloudflare.com   (CF,某些时候国内被墙)"
    echo "  3) www.apple.com        (苹果)"
    echo "  4) addons.mozilla.org   (Mozilla)"
    echo "  5) www.amazon.com       (亚马逊)"
    echo "  6) 自定义(自己输入)"
    echo "  0) 取消"
    read -p "请选择 [0-6]: " choice

    local new_sni=""
    case "$choice" in
        1) new_sni="www.microsoft.com" ;;
        2) new_sni="www.cloudflare.com" ;;
        3) new_sni="www.apple.com" ;;
        4) new_sni="addons.mozilla.org" ;;
        5) new_sni="www.amazon.com" ;;
        6) read -p "输入自定义域名(例如 www.example.com): " new_sni ;;
        0) return ;;
        *) warn "无效选项"; return ;;
    esac

    [ -z "$new_sni" ] && { warn "域名为空"; return; }

    sed -i "s|^REALITY_SNI=.*|REALITY_SNI=${new_sni}|" config.env
    ok "已更新 REALITY_SNI=$new_sni"
    log "重新部署应用更改..."
    bash deploy.sh
    warn "Reality SNI 已更改,所有客户端需要重新导入 VLESS 链接"
}

action_regen_mtg_secret() {
    cd "$INSTALL_DIR"
    [ -f config.env ] || { warn "尚未部署"; return; }

    log "生成新的 mtg 密钥(hex 格式,iOS 兼容)..."
    local fake_host="www.cloudflare.com"
    local host_hex
    host_hex=$(echo -n "$fake_host" | od -An -tx1 | tr -d ' \n')
    local new_secret="ee$(openssl rand -hex 16)${host_hex}"

    sed -i "s|^MTG_SECRET=.*|MTG_SECRET=${new_secret}|" config.env
    ok "新密钥: $new_secret"

    log "重启 mtg 容器..."
    compose up -d mtg

    sleep 2
    log "新的 Telegram 代理链接:"
    # shellcheck disable=SC1091
    . ./config.env
    echo "  tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${new_secret}"
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${new_secret}"
    warn "请在 Telegram 中删除旧代理后重新添加(完全关闭 Telegram 再点新链接)"
}

action_bbr_status() {
    echo
    log "BBR 加速 / 网络优化 状态"
    echo "----------------------------------------"
    echo "拥塞控制算法:   $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "可用算法:       $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    echo "队列调度器:     $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "TCP Fast Open:  $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    echo "接收缓冲区上限: $(sysctl -n net.core.rmem_max 2>/dev/null) bytes"
    echo "发送缓冲区上限: $(sysctl -n net.core.wmem_max 2>/dev/null) bytes"
    echo "----------------------------------------"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
        ok "BBR 已启用 ✓"
    else
        warn "BBR 未启用(当前: $cc)"
        echo
        read -p "现在启用 BBR?[Y/n] " confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            cd "$INSTALL_DIR"
            bash -c "source <(sed -n '/^enable_bbr()/,/^}/p' $INSTALL_DIR/deploy.sh) && enable_bbr"
        fi
    fi
}

action_uninstall() {
    cd "$INSTALL_DIR"
    [ -f uninstall.sh ] || { warn "uninstall.sh 不存在"; return; }
    bash uninstall.sh
}

action_doctor() {
    cd "$INSTALL_DIR"
    [ -f doctor.sh ] || { warn "doctor.sh 不存在,请先更新到最新版本(选 4)"; return; }
    bash doctor.sh
}

action_repair() {
    cd "$INSTALL_DIR"
    [ -f repair.sh ] || { warn "repair.sh 不存在,请先更新到最新版本(选 4)"; return; }
    bash repair.sh
}

action_tcp_tune() {
    cd "$INSTALL_DIR"
    [ -f tcp-tune.sh ] || { warn "tcp-tune.sh 不存在,请先更新到最新版本(选 4)"; return; }
    bash tcp-tune.sh
}

# ============================================================
# 菜单显示
# ============================================================

show_status_bar() {
    cd "$INSTALL_DIR" 2>/dev/null || return
    if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
        local running
        running=$(compose ps --status running 2>/dev/null | grep -c "proxy-" || echo "0")
        if [ "$running" = "3" ]; then
            echo -e "  状态: ${GREEN}● 运行中${NC} (3/3 容器正常)"
        elif [ "$running" -gt 0 ]; then
            echo -e "  状态: ${YELLOW}● 部分运行${NC} ($running/3 容器运行中)"
        else
            echo -e "  状态: ${RED}● 已停止${NC} (无容器运行)"
        fi

        if [ -f config.env ]; then
            local ip
            ip=$(grep '^SERVER_IP=' config.env | cut -d= -f2)
            local dport
            dport=$(grep '^DASHBOARD_PORT=' config.env | cut -d= -f2)
            echo -e "  面板地址: ${CYAN}http://${ip}:${dport}${NC}"
        fi
    else
        echo -e "  状态: ${YELLOW}● 未部署${NC}"
    fi
}

show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════╗
  ║       代理面板管理器                         ║
  ║       VLESS-Reality + Hysteria2 + MTProxy    ║
  ╚══════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    show_status_bar
    echo
    echo -e "  ${BOLD}部署${NC}"
    echo "    1) 全新部署 / 重新部署"
    echo "    2) 查看节点信息和订阅链接"
    echo
    echo -e "  ${BOLD}管理${NC}"
    echo "    3) 重启所有服务"
    echo "    4) 更新到最新版本"
    echo "    5) 修改端口"
    echo "    6) 查看实时日志"
    echo
    echo -e "  ${BOLD}调整${NC}"
    echo "    7) 切换 Reality 伪装域名"
    echo "    8) 重新生成 Telegram 代理密钥"
    echo "    9) 检查 / 启用 BBR 加速"
    echo
    echo -e "  ${BOLD}诊断与修复${NC}"
    echo "   11) 健康诊断(一键体检)"
    echo "   12) 修复服务(单服务重建)"
    echo "   13) 智能 TCP 调优(测速 + 缓冲分档)"
    echo
    echo -e "  ${BOLD}其他${NC}"
    echo "   10) 卸载"
    echo "    0) 退出"
    echo
}

# ============================================================
# 主循环
# ============================================================

main() {
    install_prereqs
    fetch_repo
    install_shortcut

    while true; do
        show_menu
        read -p "  请选择 [0-13]: " choice
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
            11) action_doctor ;;
            12) action_repair ;;
            13) action_tcp_tune ;;
            0)  echo "再见!"; exit 0 ;;
            *)  warn "无效选项,请输入 0-13" ;;
        esac
        echo
        read -p "  按 Enter 返回主菜单..." _
    done
}

main "$@"
