#!/bin/bash
# ============================================================
# 健康诊断脚本 - 一键体检 VPS 和代理服务的健康状况
# ============================================================

set +e  # 诊断时不要因为某项失败就退出

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 颜色
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

pass() { echo -e "  ${GREEN}✓${NC} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info() { echo -e "  ${BLUE}ℹ${NC} $*"; }
section() { echo; echo -e "${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ============================================================
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════╗
  ║         健康诊断 / Health Check               ║
  ╚══════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ---------- 1. 基础环境 ----------
section "1. 基础环境"

if [ "$(id -u)" -eq 0 ]; then
    pass "Root 权限"
else
    warn "非 root 用户运行,部分检查可能失败"
fi

if command -v docker >/dev/null 2>&1; then
    pass "Docker 已安装: $(docker --version | head -1)"
else
    fail "Docker 未安装"
fi

if docker compose version >/dev/null 2>&1; then
    pass "docker compose v2 可用"
elif command -v docker-compose >/dev/null 2>&1; then
    pass "docker-compose v1 可用"
else
    fail "docker compose 未安装"
fi

# 系统资源
mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$((mem_used * 100 / mem_total))
    if [ "$mem_pct" -lt 80 ]; then
        pass "内存使用 ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
    else
        warn "内存使用偏高 ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
    fi
fi

disk_pct=$(df -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
if [ -n "$disk_pct" ]; then
    if [ "$disk_pct" -lt 80 ]; then
        pass "根分区使用率 ${disk_pct}%"
    else
        warn "根分区使用率偏高 ${disk_pct}%"
    fi
fi

# ---------- 2. 配置文件 ----------
section "2. 配置文件"

if [ -f config.env ]; then
    pass "config.env 存在"
    perm=$(stat -c %a config.env 2>/dev/null)
    if [ "$perm" = "600" ]; then
        pass "config.env 权限 600(安全)"
    else
        warn "config.env 权限 $perm(建议改成 600: chmod 600 config.env)"
    fi
    # shellcheck disable=SC1091
    . ./config.env

    # 检查关键字段不为空
    for var in SERVER_IP VLESS_UUID REALITY_PRIVATE_KEY HY2_PASSWORD MTG_SECRET DASHBOARD_PASS; do
        if [ -z "${!var}" ]; then
            fail "$var 为空"
        fi
    done

    # mtg secret 必须是 hex 格式(ee 开头)
    if [[ "$MTG_SECRET" =~ ^ee[0-9a-f]{60,}$ ]]; then
        pass "mtg secret 是 hex 格式(iOS 兼容)"
    else
        warn "mtg secret 不是标准 hex 格式(iOS Telegram 可能连不上)"
    fi
else
    fail "config.env 不存在,尚未部署"
    exit 1
fi

if [ -L .env ] && [ "$(readlink .env)" = "config.env" ]; then
    pass ".env -> config.env 软链正确"
else
    warn ".env 软链异常,docker compose 可能读不到变量"
fi

if [ -f sing-box/config.json ]; then
    if jq empty sing-box/config.json 2>/dev/null; then
        pass "sing-box/config.json 是合法 JSON"
    else
        fail "sing-box/config.json 格式错误"
    fi
else
    fail "sing-box/config.json 不存在"
fi

if [ -f sing-box/hy2.crt ] && [ -f sing-box/hy2.key ]; then
    pass "Hysteria2 自签证书存在"
else
    fail "Hysteria2 证书缺失"
fi

# ---------- 3. 容器状态 ----------
section "3. 容器状态"

for c in proxy-singbox proxy-mtg proxy-dashboard; do
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
    if [ "$state" = "running" ]; then
        # 检查 restart count
        restarts=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)
        uptime=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | cut -dT -f1,2 | tr T ' ' | cut -d. -f1)
        if [ "$restarts" -gt 5 ] 2>/dev/null; then
            warn "$c 运行中,但重启了 $restarts 次(可能不稳定)"
        else
            pass "$c 运行中(自 $uptime)"
        fi
    elif [ "$state" = "restarting" ]; then
        fail "$c 正在重启(配置可能有问题,看日志)"
    elif [ -z "$state" ]; then
        fail "$c 容器不存在"
    else
        fail "$c 状态: $state"
    fi
done

# ---------- 4. 端口监听 ----------
section "4. 端口监听"

check_tcp_port() {
    local port=$1 name=$2
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        pass "$name TCP 端口 $port 监听中"
    else
        fail "$name TCP 端口 $port 未监听"
    fi
}

check_udp_port() {
    local port=$1 name=$2
    if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        pass "$name UDP 端口 $port 监听中"
    else
        fail "$name UDP 端口 $port 未监听"
    fi
}

check_tcp_port "$VLESS_PORT" "VLESS-Reality"
check_udp_port "$HY2_PORT" "Hysteria2"
check_tcp_port "$MTG_PORT" "mtproxy"
check_tcp_port "$DASHBOARD_PORT" "Dashboard"

# ---------- 5. 本机自连测试 ----------
section "5. 本机自连测试"

if timeout 3 bash -c "</dev/tcp/127.0.0.1/$VLESS_PORT" 2>/dev/null; then
    pass "本机 TCP 连 VLESS 端口成功"
else
    fail "本机 TCP 连 VLESS 端口失败"
fi

if timeout 3 bash -c "</dev/tcp/127.0.0.1/$MTG_PORT" 2>/dev/null; then
    pass "本机 TCP 连 mtproxy 端口成功"
else
    fail "本机 TCP 连 mtproxy 端口失败"
fi

if timeout 3 curl -s -o /dev/null "http://127.0.0.1:$DASHBOARD_PORT/health" 2>/dev/null; then
    pass "Dashboard /health 接口响应正常"
else
    fail "Dashboard /health 接口无响应"
fi

# ---------- 6. 防火墙 ----------
section "6. 防火墙"

if command -v ufw >/dev/null 2>&1; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -q inactive; then
        pass "ufw inactive(全放行)"
    else
        warn "ufw active,确认放行了 $VLESS_PORT/tcp $HY2_PORT/udp $MTG_PORT/tcp $DASHBOARD_PORT/tcp"
        for p in $VLESS_PORT $MTG_PORT $DASHBOARD_PORT; do
            if ufw status | grep -qE "^$p(/tcp)?\s+ALLOW"; then
                pass "  ufw 放行 TCP $p"
            else
                fail "  ufw 没放行 TCP $p"
            fi
        done
        if ufw status | grep -qE "^$HY2_PORT(/udp)?\s+ALLOW"; then
            pass "  ufw 放行 UDP $HY2_PORT"
        else
            fail "  ufw 没放行 UDP $HY2_PORT"
        fi
    fi
fi

# iptables DROP/REJECT 检查
drop_rules=$(iptables -L INPUT -n 2>/dev/null | grep -cE 'DROP|REJECT')
if [ "$drop_rules" -gt 0 ] 2>/dev/null; then
    warn "iptables INPUT 链有 $drop_rules 条 DROP/REJECT 规则,可能影响连通性"
else
    pass "iptables INPUT 无 DROP/REJECT 规则"
fi

# ---------- 7. 网络连通 ----------
section "7. 出站连通"

# 测 DNS
if timeout 3 nslookup github.com 1.1.1.1 >/dev/null 2>&1; then
    pass "DNS 查询正常(1.1.1.1)"
else
    warn "DNS 查询失败"
fi

# 测 HTTPS 出站
if timeout 5 curl -fsS -o /dev/null https://www.cloudflare.com 2>/dev/null; then
    pass "HTTPS 出站正常(cloudflare.com)"
else
    warn "HTTPS 出站异常"
fi

# 测公网 IP
my_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
if [ -n "$my_ip" ]; then
    if [ "$my_ip" = "$SERVER_IP" ]; then
        pass "当前公网 IP $my_ip(与 config.env 一致)"
    else
        warn "当前公网 IP $my_ip,但 config.env 写的 $SERVER_IP(IP 变了?)"
    fi
fi

# 测 Reality SNI 域名是否可达
if timeout 5 curl -fsS -o /dev/null "https://${REALITY_SNI}" 2>/dev/null; then
    pass "Reality 伪装域名 $REALITY_SNI 可达"
else
    warn "Reality 伪装域名 $REALITY_SNI 不可达,Reality 握手会失败!"
fi

# ---------- 8. BBR 状态 ----------
section "8. BBR / 网络优化"

cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$cc" = "bbr" ]; then
    pass "BBR 已启用"
else
    warn "BBR 未启用(当前: $cc)"
fi

qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$qdisc" = "fq" ]; then
    pass "队列调度器 fq(BBR 推荐)"
else
    warn "队列调度器 $qdisc(BBR 推荐 fq)"
fi

rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
if [ "$rmem" -ge 16777216 ] 2>/dev/null; then
    pass "TCP 接收缓冲区 $((rmem/1024/1024))MB"
else
    warn "TCP 接收缓冲区偏小: $((rmem/1024/1024))MB"
fi

# ---------- 9. 容器近期错误日志 ----------
section "9. 容器近期错误"

for c in proxy-singbox proxy-mtg proxy-dashboard; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
        err_count=$(docker logs --since 10m "$c" 2>&1 | grep -ciE 'error|fatal|panic' || echo 0)
        if [ "$err_count" -eq 0 ] 2>/dev/null; then
            pass "$c 近 10 分钟无错误日志"
        else
            warn "$c 近 10 分钟有 $err_count 条错误日志(查看: docker logs $c)"
        fi
    fi
done

# ---------- 总结 ----------
echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}诊断结果汇总:${NC}"
echo -e "  ${GREEN}通过 ${PASS_COUNT}${NC}  ${YELLOW}警告 ${WARN_COUNT}${NC}  ${RED}失败 ${FAIL_COUNT}${NC}"
echo

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}建议:${NC} 有 $FAIL_COUNT 项失败,优先解决。常见操作:"
    echo "  - 容器没起来: proxy → 选 6) 查看日志"
    echo "  - 配置文件缺失: proxy → 选 1) 重新部署"
    echo "  - 端口冲突: proxy → 选 5) 修改端口"
    echo "  - 出站异常: 检查 Vultr Firewall Group / 系统 ufw"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}提示:${NC} 有 $WARN_COUNT 项警告,可以正常使用,有空时优化"
else
    echo -e "${GREEN}所有检查通过 ✓${NC}"
fi
echo
