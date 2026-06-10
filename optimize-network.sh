#!/usr/bin/env bash
#
# optimize-network.sh - 网络优化诊断与对比工具
# 用法: ./optimize-network.sh [SSH目标地址] [SSH用户名]
# 默认: xylon@192.168.1.10
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
HISTORY_FILE="${DATA_DIR}/history.json"

# 默认值
SSH_TARGET="${1:-192.168.1.10}"
SSH_USER="${2:-xylon}"
SSH_HOST="${SSH_USER}@${SSH_TARGET}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════

print_header() {
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}==========================================${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}--- $1 ---${NC}"
}

print_ok() { echo -e "${GREEN}✅ $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_err() { echo -e "${RED}❌ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }

parse_ping_summary() {
    local output="$1"
    local packet_line=$(echo "$output" | grep 'packets transmitted' || true)
    local rtt_line=$(echo "$output" | grep 'round-trip' || true)
    
    local transmitted=$(echo "$packet_line" | grep -o '[0-9]* packets transmitted' | awk '{print $1}')
    local received=$(echo "$packet_line" | grep -o '[0-9]* received' | awk '{print $1}')
    local loss=$(echo "$packet_line" | grep -o '[0-9.]*% packet loss' | sed 's/% packet loss//')
    
    local min_rtt=""
    local avg_rtt=""
    local max_rtt=""
    local stddev=""
    
    if [ -n "$rtt_line" ]; then
        local rtt_vals=$(echo "$rtt_line" | awk -F' = ' '{print $2}' | awk '{print $1}')
        min_rtt=$(echo "$rtt_vals" | cut -d'/' -f1)
        avg_rtt=$(echo "$rtt_vals" | cut -d'/' -f2)
        max_rtt=$(echo "$rtt_vals" | cut -d'/' -f3)
        stddev=$(echo "$rtt_vals" | cut -d'/' -f4)
    fi
    
    echo "${transmitted:-0}|${received:-0}|${loss:-100}|${min_rtt:-0}|${avg_rtt:-0}|${max_rtt:-0}|${stddev:-0}"
}

