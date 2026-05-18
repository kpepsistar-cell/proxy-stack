#!/bin/bash
# ============================================================
# 智能 TCP 调优 - 根据实测带宽推荐 TCP 缓冲区大小
# 借鉴 speed-slayer 的分档思路
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*"; }

# ---------- 安装 speedtest ----------
install_speedtest() {
    if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
        return 0
    fi
    log "安装 speedtest-cli..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y speedtest-cli >/dev/null 2>&1 || {
            warn "apt 安装失败,尝试 pip..."
            pip3 install speedtest-cli >/dev/null 2>&1 || \
                pip install speedtest-cli >/dev/null 2>&1 || true
        }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y speedtest-cli >/dev/null 2>&1 || true
    fi
}

# ---------- 测速 ----------
run_speedtest() {
    log "运行 Ookla speedtest 测试上传带宽(约 30 秒)..."
    local upload_mbps=""

    if command -v speedtest >/dev/null 2>&1; then
        upload_mbps=$(speedtest --simple 2>/dev/null | awk '/Upload/{print int($2)}')
    elif command -v speedtest-cli >/dev/null 2>&1; then
        upload_mbps=$(speedtest-cli --simple 2>/dev/null | awk '/Upload/{print int($2)}')
    fi

    if [ -z "$upload_mbps" ] || [ "$upload_mbps" -lt 1 ] 2>/dev/null; then
        warn "测速失败,使用默认值 100 Mbps"
        upload_mbps=100
    fi
    echo "$upload_mbps"
}

# ---------- 推荐缓冲区 ----------
recommend_buffer() {
    local bw=$1  # Mbps
    local mem_total
    mem_total=$(free -m | awk '/^Mem:/{print $2}')

    # 根据带宽分档(MB)
    local rec_mb
    if   [ "$bw" -le 100 ];   then rec_mb=16
    elif [ "$bw" -le 500 ];   then rec_mb=32
    elif [ "$bw" -le 1000 ];  then rec_mb=64
    elif [ "$bw" -le 2500 ];  then rec_mb=128
    else                            rec_mb=256
    fi

    # 内存保护:缓冲区不超过总内存 1/8
    local max_by_mem=$((mem_total / 8))
    if [ "$rec_mb" -gt "$max_by_mem" ] && [ "$max_by_mem" -gt 0 ]; then
        warn "内存仅 ${mem_total}MB,从 ${rec_mb}MB 降级到 ${max_by_mem}MB"
        rec_mb=$max_by_mem
    fi

    # 至少 16MB
    [ "$rec_mb" -lt 16 ] && rec_mb=16

    echo "$rec_mb"
}

# ---------- 主流程 ----------
echo -e "${BOLD}智能 TCP 调优${NC}"
echo

# 当前状态
cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
cur_rmem_mb=$((cur_rmem / 1024 / 1024))

echo "当前状态:"
echo "  拥塞控制: $cur_cc"
echo "  队列调度: $cur_qdisc"
echo "  接收缓冲: ${cur_rmem_mb}MB"
echo

# 选择带宽来源
echo "如何确定上传带宽?"
echo "  1) 自动测速(推荐,约 30 秒)"
echo "  2) 手动输入(已知带宽时)"
echo "  3) 跳过测速,使用通用配置(64MB 缓冲)"
echo "  0) 取消"
read -p "请选择 [0-3]: " choice

upload_mbps=""
case "$choice" in
    1)
        install_speedtest
        upload_mbps=$(run_speedtest)
        ok "实测上传带宽: ${upload_mbps} Mbps"
        ;;
    2)
        read -p "请输入上传带宽(Mbps,纯数字): " upload_mbps
        if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -lt 1 ]; then
            err "无效带宽值"
            exit 1
        fi
        ;;
    3)
        upload_mbps=500
        log "使用通用配置(假设 500 Mbps)"
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

# 推荐缓冲
rec_mb=$(recommend_buffer "$upload_mbps")
rec_bytes=$((rec_mb * 1024 * 1024))

echo
echo "推荐配置:"
echo "  上传带宽: ${upload_mbps} Mbps"
echo "  TCP 缓冲: ${rec_mb}MB($rec_bytes bytes)"
echo

read -p "应用此配置?[Y/n] " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "取消"
    exit 0
fi

# ---------- 应用配置 ----------
log "更新 /etc/sysctl.conf..."

# 删旧的 proxy-stack tuning 块
sed -i '/# >>> proxy-stack tuning >>>/,/# <<< proxy-stack tuning <<</d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<EOF

# >>> proxy-stack tuning >>>
# 上传带宽: ${upload_mbps} Mbps,智能分档: ${rec_mb}MB
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=$rec_bytes
net.core.wmem_max=$rec_bytes
net.core.rmem_default=2097152
net.core.wmem_default=2097152
net.ipv4.tcp_rmem=4096 87380 $rec_bytes
net.ipv4.tcp_wmem=4096 65536 $rec_bytes
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.ip_forward=1
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
# <<< proxy-stack tuning <<<
EOF

log "应用 sysctl..."
sysctl -p >/dev/null 2>&1 || warn "部分参数应用警告(通常无害)"

# ---------- 验证 ----------
echo
log "验证新配置:"
new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
new_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
new_rmem_mb=$((new_rmem / 1024 / 1024))

if [ "$new_cc" = "bbr" ]; then
    ok "BBR 已启用"
else
    warn "BBR 未启用,当前 $new_cc(可能内核太老,需要 4.9+)"
fi

if [ "$new_rmem_mb" -ge "$rec_mb" ] 2>/dev/null; then
    ok "TCP 缓冲已设置为 ${new_rmem_mb}MB"
else
    warn "TCP 缓冲实际 ${new_rmem_mb}MB,低于预期(系统可能拒绝过大值)"
fi

echo
ok "TCP 调优完成"
echo
warn "提示:已建立的连接还用旧参数,下次新连接才生效。如要立即生效全部连接,可重启容器:"
echo "    proxy → 选 3) 重启所有服务"