format_time() {
    local time_str="$1"
    local time_min=$(echo "$time_str" | grep -o '[0-9]*m' | sed 's/m//' || echo "0")
    local time_sec=$(echo "$time_str" | grep -o '[0-9.]*s' | sed 's/s//' || echo "0")
    python3 -c "print(f'{int(${time_min}) * 60 + float(${time_sec}):.3f}')" 2>/dev/null || echo "${time_sec}"
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

trend_arrow() {
    local old="$1"
    local new="$2"
    local lower_is_better="${3:-1}"
    
    if [ -z "$old" ] || [ -z "$new" ] || [ "$old" = "N/A" ] || [ "$new" = "N/A" ]; then
        echo ""
        return
    fi
    
    local diff
    diff=$(python3 -c "print(f'{$new - $old:+.2f}')" 2>/dev/null || echo "?")
    
    if [ "$diff" = "?" ]; then
        echo ""
        return
    fi
    
    if [ "$lower_is_better" = "1" ]; then
        if (( $(echo "$new < $old" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${GREEN}↓${diff}${NC}"
        elif (( $(echo "$new > $old" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${RED}↑${diff}${NC}"
        else
            echo -e "→0"
        fi
    else
        if (( $(echo "$new > $old" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${GREEN}↑${diff}${NC}"
        elif (( $(echo "$new < $old" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${RED}↓${diff}${NC}"
        else
            echo -e "→0"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
# WiFi 检测 - 只返回数据，不输出
# ═══════════════════════════════════════════════════════════════

detect_wifi() {
    local wifi_info=""
    local phy=""
    local channel_raw=""
    local channel=""
    local band=""
    local bw=""
    local signal=""
    local noise=""
    local tx_rate=""
    local ip=""
    
    # 获取 IP
    ip=$(ifconfig en0 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "")
    
    # 获取 WiFi 详情
    wifi_info=$(system_profiler SPAirPortDataType 2>/dev/null | grep -A20 "Current Network Information" | head -25 || true)
    
    if [ -n "$wifi_info" ]; then
        phy=$(echo "$wifi_info" | grep 'PHY Mode:' | head -1 | sed 's/.*PHY Mode: *//' | tr -d ' ')
        channel_raw=$(echo "$wifi_info" | grep 'Channel:' | head -1 | sed 's/.*Channel: *//' | tr -d ' ')
        signal=$(echo "$wifi_info" | grep 'Signal / Noise:' | head -1 | sed 's/.*Signal \/ Noise: *//' | awk '{print $1}')
        noise=$(echo "$wifi_info" | grep 'Signal / Noise:' | head -1 | sed 's/.*Signal \/ Noise: *//' | awk '{print $4}')
        tx_rate=$(echo "$wifi_info" | grep 'Transmit Rate:' | head -1 | sed 's/.*Transmit Rate: *//' | tr -d ' ')
        
        # 解析信道和频段
        if [ -n "$channel_raw" ]; then
            if echo "$channel_raw" | grep -q "5GHz"; then
                band="5GHz"
            elif echo "$channel_raw" | grep -q "2GHz"; then
                band="2GHz"
            else
                band="unknown"
            fi
            bw=$(echo "$channel_raw" | grep -o '[0-9]*MHz' || echo "")
            channel=$(echo "$channel_raw" | grep -o '^[0-9]*')
        fi
    fi
    
    # 返回结构化数据: key=value 格式，每行一个
    cat <<EOF
phy=$phy
channel=$channel
band=$band
bandwidth=$bw
signal=$signal
noise=$noise
tx_rate=$tx_rate
ip=$ip
EOF
}

# ═══════════════════════════════════════════════════════════════
# Ping 测试 - 只返回数据，不输出
# ═══════════════════════════════════════════════════════════════

run_ping_test() {
    local target="$1"
    local count="${2:-30}"
    
    local output
    output=$(ping -c "$count" -i 0.2 "$target" 2>&1) || true
    
    local parsed
    parsed=$(parse_ping_summary "$output")
    
    local transmitted=$(echo "$parsed" | cut -d'|' -f1)
    local received=$(echo "$parsed" | cut -d'|' -f2)
    local loss=$(echo "$parsed" | cut -d'|' -f3)
    local min_rtt=$(echo "$parsed" | cut -d'|' -f4)
    local avg_rtt=$(echo "$parsed" | cut -d'|' -f5)
    local max_rtt=$(echo "$parsed" | cut -d'|' -f6)
    local stddev=$(echo "$parsed" | cut -d'|' -f7)
    
    echo "loss=$loss|min=$min_rtt|avg=$avg_rtt|max=$max_rtt|stddev=$stddev"
}

# ═══════════════════════════════════════════════════════════════
# SSH 测试 - 只返回数据，不输出
# ═══════════════════════════════════════════════════════════════

run_ssh_test() {
    local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    # 测试首次连接
    local first_time=""
    local start_ts
    start_ts=$(date -j +%s.%N 2>/dev/null || python3 -c "import time; print(f'{time.time():.6f}')" 2>/dev/null || date +%s)
    if ssh -o ControlMaster=no -o ControlPath=none -o GSSAPIAuthentication=no \
        $ssh_opts "$SSH_HOST" "echo 'SSH_OK'" >/dev/null 2>&1; then
        local end_ts
        end_ts=$(date -j +%s.%N 2>/dev/null || python3 -c "import time; print(f'{time.time():.6f}')" 2>/dev/null || date +%s)
        # 用 python3 计算差值（兼容浮点）
        first_time=$(python3 -c "
s = float('${start_ts}')
e = float('${end_ts}')
diff = e - s
if diff >= 60:
    m = int(diff // 60)
    sec = diff % 60
    print(f'{m}m{sec:.3f}s')
else:
    print(f'0m{diff:.3f}s')
" 2>/dev/null) || first_time="${start_ts}s"
    fi

    # 测试传输速度
    local xfer_time=""
    start_ts=$(date -j +%s.%N 2>/dev/null || python3 -c "import time; print(f'{time.time():.6f}')" 2>/dev/null || date +%s)
    if dd if=/dev/zero bs=1024 count=10240 2>/dev/null | \
        ssh $ssh_opts "$SSH_HOST" "cat > /dev/null" >/dev/null 2>&1; then
        end_ts=$(date -j +%s.%N 2>/dev/null || python3 -c "import time; print(f'{time.time():.6f}')" 2>/dev/null || date +%s)
        xfer_time=$(python3 -c "
s = float('${start_ts}')
e = float('${end_ts}')
diff = e - s
if diff >= 60:
    m = int(diff // 60)
    sec = diff % 60
    print(f'{m}m{sec:.3f}s')
else:
    print(f'0m{diff:.3f}s')
" 2>/dev/null) || xfer_time="${start_ts}s"
    fi

    echo "first=$first_time|xfer=$xfer_time"
}

# ═══════════════════════════════════════════════════════════════
# 输出格式化
# ═══════════════════════════════════════════════════════════════

print_wifi_status() {
    local data="$1"
    local phy=$(echo "$data" | grep '^phy=' | cut -d'=' -f2)
    local channel=$(echo "$data" | grep '^channel=' | cut -d'=' -f2)
    local band=$(echo "$data" | grep '^band=' | cut -d'=' -f2)
    local bw=$(echo "$data" | grep '^bandwidth=' | cut -d'=' -f2)
    local signal=$(echo "$data" | grep '^signal=' | cut -d'=' -f2)
    local noise=$(echo "$data" | grep '^noise=' | cut -d'=' -f2)
    local tx_rate=$(echo "$data" | grep '^tx_rate=' | cut -d'=' -f2)
    local ip=$(echo "$data" | grep '^ip=' | cut -d'=' -f2)
    
    print_section "WiFi 连接状态"
    echo "IP 地址: ${ip:-未知}"
    echo "PHY 模式: ${phy:-未知}"
    echo "信道: ${channel:-未知} (${band:-未知}, ${bw:-未知})"
    echo "信号强度: ${signal:-未知} dBm / ${noise:-未知} dBm"
    echo "传输速率: ${tx_rate:-未知} Mbps"
}

print_ping_result() {
    local label="$1"
    local data="$2"
    
    local loss=$(echo "$data" | cut -d'|' -f1 | cut -d'=' -f2)
    local min=$(echo "$data" | cut -d'|' -f2 | cut -d'=' -f2)
    local avg=$(echo "$data" | cut -d'|' -f3 | cut -d'=' -f2)
    local max=$(echo "$data" | cut -d'|' -f4 | cut -d'=' -f2)
    local stddev=$(echo "$data" | cut -d'|' -f5 | cut -d'=' -f2)
    
    print_section "$label"
    if [ -n "$loss" ] && (( $(echo "$loss > 0" | bc -l 2>/dev/null || echo "0") )); then
        print_err "丢包率: ${loss}%"
    else
        print_ok "丢包率: ${loss}%"
    fi
    echo "延迟: min=${min}ms avg=${avg}ms max=${max}ms stddev=${stddev}ms"
}

print_ssh_result() {
    local data="$1"
    local first=$(echo "$data" | cut -d'|' -f1 | cut -d'=' -f2)
    local xfer=$(echo "$data" | cut -d'|' -f2 | cut -d'=' -f2)
    
    print_section "SSH 连接速度 (${SSH_HOST})"
    
    if [ -n "$first" ]; then
        print_ok "首次连接: ${first}"
    else
        print_err "SSH 首次连接失败"
    fi
    
    if [ -n "$xfer" ]; then
        local xfer_sec
        xfer_sec=$(format_time "$xfer")
        local speed
        speed=$(python3 -c "print(f'{10.0 / float($xfer_sec):.1f}')" 2>/dev/null || echo "?")
        print_ok "10MB 传输: ${xfer} (~${speed} MB/s)"
    else
        print_err "传输测试失败"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 分析建议
# ═══════════════════════════════════════════════════════════════

generate_advice() {
    local wifi_data="$1"
    local router_ping="$2"
    local server_ping="$3"
    
    local phy=$(echo "$wifi_data" | grep '^phy=' | cut -d'=' -f2)
    local channel=$(echo "$wifi_data" | grep '^channel=' | cut -d'=' -f2)
    local band=$(echo "$wifi_data" | grep '^band=' | cut -d'=' -f2)
    local bw=$(echo "$wifi_data" | grep '^bandwidth=' | cut -d'=' -f2)
    local signal=$(echo "$wifi_data" | grep '^signal=' | cut -d'=' -f2)
    local tx_rate=$(echo "$wifi_data" | grep '^tx_rate=' | cut -d'=' -f2)
    
    local router_loss=$(echo "$router_ping" | cut -d'|' -f1 | cut -d'=' -f2)
    local router_avg=$(echo "$router_ping" | cut -d'|' -f3 | cut -d'=' -f2)
    local server_loss=$(echo "$server_ping" | cut -d'|' -f1 | cut -d'=' -f2)
    local server_avg=$(echo "$server_ping" | cut -d'|' -f3 | cut -d'=' -f2)
    
    local issues=()
    local suggestions=()
    
    print_header "💡 诊断分析与优化建议"
    
    # 1. 频段分析
    if [ "$band" = "2GHz" ]; then
        issues+=("当前连接 2.4GHz 频段，通常拥堵严重")
        suggestions+=("切换到 5GHz 频段（如果路由器支持）")
    elif [ "$band" = "5GHz" ]; then
        print_ok "已使用 5GHz 频段，避开了 2.4GHz 拥堵"
    fi
    
    # 2. 带宽分析
    if [ "$bw" = "80MHz" ]; then
        issues+=("当前使用 80MHz 带宽，容易受同频干扰")
        suggestions+=("尝试改为 40MHz 带宽，牺牲一点速率换取更稳定的延迟")
    elif [ "$bw" = "40MHz" ]; then
        print_ok "已使用 40MHz 带宽，延迟更稳定"
    elif [ "$bw" = "20MHz" ]; then
        print_warn "当前使用 20MHz 带宽，速率较低"
        suggestions+=("如果路由器支持，可尝试 40MHz 带宽")
    fi
    
    # 3. 信道分析
    if [ -n "$channel" ]; then
        if [ "$band" = "5GHz" ]; then
            local ch_num=$((channel))
            if [ "$ch_num" -ge 100 ] && [ "$ch_num" -le 140 ]; then
                issues+=("Channel ${channel} 是 DFS 信道，雷达活动时可能跳频断流")
                suggestions+=("如果频繁断流，换到 36-48 范围（非 DFS）")
            elif [ "$ch_num" -ge 149 ] && [ "$ch_num" -le 165 ]; then
                print_ok "Channel ${channel} 位于 5GHz 高频段，通常干扰较少"
            elif [ "$ch_num" -ge 36 ] && [ "$ch_num" -le 48 ]; then
                print_ok "Channel ${channel} 位于 5GHz 低频段，干扰较少"
            else
                print_info "Channel ${channel} 为 5GHz 信道，建议定期监控干扰情况"
            fi
        elif [ "$band" = "2GHz" ]; then
            local ch_num=$((channel))
            if [ "$ch_num" = "1" ] || [ "$ch_num" = "6" ] || [ "$ch_num" = "11" ]; then
                print_ok "Channel ${channel} 是 2.4GHz 标准非重叠信道"
            elif [ "$ch_num" -ge 2 ] && [ "$ch_num" -le 5 ]; then
                issues+=("Channel ${channel} 在 2.4GHz 重叠区域（与信道 1 干扰）")
                suggestions+=("换到 Channel 1、6 或 11")
            elif [ "$ch_num" -ge 7 ] && [ "$ch_num" -le 10 ]; then
                issues+=("Channel ${channel} 在 2.4GHz 重叠区域（与信道 6 干扰）")
                suggestions+=("换到 Channel 1、6 或 11")
            elif [ "$ch_num" -ge 12 ] && [ "$ch_num" -le 13 ]; then
                issues+=("Channel ${channel} 在 2.4GHz 重叠区域（与信道 11 干扰）")
                suggestions+=("换到 Channel 1、6 或 11")
            else
                print_info "Channel ${channel} 为 2.4GHz 信道，建议优先用 1/6/11"
            fi
        fi
    fi
    
    # 4. 信号强度分析
    if [ -n "$signal" ] && [ "$signal" != "未知" ]; then
        local signal_abs=$(echo "$signal" | sed 's/-//')
        # signal_abs 是信号强度的绝对值（去掉负号），值越大信号越弱
        if (( $(echo "$signal_abs > 70" | bc -l 2>/dev/null || echo "0") )); then
            issues+=("信号较弱 (${signal} dBm)")
            suggestions+=("靠近路由器或减少遮挡物")
        elif (( $(echo "$signal_abs > 60" | bc -l 2>/dev/null || echo "0") )); then
            print_warn "信号中等 (${signal} dBm)，建议靠近路由器"
        else
            print_ok "信号强度良好 (${signal} dBm)"
        fi
    fi
    
    # 5. 速率分析（基于 PHY 模式动态判断）
    if [ -n "$tx_rate" ] && [ "$tx_rate" != "未知" ]; then
        local max_rate=0
        case "$phy" in
            *n*)
                case "$bw" in
                    20MHz) max_rate=72 ;;
                    40MHz) max_rate=150 ;;
                    *) max_rate=150 ;;
                esac
                ;;
            *ac*)
                case "$bw" in
                    40MHz)  max_rate=270 ;;
                    80MHz)  max_rate=433 ;;
                    160MHz) max_rate=867 ;;
                    *)      max_rate=433 ;;
                esac
                ;;
            *ax*)
                case "$bw" in
                    40MHz)  max_rate=287 ;;
                    80MHz)  max_rate=600 ;;
                    160MHz) max_rate=1200 ;;
                    *)      max_rate=600 ;;
                esac
                ;;
            *)
                max_rate=300  # 未知 PHY 模式，保守估计
                ;;
        esac
        # 实际速率低于理论最大值 60% 才提示
        local threshold=$(python3 -c "print(int(${max_rate} * 0.6))" 2>/dev/null || echo "${max_rate}")
        if (( $(echo "$tx_rate < ${threshold}" | bc -l 2>/dev/null || echo "0") )); then
            issues+=("实际速率 (${tx_rate} Mbps) 低于理论最大值 (${max_rate} Mbps) 的 60%")
            suggestions+=("检查信道干扰、路由器负载，或尝试更换信道")
        else
            print_ok "传输速率 (${tx_rate} Mbps) 正常（理论最大 ${max_rate} Mbps）"
        fi
    fi
    
    # 6. 丢包分析
    if [ -n "$router_loss" ] && (( $(echo "$router_loss > 0" | bc -l 2>/dev/null || echo "0") )); then
        issues+=("到路由器丢包 ${router_loss}%，WiFi 连接不稳定")
        suggestions+=("优先解决 WiFi 信号问题，或检查路由器负载")
    fi
    
    if [ -n "$server_loss" ] && (( $(echo "$server_loss > 0" | bc -l 2>/dev/null || echo "0") )); then
        issues+=("到服务器丢包 ${server_loss}%")
        suggestions+=("排查路由器到服务器的有线链路")
    fi
    
    # 7. 延迟分析
    if [ -n "$server_avg" ] && [ "$server_avg" != "0" ] && (( $(echo "$server_avg > 50" | bc -l 2>/dev/null || echo "0") )); then
        issues+=("到服务器延迟偏高 (${server_avg}ms)")
        suggestions+=("优化 WiFi 信道和带宽设置")
    fi
    
    # 输出问题列表
    echo ""
    if [ ${#issues[@]} -eq 0 ]; then
        print_ok "当前网络状态良好，无明显问题！"
    else
        echo -e "${YELLOW}${BOLD}发现的问题:${NC}"
        for i in "${!issues[@]}"; do
            echo -e "  ${RED}$((i+1)). ${issues[$i]}${NC}"
        done
        
        echo ""
        echo -e "${GREEN}${BOLD}优化建议:${NC}"
        local unique_suggestions=()
        local seen=""
        for s in "${suggestions[@]}"; do
            if [[ "$seen" != *"|${s}|"* ]]; then
                unique_suggestions+=("$s")
                seen="${seen}|${s}|"
            fi
        done
        for i in "${!unique_suggestions[@]}"; do
            echo -e "  ${CYAN}$((i+1)). ${unique_suggestions[$i]}${NC}"
        done
    fi
    
    if [ ${#issues[@]} -gt 0 ]; then
        echo ""
        echo -e "${BOLD}TP-LINK 路由器操作路径:${NC}"
        echo "  1. 浏览器访问 http://tplinkwifi.net 或 http://192.168.0.1"
        echo "  2. 登录后进入「无线设置」→「5G 无线设置」"
        echo "  3. 修改信道和频道带宽，保存重启"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 数据持久化
# ═══════════════════════════════════════════════════════════════

save_results() {
    local wifi_data="$1"
    local router_ping="$2"
    local modem_ping="$3"
    local server_ping="$4"
    local ssh_data="$5"
    
    local ts=$(timestamp)
    
    # 提取字段
    local phy=$(echo "$wifi_data" | grep '^phy=' | cut -d'=' -f2)
    local channel=$(echo "$wifi_data" | grep '^channel=' | cut -d'=' -f2)
    local band=$(echo "$wifi_data" | grep '^band=' | cut -d'=' -f2)
    local bw=$(echo "$wifi_data" | grep '^bandwidth=' | cut -d'=' -f2)
    local signal=$(echo "$wifi_data" | grep '^signal=' | cut -d'=' -f2)
    local noise=$(echo "$wifi_data" | grep '^noise=' | cut -d'=' -f2)
    local tx_rate=$(echo "$wifi_data" | grep '^tx_rate=' | cut -d'=' -f2)
    local ip=$(echo "$wifi_data" | grep '^ip=' | cut -d'=' -f2)
    
    local r_loss=$(echo "$router_ping" | cut -d'|' -f1 | cut -d'=' -f2)
    local r_avg=$(echo "$router_ping" | cut -d'|' -f3 | cut -d'=' -f2)
    local m_loss=$(echo "$modem_ping" | cut -d'|' -f1 | cut -d'=' -f2)
    local m_avg=$(echo "$modem_ping" | cut -d'|' -f3 | cut -d'=' -f2)
    local s_loss=$(echo "$server_ping" | cut -d'|' -f1 | cut -d'=' -f2)
    local s_avg=$(echo "$server_ping" | cut -d'|' -f3 | cut -d'=' -f2)
    
    local ssh_first=$(echo "$ssh_data" | cut -d'|' -f1 | cut -d'=' -f2)
    local ssh_xfer=$(echo "$ssh_data" | cut -d'|' -f2 | cut -d'=' -f2)
    
    local json_entry=$(cat <<EOF
  {
    "timestamp": "$ts",
    "wifi": {
      "phy": "$phy",
      "channel": "$channel",
      "band": "$band",
      "bandwidth": "$bw",
      "signal_dbm": "$signal",
      "noise_dbm": "$noise",
      "tx_rate_mbps": "$tx_rate",
      "ip": "$ip"
    },
    "ping": {
      "router": { "loss_pct": "$r_loss", "avg_ms": "$r_avg" },
      "modem": { "loss_pct": "$m_loss", "avg_ms": "$m_avg" },
      "server": { "loss_pct": "$s_loss", "avg_ms": "$s_avg" }
    },
    "ssh": {
      "first_connect": "$ssh_first",
      "xfer_10mb": "$ssh_xfer"
    }
  }
EOF
)
    
    if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
        # 使用 python3 安全地追加 JSON（避免 sed 文本操作损坏文件）
        local entry_tmp=$(mktemp)
        echo "$json_entry" > "$entry_tmp"
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
with open(sys.argv[2]) as f:
    entry = json.load(f)
data.append(entry)
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" "$HISTORY_FILE" "$entry_tmp" 2>/dev/null
        local rc=$?
        rm -f "$entry_tmp"
        if [ $rc -ne 0 ]; then
            echo "⚠️ JSON 保存失败，请检查 data/history.json" >&2
        fi
    else
        echo "[
${json_entry}
]" > "$HISTORY_FILE"
    fi
    
    print_info "结果已保存到: $HISTORY_FILE"
}

# ═══════════════════════════════════════════════════════════════
# 对比报告
# ═══════════════════════════════════════════════════════════════

show_comparison() {
    local current_wifi="$1"
    local current_router="$2"
    local current_modem="$3"
    local current_server="$4"
    local current_ssh="$5"
    
    if [ ! -f "$HISTORY_FILE" ]; then
        return
    fi
    
    local history_count
    history_count=$(python3 -c "
import json
try:
    with open('$HISTORY_FILE') as f:
        data = json.load(f)
    print(len(data))
except:
    print(0)
" 2>/dev/null || echo "0")
    
    if [ "$history_count" -lt 2 ]; then
        echo ""
        print_info "首次运行，暂无历史数据对比。修改网络设置后再次运行可看到对比。"
        return
    fi
    
    local prev_data
    prev_data=$(python3 -c "
import json
with open('$HISTORY_FILE') as f:
    data = json.load(f)
print(json.dumps(data[-2]))
" 2>/dev/null || echo "{}")
    
    if [ "$prev_data" = "{}" ]; then
        return
    fi
    
    print_header "📊 与上一次的对比"

    # 提取当前数据
    local cur_ch=$(echo "$current_wifi" | grep '^channel=' | cut -d'=' -f2)
    local cur_bw=$(echo "$current_wifi" | grep '^bandwidth=' | cut -d'=' -f2)
    local cur_sig=$(echo "$current_wifi" | grep '^signal=' | cut -d'=' -f2)
    local cur_tx=$(echo "$current_wifi" | grep '^tx_rate=' | cut -d'=' -f2)
    local cur_r_loss=$(echo "$current_router" | cut -d'|' -f1 | cut -d'=' -f2)
    local cur_r_avg=$(echo "$current_router" | cut -d'|' -f3 | cut -d'=' -f2)
    local cur_s_loss=$(echo "$current_server" | cut -d'|' -f1 | cut -d'=' -f2)
    local cur_s_avg=$(echo "$current_server" | cut -d'|' -f3 | cut -d'=' -f2)

    # 提取上一次数据
    local prev_ch=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('wifi',{}).get('channel',''))" 2>/dev/null || echo "")
    local prev_bw=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('wifi',{}).get('bandwidth',''))" 2>/dev/null || echo "")
    local prev_sig=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('wifi',{}).get('signal_dbm',''))" 2>/dev/null || echo "")
    local prev_tx=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('wifi',{}).get('tx_rate_mbps',''))" 2>/dev/null || echo "")
    local prev_r_loss=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ping',{}).get('router',{}).get('loss_pct',''))" 2>/dev/null || echo "")
    local prev_r_avg=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ping',{}).get('router',{}).get('avg_ms',''))" 2>/dev/null || echo "")
    local prev_s_loss=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ping',{}).get('server',{}).get('loss_pct',''))" 2>/dev/null || echo "")
    local prev_s_avg=$(echo "$prev_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ping',{}).get('server',{}).get('avg_ms',''))" 2>/dev/null || echo "")

    # 计算列宽（取各列最大内容宽度）
    local name_w=12
    local prev_w=12
    local cur_w=12
    local diff_w=12

    local fmt_name="%-${name_w}s"
    local fmt_prev="%-${prev_w}s"
    local fmt_cur="%-${cur_w}s"
    local fmt_diff="%-${diff_w}s"

    # 打印对比表格
    printf "${BOLD}%-12s %-12s %-12s %-12s${NC}\n" "指标" "上次" "本次" "变化"
    printf "%s\n" "──────────────────────────────────────"

    local ch_changed=0
    local bw_changed=0
    if [ "$cur_ch" != "$prev_ch" ]; then ch_changed=1; fi
    if [ "$cur_bw" != "$prev_bw" ]; then bw_changed=1; fi

    if [ $ch_changed -eq 1 ] || [ $bw_changed -eq 1 ]; then
        printf "%-12s %-12s %-12s ${GREEN}已修改${NC}\n" "WiFi 信道" "${prev_ch:-N/A}" "${cur_ch:-N/A}"
        printf "%-12s %-12s %-12s ${GREEN}已修改${NC}\n" "带宽" "${prev_bw:-N/A}" "${cur_bw:-N/A}"
    else
        printf "%-12s %-12s %-12s %s\n" "WiFi 信道" "${prev_ch:-N/A}" "${cur_ch:-N/A}" "—"
        printf "%-12s %-12s %-12s %s\n" "带宽" "${prev_bw:-N/A}" "${cur_bw:-N/A}" "—"
    fi

    local sig_arrow=$(trend_arrow "$prev_sig" "$cur_sig" 1)
    local tx_arrow=$(trend_arrow "$prev_tx" "$cur_tx" 0)
    printf "%-12s %-12s %-12s %s\n" "信号强度" "${prev_sig:-N/A} dBm" "${cur_sig:-N/A} dBm" "$sig_arrow"
    printf "%-12s %-12s %-12s %s\n" "传输速率" "${prev_tx:-N/A} Mbps" "${cur_tx:-N/A} Mbps" "$tx_arrow"

    printf "%s\n" "──────────────────────────────────────"

    local r_loss_arrow=$(trend_arrow "$prev_r_loss" "$cur_r_loss" 1)
    local r_avg_arrow=$(trend_arrow "$prev_r_avg" "$cur_r_avg" 1)
    local s_loss_arrow=$(trend_arrow "$prev_s_loss" "$cur_s_loss" 1)
    local s_avg_arrow=$(trend_arrow "$prev_s_avg" "$cur_s_avg" 1)
    printf "%-12s %-12s %-12s %s\n" "到路由器丢包" "${prev_r_loss:-N/A}%" "${cur_r_loss:-N/A}%" "$r_loss_arrow"
    printf "%-12s %-12s %-12s %s\n" "到路由器延迟" "${prev_r_avg:-N/A}ms" "${cur_r_avg:-N/A}ms" "$r_avg_arrow"
    printf "%-12s %-12s %-12s %s\n" "到服务器丢包" "${prev_s_loss:-N/A}%" "${cur_s_loss:-N/A}%" "$s_loss_arrow"
    printf "%-12s %-12s %-12s %s\n" "到服务器延迟" "${prev_s_avg:-N/A}ms" "${cur_s_avg:-N/A}ms" "$s_avg_arrow"

    echo ""

    # 健康评分（5星制）
    local score=5
    local reason=""

    # 丢包扣分
    if [ -n "$cur_s_loss" ] && [ "$cur_s_loss" != "0.0" ] && (( $(echo "$cur_s_loss > 0" | bc -l 2>/dev/null || echo "0") )); then
        score=$((score - 1))
        reason="${reason}丢包 "
    fi
    if [ -n "$cur_r_loss" ] && [ "$cur_r_loss" != "0.0" ] && (( $(echo "$cur_r_loss > 0" | bc -l 2>/dev/null || echo "0") )); then
        score=$((score - 1))
        reason="${reason}路由器丢包 "
    fi

    # 延迟扣分
    if [ -n "$cur_s_avg" ] && [ "$cur_s_avg" != "0" ] && (( $(echo "$cur_s_avg > 100" | bc -l 2>/dev/null || echo "0") )); then
        score=$((score - 1))
        reason="${reason}高延迟 "
    fi

    # 信号扣分
    if [ -n "$cur_sig" ] && [ "$cur_sig" != "未知" ]; then
        local sig_abs=$(echo "$cur_sig" | sed 's/-//')
        if (( $(echo "$sig_abs > 70" | bc -l 2>/dev/null || echo "0") )); then
            score=$((score - 1))
            reason="${reason}弱信号 "
        fi
    fi

    # 速率扣分
    if [ -n "$cur_tx" ] && [ "$cur_tx" != "未知" ]; then
        if (( $(echo "$cur_tx < 50" | bc -l 2>/dev/null || echo "0") )); then
            score=$((score - 1))
            reason="${reason}低速率 "
        fi
    fi

    # 确保最低 1 星
    if [ $score -lt 1 ]; then score=1; fi

    local stars=""
    local i
    for i in $(seq 1 5); do
        if [ $i -le $score ]; then
            stars="${stars}⭐"
        else
            stars="${stars}☆"
        fi
    done

    local rating_text=""
    case $score in
        5) rating_text="优秀" ;;
        4) rating_text="良好" ;;
        3) rating_text="一般" ;;
        2) rating_text="较差" ;;
        1) rating_text="严重" ;;
    esac

    printf "${BOLD}健康评分: %s ${NC}%s${NC}\n" "$stars" "$rating_text"
    if [ -n "$reason" ]; then
        printf "${YELLOW}扣分项: %s${NC}\n" "$reason"
    fi

    echo ""

    # 总结
    local improved=0
    local worsened=0
    if [ -n "$prev_s_loss" ] && [ -n "$cur_s_loss" ] && (( $(echo "$cur_s_loss < $prev_s_loss" | bc -l 2>/dev/null || echo "0") )); then
        improved=$((improved + 1))
    elif [ -n "$prev_s_loss" ] && [ -n "$cur_s_loss" ] && (( $(echo "$cur_s_loss > $prev_s_loss" | bc -l 2>/dev/null || echo "0") )); then
        worsened=$((worsened + 1))
    fi
    if [ -n "$prev_s_avg" ] && [ -n "$cur_s_avg" ] && (( $(echo "$cur_s_avg < $prev_s_avg" | bc -l 2>/dev/null || echo "0") )); then
        improved=$((improved + 1))
    elif [ -n "$prev_s_avg" ] && [ -n "$cur_s_avg" ] && (( $(echo "$cur_s_avg > $prev_s_avg" | bc -l 2>/dev/null || echo "0") )); then
        worsened=$((worsened + 1))
    fi
    if [ -n "$prev_tx" ] && [ -n "$cur_tx" ] && (( $(echo "$cur_tx > $prev_tx" | bc -l 2>/dev/null || echo "0") )); then
        improved=$((improved + 1))
    elif [ -n "$prev_tx" ] && [ -n "$cur_tx" ] && (( $(echo "$cur_tx < $prev_tx" | bc -l 2>/dev/null || echo "0") )); then
        worsened=$((worsened + 1))
    fi

    if [ $improved -gt $worsened ] && [ $improved -gt 0 ]; then
        print_ok "网络质量有改善！${improved} 项指标优化，${worsened} 项退化"
    elif [ $worsened -gt $improved ]; then
        print_warn "网络质量有所下降！${worsened} 项指标退化，${improved} 项优化"
    else
        print_info "网络状态稳定，无显著变化"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 主函数
# ═══════════════════════════════════════════════════════════════

main() {
    print_header "🌐 网络优化诊断工具"
    echo "目标服务器: ${SSH_HOST}"
    echo "时间: $(timestamp)"
    
    if ! command -v python3 &>/dev/null; then
        echo "错误: 需要安装 python3"
        exit 1
    fi
    if ! command -v bc &>/dev/null; then
        echo "错误: 需要安装 bc"
        exit 1
    fi
    
    mkdir -p "$DATA_DIR"
    
    # 1. WiFi 检测
    print_header "📡 WiFi 状态"
    local wifi_result
    wifi_result=$(detect_wifi)
    print_wifi_status "$wifi_result"
    
    # 2. Ping 测试
    print_header "📶 网络质量测试"
    local router_ping
    router_ping=$(run_ping_test "192.168.0.1")
    print_ping_result "笔记本 → 路由器 (192.168.0.1)" "$router_ping"
    
    local modem_ping
    modem_ping=$(run_ping_test "192.168.1.1")
    print_ping_result "笔记本 → 宽带猫 (192.168.1.1)" "$modem_ping"
    
    local server_ping
    server_ping=$(run_ping_test "$SSH_TARGET")
    print_ping_result "笔记本 → 服务器 (${SSH_TARGET})" "$server_ping"
    
    # 3. SSH 测试
    print_header "🚀 SSH & 传输速度"
    local ssh_result
    ssh_result=$(run_ssh_test)
    print_ssh_result "$ssh_result"
    
    # 4. 显示对比
    show_comparison "$wifi_result" "$router_ping" "$modem_ping" "$server_ping" "$ssh_result"
    
    # 5. 生成建议
    generate_advice "$wifi_result" "$router_ping" "$server_ping"
    
    # 6. 保存结果
    echo ""
    save_results "$wifi_result" "$router_ping" "$modem_ping" "$server_ping" "$ssh_result"
    
    echo ""
    print_header "测试完成"
    echo "💡 提示: 修改路由器设置后再次运行此脚本，可看到对比效果"
}

main "$@"
