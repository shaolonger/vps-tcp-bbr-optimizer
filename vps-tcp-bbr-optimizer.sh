#!/bin/sh

if [ "${VPS_TCP_BBR_OPTIMIZER_BASH_STAGE:-0}" != "1" ]; then
  if command -v bash >/dev/null 2>&1; then
    VPS_TCP_BBR_OPTIMIZER_BASH_STAGE=1 exec bash "$0" "$@"
  fi

  detect_pm() {
    if command -v apk >/dev/null 2>&1; then
      printf '%s' apk
    elif command -v apt-get >/dev/null 2>&1; then
      printf '%s' apt
    elif command -v dnf >/dev/null 2>&1; then
      printf '%s' dnf
    elif command -v yum >/dev/null 2>&1; then
      printf '%s' yum
    else
      printf '%s' unknown
    fi
  }

  install_bash() {
    case "$(detect_pm)" in
      apk)
        apk add --no-cache bash
        ;;
      apt)
        apt-get update && apt-get install -y bash
        ;;
      dnf)
        dnf install -y bash
        ;;
      yum)
        yum install -y bash
        ;;
      *)
        return 1
        ;;
    esac
  }

  echo "检测到系统未安装 bash，正在尝试自举安装..." >&2
  if [ "$(id -u)" -ne 0 ]; then
    echo "当前不是 root，无法自动安装 bash。" >&2
    echo "请先安装 bash 后重试；例如 Alpine 可执行: apk add bash" >&2
    exit 1
  fi

  if ! install_bash; then
    echo "自动安装 bash 失败，请手动安装后重试。" >&2
    exit 1
  fi

  if command -v bash >/dev/null 2>&1; then
    VPS_TCP_BBR_OPTIMIZER_BASH_STAGE=1 exec bash "$0" "$@"
  fi

  echo "bash 安装后仍不可用，请检查系统环境。" >&2
  exit 1
fi

unset VPS_TCP_BBR_OPTIMIZER_BASH_STAGE

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="0.1.0"

DEFAULT_CONF_PATH="/etc/sysctl.d/99-vps-tcp-bbr-optimizer.conf"
STATE_DIR="/var/lib/vps-tcp-bbr-optimizer"
BACKUP_DIR="${STATE_DIR}/backups"

ACTION="interactive"
ASSUME_YES=0
NO_NETWORK_TEST=0
JSON_OUTPUT=0
PRINT_CONFIG=0
APPLY_LIVE_QDISC=1

USER_BANDWIDTH_MBPS=""
USER_RTT_MS=""
USER_CONCURRENCY=""
REGION="global"
PROFILE="balanced"
CONF_PATH="$DEFAULT_CONF_PATH"

OS_NAME="unknown"
OS_VERSION="unknown"
KERNEL_RELEASE="unknown"
ARCH_NAME="unknown"
VIRT_TYPE="unknown"
CPU_MODEL="unknown"
CPU_CORES=1
RAM_MB=0
SWAP_MB=0
DEFAULT_IFACE=""
IFACE_MTU=1500
IFACE_SPEED_MBPS=0
IFACE_SPEED_SOURCE="fallback"
CURRENT_QDISC="unknown"
CURRENT_CC="unknown"
AVAILABLE_CC=""
BBR_AVAILABLE=0
ESTIMATED_RTT_MS=0
ESTIMATED_RTT_SOURCE="default"
EFFECTIVE_BANDWIDTH_MBPS=0
EFFECTIVE_BANDWIDTH_SOURCE="fallback"

RECOMMENDED_CC=""
RECOMMENDED_QDISC="fq"
RECOMMENDED_BUFFER_BYTES=0
RECOMMENDED_RMEM_DEFAULT=0
RECOMMENDED_WMEM_DEFAULT=0
RECOMMENDED_NOTSENT_LOWAT=0
RECOMMENDED_SOMAXCONN=0
RECOMMENDED_BACKLOG=0
RECOMMENDED_SYN_BACKLOG=0
RECOMMENDED_CONNTRACK_MAX=0
RECOMMENDED_FILE_MAX=0
LIVE_QDISC_SAFE=0
PKG_MANAGER="unknown"
PKG_INSTALL_UPDATED=0

declare -a WARNINGS=()
declare -a NOTES=()
declare -a GENERATED_LINES=()
declare -a PING_RESULTS=()
declare -a SKIPPED_KEYS=()
declare -a APPLY_FAILURES=()

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
GRAY="$(printf '\033[90m')"
RESET="$(printf '\033[0m')"

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

用途:
  一键检测 VPS 的系统/网络能力，并为 TCP + BBR 生成或应用更稳妥的优化配置。

用法:
  sudo sh $SCRIPT_NAME
  sudo sh $SCRIPT_NAME --apply --yes
  sudo sh $SCRIPT_NAME --rollback
  sh $SCRIPT_NAME --report --json

选项:
  --report               只检测并输出报告，不修改系统。
  --apply                生成配置、写入 sysctl 文件并立即尝试应用。
  --rollback             回滚到最近一次备份。
  --print-config         只打印将要写入的 sysctl 配置。
  --json                 以 JSON 输出检测结果与推荐值。
  --yes                  非交互执行；在 interactive/apply 模式下自动确认。
  --no-network-test      跳过 RTT 探测，使用地区默认 RTT 估算。
  --region NAME          主要服务地区: china, asia, us, eu, global。默认 global。
  --profile NAME         优化侧重: balanced, throughput, latency。默认 balanced。
  --bandwidth MBPS       手动指定套餐/链路带宽 Mbps。
  --rtt MS               手动指定 RTT 毫秒。
  --concurrency N        预计并发活跃连接数量。
  --config-path PATH     自定义 sysctl 配置文件路径。
  --no-live-qdisc        不尝试即时替换当前网卡 qdisc，只写入持久化配置。
  --help, -h             显示帮助。

设计原则:
  1. 默认保守，不会安装第三方内核。
  2. 默认不碰高风险项，例如强制全局 tcp_tw_reuse、关闭 ip_forward、大幅 VM 调优。
  3. 写入前自动备份，支持一键回滚。
EOF
}

info() {
  printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"
}

ok() {
  printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"
}

warn() {
  WARNINGS+=("$*")
  printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"
}

note() {
  NOTES+=("$*")
  printf "%s[NOTE]%s %s\n" "$GRAY" "$RESET" "$*"
}

die() {
  printf "%s[FAIL]%s %s\n" "$RED" "$RESET" "$*" >&2
  exit 1
}

json_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_package_manager() {
  if command_exists apk; then
    PKG_MANAGER="apk"
  elif command_exists apt-get; then
    PKG_MANAGER="apt"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="unknown"
  fi
}

can_prompt() {
  [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }
}

prompt_read() {
  local prompt="$1"
  local reply=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
  else
    printf '%s' "$prompt"
    IFS= read -r reply || reply=""
  fi
  printf '%s' "$reply"
}

confirm() {
  local prompt="$1"
  local answer=""

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if ! can_prompt; then
    return 1
  fi

  answer="$(prompt_read "$prompt [y/N]: ")"
  case "${answer,,}" in
    y|yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

clamp() {
  local value="$1"
  local min="$2"
  local max="$3"
  if [ "$value" -lt "$min" ]; then
    printf '%s' "$min"
  elif [ "$value" -gt "$max" ]; then
    printf '%s' "$max"
  else
    printf '%s' "$value"
  fi
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

require_linux() {
  [ "$(uname -s)" = "Linux" ] || die "此脚本仅支持 Linux VPS。"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 或 sudo 运行当前操作。"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report)
        ACTION="report"
        ;;
      --apply)
        ACTION="apply"
        ;;
      --rollback)
        ACTION="rollback"
        ;;
      --print-config)
        PRINT_CONFIG=1
        ;;
      --json)
        JSON_OUTPUT=1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      --no-network-test)
        NO_NETWORK_TEST=1
        ;;
      --region)
        shift
        REGION="${1:-}"
        ;;
      --profile)
        shift
        PROFILE="${1:-}"
        ;;
      --bandwidth)
        shift
        USER_BANDWIDTH_MBPS="${1:-}"
        ;;
      --rtt)
        shift
        USER_RTT_MS="${1:-}"
        ;;
      --concurrency)
        shift
        USER_CONCURRENCY="${1:-}"
        ;;
      --config-path)
        shift
        CONF_PATH="${1:-}"
        ;;
      --no-live-qdisc)
        APPLY_LIVE_QDISC=0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
    shift
  done

  case "$REGION" in
    china|asia|us|eu|global)
      ;;
    *)
      die "--region 仅支持: china, asia, us, eu, global"
      ;;
  esac

  case "$PROFILE" in
    balanced|throughput|latency)
      ;;
    *)
      die "--profile 仅支持: balanced, throughput, latency"
      ;;
  esac

  if [ -n "$USER_BANDWIDTH_MBPS" ] && ! is_integer "$USER_BANDWIDTH_MBPS"; then
    die "--bandwidth 必须为正整数 Mbps"
  fi

  if [ -n "$USER_RTT_MS" ] && ! is_integer "$USER_RTT_MS"; then
    die "--rtt 必须为正整数毫秒"
  fi

  if [ -n "$USER_CONCURRENCY" ] && ! is_integer "$USER_CONCURRENCY"; then
    die "--concurrency 必须为正整数"
  fi
}

load_os_info() {
  detect_package_manager
  ARCH_NAME="$(uname -m 2>/dev/null || printf 'unknown')"
  KERNEL_RELEASE="$(uname -r 2>/dev/null || printf 'unknown')"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  fi

  if command_exists systemd-detect-virt; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || printf 'none')"
  elif command_exists virt-what; then
    VIRT_TYPE="$(virt-what 2>/dev/null | head -n 1 || true)"
    [ -n "$VIRT_TYPE" ] || VIRT_TYPE="unknown"
  fi
}

load_hardware_info() {
  local mem_kb=""
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')"
  RAM_MB=$(( mem_kb / 1024 ))

  local swap_kb=""
  swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')"
  SWAP_MB=$(( swap_kb / 1024 ))

  CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  [ -n "$CPU_CORES" ] || CPU_CORES=1

  CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || printf 'unknown')"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="unknown"
}

package_for_capability() {
  local capability="$1"
  case "$PKG_MANAGER:$capability" in
    apk:ip)
      printf '%s' "iproute2-minimal"
      ;;
    apk:ping)
      printf '%s' "iputils-ping"
      ;;
    apk:tc)
      printf '%s' "iproute2-tc"
      ;;
    apk:ethtool)
      printf '%s' "ethtool"
      ;;
    apk:sysctl)
      printf '%s' "procps-ng"
      ;;
    apk:modprobe)
      printf '%s' "kmod"
      ;;
    apt:ip)
      printf '%s' "iproute2"
      ;;
    apt:ping)
      printf '%s' "iputils-ping"
      ;;
    apt:tc)
      printf '%s' "iproute2"
      ;;
    apt:ethtool)
      printf '%s' "ethtool"
      ;;
    apt:sysctl)
      printf '%s' "procps"
      ;;
    apt:modprobe)
      printf '%s' "kmod"
      ;;
    dnf:ip|yum:ip)
      printf '%s' "iproute"
      ;;
    dnf:ping|yum:ping)
      printf '%s' "iputils"
      ;;
    dnf:tc|yum:tc)
      printf '%s' "iproute-tc"
      ;;
    dnf:ethtool|yum:ethtool)
      printf '%s' "ethtool"
      ;;
    dnf:sysctl|yum:sysctl)
      printf '%s' "procps-ng"
      ;;
    dnf:modprobe|yum:modprobe)
      printf '%s' "kmod"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

install_packages() {
  local packages=("$@")

  [ "${#packages[@]}" -gt 0 ] || return 0
  require_root

  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    apt)
      if [ "$PKG_INSTALL_UPDATED" -eq 0 ]; then
        apt-get update
        PKG_INSTALL_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_capability() {
  local capability="$1"
  local binary="$2"
  local required="$3"
  local package_name=""

  if command_exists "$binary"; then
    return 0
  fi

  package_name="$(package_for_capability "$capability")"
  if [ -z "$package_name" ]; then
    if [ "$required" = "required" ]; then
      die "缺少关键命令 $binary，且无法识别当前系统的安装包。"
    fi
    warn "缺少可选命令 $binary，相关功能将被跳过。"
    return 1
  fi

  if [ "$required" != "required" ]; then
    warn "缺少可选命令 $binary，相关功能将被跳过。可安装包: $package_name"
    return 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    info "检测到缺少 $binary，正在尝试安装 $package_name ..."
    if install_packages "$package_name"; then
      if command_exists "$binary"; then
        ok "已安装 $binary"
        return 0
      fi
      die "安装 $package_name 后仍未找到 $binary。"
    fi
  fi

  die "缺少关键命令 $binary。请先安装 $package_name 后重试。"
}

ensure_runtime_dependencies() {
  ensure_capability "sysctl" "sysctl" "required"
  ensure_capability "ip" "ip" "required"
  ensure_capability "ping" "ping" "optional" || true
  ensure_capability "tc" "tc" "optional" || true
  ensure_capability "ethtool" "ethtool" "optional" || true
  ensure_capability "modprobe" "modprobe" "optional" || true
}

get_default_iface() {
  ip route show default 2>/dev/null | awk '
    $1 == "default" {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

load_network_info() {
  if ! command_exists ip; then
    warn "未检测到 ip 命令，默认网卡与路由信息无法探测。"
    return
  fi

  DEFAULT_IFACE="$(get_default_iface)"
  if [ -z "$DEFAULT_IFACE" ]; then
    warn "未检测到默认网卡，qdisc 和 MTU 探测会被跳过。"
    return
  fi

  IFACE_MTU="$(ip -o link show dev "$DEFAULT_IFACE" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "mtu") {
          print $(i + 1)
          exit
        }
      }
    }
  ')"
  [ -n "$IFACE_MTU" ] || IFACE_MTU=1500

  if command_exists ethtool; then
    local speed_raw=""
    speed_raw="$(ethtool "$DEFAULT_IFACE" 2>/dev/null | awk -F': ' '/Speed:/ {print $2; exit}')"
    case "$speed_raw" in
      *Mb/s)
        IFACE_SPEED_MBPS="${speed_raw%Mb/s}"
        IFACE_SPEED_SOURCE="ethtool"
        ;;
      *Gb/s)
        IFACE_SPEED_MBPS=$(( ${speed_raw%Gb/s} * 1000 ))
        IFACE_SPEED_SOURCE="ethtool"
        ;;
      *)
        IFACE_SPEED_MBPS=0
        ;;
    esac
  fi

  if command_exists tc; then
    CURRENT_QDISC="$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | awk 'NR==1 {print $2; exit}')"
    [ -n "$CURRENT_QDISC" ] || CURRENT_QDISC="unknown"
  fi

  if command_exists sysctl; then
    CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
    AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '')"
  fi

  if printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
    BBR_AVAILABLE=1
  elif [ "$(id -u)" -eq 0 ] && command_exists modprobe; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '')"
    if printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
      BBR_AVAILABLE=1
    fi
  fi
}

region_default_rtt() {
  case "$1" in
    china)
      printf '40'
      ;;
    asia)
      printf '60'
      ;;
    us|eu)
      printf '120'
      ;;
    *)
      printf '90'
      ;;
  esac
}

region_targets() {
  case "$1" in
    china)
      printf '%s\n' "223.5.5.5" "119.29.29.29" "180.76.76.76"
      ;;
    asia)
      printf '%s\n' "1.1.1.1" "8.8.8.8" "223.5.5.5"
      ;;
    us)
      printf '%s\n' "1.1.1.1" "8.8.8.8" "208.67.222.222"
      ;;
    eu)
      printf '%s\n' "1.1.1.1" "9.9.9.9" "8.8.8.8"
      ;;
    *)
      printf '%s\n' "1.1.1.1" "8.8.8.8" "9.9.9.9"
      ;;
  esac
}

probe_rtt() {
  local -a avgs=()
  local target=""
  local avg=""

  if [ -n "$USER_RTT_MS" ]; then
    ESTIMATED_RTT_MS="$USER_RTT_MS"
    ESTIMATED_RTT_SOURCE="user"
    return
  fi

  if [ "$NO_NETWORK_TEST" -eq 1 ] || ! command_exists ping; then
    ESTIMATED_RTT_MS="$(region_default_rtt "$REGION")"
    ESTIMATED_RTT_SOURCE="default"
    return
  fi

  while IFS= read -r target; do
    [ -n "$target" ] || continue
    avg="$(
      {
        ping -c 3 -W 1 "$target" 2>/dev/null ||
        ping -c 3 "$target" 2>/dev/null ||
        true
      } | awk -F'/' '/rtt|round-trip/ {print int($5 + 0.5); exit}'
    )"
    if [ -n "$avg" ]; then
      avgs+=("$avg")
      PING_RESULTS+=("$target=${avg}ms")
    fi
  done < <(region_targets "$REGION")

  if [ "${#avgs[@]}" -eq 0 ]; then
    ESTIMATED_RTT_MS="$(region_default_rtt "$REGION")"
    ESTIMATED_RTT_SOURCE="default"
    warn "RTT 探测失败，改用地区默认值 ${ESTIMATED_RTT_MS}ms。"
    return
  fi

  local sum=0
  local item=0
  for item in "${avgs[@]}"; do
    sum=$(( sum + item ))
  done

  ESTIMATED_RTT_MS=$(( sum / ${#avgs[@]} ))
  ESTIMATED_RTT_SOURCE="ping"
}

resolve_bandwidth() {
  if [ -n "$USER_BANDWIDTH_MBPS" ]; then
    EFFECTIVE_BANDWIDTH_MBPS="$USER_BANDWIDTH_MBPS"
    EFFECTIVE_BANDWIDTH_SOURCE="user"
    return
  fi

  if [ "$IFACE_SPEED_MBPS" -gt 0 ]; then
    EFFECTIVE_BANDWIDTH_MBPS="$IFACE_SPEED_MBPS"
    EFFECTIVE_BANDWIDTH_SOURCE="$IFACE_SPEED_SOURCE"
    return
  fi

  EFFECTIVE_BANDWIDTH_MBPS=1000
  EFFECTIVE_BANDWIDTH_SOURCE="fallback"
}

compute_recommendation() {
  local profile_factor=3
  local rtt_factor=100
  local min_buffer=$(( 4 * 1024 * 1024 ))
  local max_buffer=$(( 128 * 1024 * 1024 ))
  local ram_budget_bytes=0
  local bdp_bytes=0
  local raw_buffer=0
  local min_percent=4
  local default_rmem=0
  local default_wmem=0
  local conn_hint=0

  resolve_bandwidth
  probe_rtt

  if [ "$ESTIMATED_RTT_MS" -lt 1 ]; then
    ESTIMATED_RTT_MS=1
    ESTIMATED_RTT_SOURCE="guard"
  fi

  case "$PROFILE" in
    latency)
      profile_factor=2
      ;;
    throughput)
      profile_factor=4
      ;;
    *)
      profile_factor=3
      ;;
  esac

  if [ "$ESTIMATED_RTT_MS" -ge 150 ]; then
    rtt_factor=135
  elif [ "$ESTIMATED_RTT_MS" -ge 80 ]; then
    rtt_factor=120
  fi

  if [ "$RAM_MB" -lt 512 ]; then
    min_percent=2
    min_buffer=$(( 2 * 1024 * 1024 ))
    max_buffer=$(( 8 * 1024 * 1024 ))
  elif [ "$RAM_MB" -lt 1024 ]; then
    min_percent=4
    max_buffer=$(( 16 * 1024 * 1024 ))
  elif [ "$RAM_MB" -lt 4096 ]; then
    min_percent=6
    max_buffer=$(( 64 * 1024 * 1024 ))
  else
    min_percent=8
    max_buffer=$(( 256 * 1024 * 1024 ))
  fi

  ram_budget_bytes=$(( RAM_MB * 1024 * 1024 * min_percent / 100 ))
  bdp_bytes=$(( EFFECTIVE_BANDWIDTH_MBPS * 125 * ESTIMATED_RTT_MS ))
  raw_buffer=$(( bdp_bytes * profile_factor * rtt_factor / 100 ))
  if [ "$ram_budget_bytes" -lt "$min_buffer" ]; then
    ram_budget_bytes="$min_buffer"
  fi

  RECOMMENDED_BUFFER_BYTES="$(clamp "$raw_buffer" "$min_buffer" "$ram_budget_bytes")"
  RECOMMENDED_BUFFER_BYTES="$(clamp "$RECOMMENDED_BUFFER_BYTES" "$min_buffer" "$max_buffer")"

  default_rmem=$(( RECOMMENDED_BUFFER_BYTES / 8 ))
  default_wmem=$(( RECOMMENDED_BUFFER_BYTES / 16 ))

  RECOMMENDED_RMEM_DEFAULT="$(clamp "$default_rmem" $(( 128 * 1024 )) $(( 4 * 1024 * 1024 )))"
  RECOMMENDED_WMEM_DEFAULT="$(clamp "$default_wmem" $(( 64 * 1024 )) $(( 2 * 1024 * 1024 )))"
  RECOMMENDED_NOTSENT_LOWAT="$(clamp $(( RECOMMENDED_BUFFER_BYTES / 256 )) 16384 131072)"

  if [ -n "$USER_CONCURRENCY" ]; then
    conn_hint="$USER_CONCURRENCY"
  else
    conn_hint=$(( CPU_CORES * 1024 ))
    if [ "$EFFECTIVE_BANDWIDTH_MBPS" -ge 1000 ]; then
      conn_hint=$(( conn_hint + 1024 ))
    fi
  fi

  RECOMMENDED_SOMAXCONN="$(clamp "$conn_hint" 1024 8192)"
  RECOMMENDED_BACKLOG="$(clamp $(( RECOMMENDED_SOMAXCONN * 2 )) 2048 16384)"
  RECOMMENDED_SYN_BACKLOG="$(clamp $(( RECOMMENDED_SOMAXCONN * 2 )) 2048 16384)"
  RECOMMENDED_CONNTRACK_MAX="$(clamp $(( RAM_MB * 128 )) 65536 1048576)"
  RECOMMENDED_FILE_MAX="$(clamp $(( RAM_MB * 512 )) 131072 2097152)"

  if [ "$BBR_AVAILABLE" -eq 1 ]; then
    RECOMMENDED_CC="bbr"
  elif printf '%s\n' "$AVAILABLE_CC" | grep -qw cubic; then
    RECOMMENDED_CC="cubic"
    warn "当前内核未检测到 bbr，已回退为 cubic。若需要 BBR，请先升级或启用支持 BBR 的内核模块。"
  else
    RECOMMENDED_CC="$CURRENT_CC"
    warn "未检测到可用的 bbr/cubic 切换目标，将保持当前拥塞控制算法。"
  fi

  if [ "$CURRENT_QDISC" = "mq" ]; then
    LIVE_QDISC_SAFE=0
    note "当前网卡 root qdisc 为 mq，多队列设备上跳过 live replace，改为仅写入 default_qdisc=fq。"
  elif [ "$CURRENT_QDISC" = "unknown" ] || [ -z "$DEFAULT_IFACE" ]; then
    LIVE_QDISC_SAFE=0
  else
    LIVE_QDISC_SAFE=1
  fi

  if [ "$SWAP_MB" -eq 0 ] && [ "$RAM_MB" -lt 1024 ]; then
    warn "检测到内存较小且无 Swap，建议先补充少量 Swap 再压测。"
  fi
}

sysctl_proc_path() {
  printf '/proc/sys/%s' "${1//./\/}"
}

sysctl_key_exists() {
  [ -e "$(sysctl_proc_path "$1")" ]
}

sysctl_key_writable() {
  [ -w "$(sysctl_proc_path "$1")" ]
}

emit_sysctl_if_supported() {
  local key="$1"
  local value="$2"
  if ! sysctl_key_exists "$key"; then
    SKIPPED_KEYS+=("$key (missing)")
    return
  fi

  if [ "$ACTION" != "report" ] && [ "$(id -u)" -eq 0 ] && ! sysctl_key_writable "$key"; then
    SKIPPED_KEYS+=("$key (read-only)")
    return
  fi

  GENERATED_LINES+=("$key = $value")
}

build_config() {
  GENERATED_LINES=()
  SKIPPED_KEYS=()

  emit_sysctl_if_supported "net.core.default_qdisc" "$RECOMMENDED_QDISC"
  if [ -n "$RECOMMENDED_CC" ] && [ "$RECOMMENDED_CC" != "unknown" ]; then
    emit_sysctl_if_supported "net.ipv4.tcp_congestion_control" "$RECOMMENDED_CC"
  else
    SKIPPED_KEYS+=("net.ipv4.tcp_congestion_control (unresolved)")
  fi
  emit_sysctl_if_supported "net.core.rmem_max" "$RECOMMENDED_BUFFER_BYTES"
  emit_sysctl_if_supported "net.core.wmem_max" "$RECOMMENDED_BUFFER_BYTES"
  emit_sysctl_if_supported "net.core.rmem_default" "$RECOMMENDED_RMEM_DEFAULT"
  emit_sysctl_if_supported "net.core.wmem_default" "$RECOMMENDED_WMEM_DEFAULT"
  emit_sysctl_if_supported "net.core.optmem_max" "$(clamp $(( RECOMMENDED_BUFFER_BYTES / 8 )) 65536 262144)"
  emit_sysctl_if_supported "net.core.somaxconn" "$RECOMMENDED_SOMAXCONN"
  emit_sysctl_if_supported "net.core.netdev_max_backlog" "$RECOMMENDED_BACKLOG"
  emit_sysctl_if_supported "net.ipv4.tcp_max_syn_backlog" "$RECOMMENDED_SYN_BACKLOG"
  emit_sysctl_if_supported "net.ipv4.tcp_rmem" "4096 ${RECOMMENDED_RMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}"
  emit_sysctl_if_supported "net.ipv4.tcp_wmem" "4096 ${RECOMMENDED_WMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}"
  emit_sysctl_if_supported "net.ipv4.tcp_moderate_rcvbuf" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_window_scaling" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_sack" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_mtu_probing" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_slow_start_after_idle" "0"
  emit_sysctl_if_supported "net.ipv4.tcp_fastopen" "3"
  emit_sysctl_if_supported "net.ipv4.tcp_notsent_lowat" "$RECOMMENDED_NOTSENT_LOWAT"
  emit_sysctl_if_supported "net.ipv4.tcp_timestamps" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_syncookies" "1"
  emit_sysctl_if_supported "fs.file-max" "$RECOMMENDED_FILE_MAX"

  if sysctl_key_exists "net.netfilter.nf_conntrack_max"; then
    emit_sysctl_if_supported "net.netfilter.nf_conntrack_max" "$RECOMMENDED_CONNTRACK_MAX"
  fi

  emit_sysctl_if_supported "net.ipv4.conf.all.accept_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.default.accept_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.all.secure_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.default.secure_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.all.send_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.default.send_redirects" "0"
  emit_sysctl_if_supported "net.ipv4.conf.all.accept_source_route" "0"
  emit_sysctl_if_supported "net.ipv4.conf.default.accept_source_route" "0"
  emit_sysctl_if_supported "net.ipv4.conf.all.rp_filter" "2"
  emit_sysctl_if_supported "net.ipv4.conf.default.rp_filter" "2"
  emit_sysctl_if_supported "net.ipv4.icmp_echo_ignore_broadcasts" "1"
  emit_sysctl_if_supported "net.ipv4.icmp_ignore_bogus_error_responses" "1"
  emit_sysctl_if_supported "net.ipv6.conf.all.accept_redirects" "0"
  emit_sysctl_if_supported "net.ipv6.conf.default.accept_redirects" "0"
  emit_sysctl_if_supported "net.ipv6.conf.all.accept_source_route" "0"
  emit_sysctl_if_supported "net.ipv6.conf.default.accept_source_route" "0"
}

print_config_text() {
  cat <<EOF
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Time: $(date '+%Y-%m-%d %H:%M:%S %Z')
# Profile: $PROFILE
# Region: $REGION
# RTT source: $ESTIMATED_RTT_SOURCE (${ESTIMATED_RTT_MS}ms)
# Bandwidth source: $EFFECTIVE_BANDWIDTH_SOURCE (${EFFECTIVE_BANDWIDTH_MBPS}Mbps)
EOF
  printf '\n'
  printf '%s\n' "${GENERATED_LINES[@]}"
}

apply_runtime_sysctls() {
  APPLY_FAILURES=()
  local line=""
  local key=""
  local value=""
  for line in "${GENERATED_LINES[@]}"; do
    key="${line%% = *}"
    value="${line#*= }"
    if ! sysctl -q -w "${key}=${value}" >/dev/null 2>&1; then
      APPLY_FAILURES+=("$key")
    fi
  done
}

reload_sysctl_file() {
  local file_path="$1"

  if ! command_exists sysctl; then
    warn "未检测到 sysctl，无法重新加载配置文件。"
    return 1
  fi

  if [ ! -f "$file_path" ]; then
    warn "配置文件不存在，无法重新加载: $file_path"
    return 1
  fi

  if sysctl -e -p "$file_path" >/dev/null 2>&1; then
    ok "已重新加载 $file_path"
    return 0
  fi

  warn "重新加载 $file_path 失败，配置文件已写入，但部分值可能需要重启后生效。"
  return 1
}

reload_sysctl_system_portable() {
  local file=""
  local matched=0
  local -a files=()
  local -a dirs=(
    /etc/sysctl.conf
    /usr/lib/sysctl.d
    /usr/local/lib/sysctl.d
    /lib/sysctl.d
    /run/sysctl.d
    /etc/sysctl.d
  )

  if ! command_exists sysctl; then
    warn "未检测到 sysctl，无法重新加载系统配置。"
    return 1
  fi

  if sysctl --help 2>&1 | grep -q -- '--system'; then
    if sysctl --system >/dev/null 2>&1; then
      ok "已重新加载系统 sysctl 配置"
      return 0
    fi
    warn "sysctl --system 执行失败，正在尝试逐文件加载。"
  fi

  if [ -f /etc/sysctl.conf ]; then
    files+=("/etc/sysctl.conf")
  fi

  for file in /usr/lib/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf /run/sysctl.d/*.conf /etc/sysctl.d/*.conf; do
    [ -e "$file" ] || continue
    files+=("$file")
  done

  for file in "${files[@]}"; do
    matched=1
    sysctl -e -p "$file" >/dev/null 2>&1 || true
  done

  if [ "$matched" -eq 1 ]; then
    ok "已按可移植方式重新加载系统 sysctl 配置"
    return 0
  fi

  warn "未找到可加载的 sysctl 配置文件。"
  return 1
}

write_config_file() {
  ensure_dirs
  mkdir -p "$(dirname "$CONF_PATH")"

  local backup_path=""
  if [ -f "$CONF_PATH" ]; then
    backup_path="${BACKUP_DIR}/$(basename "$CONF_PATH").$(date +%Y%m%d-%H%M%S).bak"
    cp "$CONF_PATH" "$backup_path"
    ok "已备份旧配置到 $backup_path"
  fi

  {
    print_config_text
  } >"$CONF_PATH"

  ok "已写入 $CONF_PATH"
}

try_live_qdisc() {
  if [ "$APPLY_LIVE_QDISC" -ne 1 ] || [ "$LIVE_QDISC_SAFE" -ne 1 ]; then
    return
  fi

  if ! command_exists tc || [ -z "$DEFAULT_IFACE" ]; then
    return
  fi

  if [ "$CURRENT_QDISC" = "fq" ]; then
    return
  fi

  if tc qdisc replace dev "$DEFAULT_IFACE" root fq >/dev/null 2>&1; then
    ok "已为 $DEFAULT_IFACE 即时切换 root qdisc -> fq"
  else
    warn "即时切换 $DEFAULT_IFACE 的 qdisc 失败，已保留持久化配置，重启后仍会生效。"
  fi
}

rollback_config() {
  require_linux
  require_root
  ensure_dirs

  local latest_backup=""
  latest_backup="$(ls -t "${BACKUP_DIR}/$(basename "$CONF_PATH")."*.bak 2>/dev/null | head -n 1 || true)"

  if [ -z "$latest_backup" ]; then
    if [ -f "$CONF_PATH" ]; then
      rm -f "$CONF_PATH"
      ok "已删除 $CONF_PATH"
      reload_sysctl_system_portable || true
      return
    fi
    die "没有找到可回滚的备份。"
  fi

  cp "$latest_backup" "$CONF_PATH"
  ok "已恢复备份: $latest_backup -> $CONF_PATH"
  reload_sysctl_file "$CONF_PATH" || true
}

print_report() {
  cat <<EOF
============================================================
$SCRIPT_NAME v$SCRIPT_VERSION
============================================================
系统:
  OS            : $OS_NAME $OS_VERSION
  Kernel        : $KERNEL_RELEASE
  Arch          : $ARCH_NAME
  Virt          : $VIRT_TYPE

硬件:
  CPU           : $CPU_MODEL
  Cores         : $CPU_CORES
  RAM           : ${RAM_MB} MB
  Swap          : ${SWAP_MB} MB

网络:
  Interface     : ${DEFAULT_IFACE:-unknown}
  MTU           : ${IFACE_MTU}
  NIC Speed     : ${IFACE_SPEED_MBPS} Mbps (${IFACE_SPEED_SOURCE})
  Current qdisc : $CURRENT_QDISC
  Current CC    : $CURRENT_CC
  Available CC  : ${AVAILABLE_CC:-unknown}
  BBR available : $( [ "$BBR_AVAILABLE" -eq 1 ] && printf yes || printf no )
  RTT           : ${ESTIMATED_RTT_MS} ms (${ESTIMATED_RTT_SOURCE})
  Bandwidth     : ${EFFECTIVE_BANDWIDTH_MBPS} Mbps (${EFFECTIVE_BANDWIDTH_SOURCE})

推荐:
  Congestion    : $RECOMMENDED_CC
  default_qdisc : $RECOMMENDED_QDISC
  Buffer max    : $RECOMMENDED_BUFFER_BYTES bytes
  tcp_rmem      : 4096 ${RECOMMENDED_RMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}
  tcp_wmem      : 4096 ${RECOMMENDED_WMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}
  tcp_notsent   : $RECOMMENDED_NOTSENT_LOWAT
  somaxconn     : $RECOMMENDED_SOMAXCONN
  backlog       : $RECOMMENDED_BACKLOG
  syn_backlog   : $RECOMMENDED_SYN_BACKLOG
  conntrack     : $RECOMMENDED_CONNTRACK_MAX
  file-max      : $RECOMMENDED_FILE_MAX
EOF

  if [ "${#PING_RESULTS[@]}" -gt 0 ]; then
    printf '\nRTT 明细:\n'
    printf '  %s\n' "${PING_RESULTS[@]}"
  fi

  if [ "${#SKIPPED_KEYS[@]}" -gt 0 ]; then
    printf '\n跳过的键:\n'
    printf '  %s\n' "${SKIPPED_KEYS[@]}"
  fi

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\n告警:\n'
    printf '  %s\n' "${WARNINGS[@]}"
  fi

  if [ "${#NOTES[@]}" -gt 0 ]; then
    printf '\n说明:\n'
    printf '  %s\n' "${NOTES[@]}"
  fi
}

print_json() {
  local ping_json=""
  local skipped_json=""
  local warn_json=""
  local note_json=""
  local line=""

  for line in "${PING_RESULTS[@]}"; do
    ping_json="${ping_json}\"$(json_escape "$line")\","
  done
  ping_json="[${ping_json%,}]"

  for line in "${SKIPPED_KEYS[@]}"; do
    skipped_json="${skipped_json}\"$(json_escape "$line")\","
  done
  skipped_json="[${skipped_json%,}]"

  for line in "${WARNINGS[@]}"; do
    warn_json="${warn_json}\"$(json_escape "$line")\","
  done
  warn_json="[${warn_json%,}]"

  for line in "${NOTES[@]}"; do
    note_json="${note_json}\"$(json_escape "$line")\","
  done
  note_json="[${note_json%,}]"

  cat <<EOF
{
  "script": "$(json_escape "$SCRIPT_NAME")",
  "version": "$(json_escape "$SCRIPT_VERSION")",
  "system": {
    "os": "$(json_escape "$OS_NAME")",
    "os_version": "$(json_escape "$OS_VERSION")",
    "kernel": "$(json_escape "$KERNEL_RELEASE")",
    "arch": "$(json_escape "$ARCH_NAME")",
    "virt": "$(json_escape "$VIRT_TYPE")",
    "cpu_model": "$(json_escape "$CPU_MODEL")",
    "cpu_cores": $CPU_CORES,
    "ram_mb": $RAM_MB,
    "swap_mb": $SWAP_MB
  },
  "network": {
    "iface": "$(json_escape "$DEFAULT_IFACE")",
    "mtu": $IFACE_MTU,
    "iface_speed_mbps": $IFACE_SPEED_MBPS,
    "iface_speed_source": "$(json_escape "$IFACE_SPEED_SOURCE")",
    "current_qdisc": "$(json_escape "$CURRENT_QDISC")",
    "current_cc": "$(json_escape "$CURRENT_CC")",
    "available_cc": "$(json_escape "$AVAILABLE_CC")",
    "bbr_available": $BBR_AVAILABLE,
    "rtt_ms": $ESTIMATED_RTT_MS,
    "rtt_source": "$(json_escape "$ESTIMATED_RTT_SOURCE")",
    "bandwidth_mbps": $EFFECTIVE_BANDWIDTH_MBPS,
    "bandwidth_source": "$(json_escape "$EFFECTIVE_BANDWIDTH_SOURCE")",
    "ping_results": $ping_json
  },
  "recommendation": {
    "profile": "$(json_escape "$PROFILE")",
    "region": "$(json_escape "$REGION")",
    "congestion_control": "$(json_escape "$RECOMMENDED_CC")",
    "default_qdisc": "$(json_escape "$RECOMMENDED_QDISC")",
    "buffer_bytes": $RECOMMENDED_BUFFER_BYTES,
    "tcp_rmem": "4096 ${RECOMMENDED_RMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}",
    "tcp_wmem": "4096 ${RECOMMENDED_WMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}",
    "tcp_notsent_lowat": $RECOMMENDED_NOTSENT_LOWAT,
    "somaxconn": $RECOMMENDED_SOMAXCONN,
    "netdev_max_backlog": $RECOMMENDED_BACKLOG,
    "tcp_max_syn_backlog": $RECOMMENDED_SYN_BACKLOG,
    "nf_conntrack_max": $RECOMMENDED_CONNTRACK_MAX,
    "file_max": $RECOMMENDED_FILE_MAX,
    "skipped_keys": $skipped_json
  },
  "warnings": $warn_json,
  "notes": $note_json
}
EOF
}

main() {
  parse_args "$@"
  require_linux

  if [ "$ACTION" = "rollback" ]; then
    detect_package_manager
    ensure_capability "sysctl" "sysctl" "required"
    rollback_config
    exit 0
  fi

  load_os_info
  ensure_runtime_dependencies
  load_hardware_info
  load_network_info
  compute_recommendation
  build_config

  if [ "$JSON_OUTPUT" -eq 1 ]; then
    print_json
  else
    print_report
  fi

  if [ "$PRINT_CONFIG" -eq 1 ]; then
    printf '\n'
    print_config_text
  fi

  case "$ACTION" in
    report)
      ;;
    apply)
      require_root
      write_config_file
      apply_runtime_sysctls
      try_live_qdisc
      if [ "${#APPLY_FAILURES[@]}" -eq 0 ]; then
        ok "运行时 sysctl 已全部应用成功"
      else
        warn "以下键即时应用失败，但配置文件已写入：${APPLY_FAILURES[*]}"
      fi
      ;;
    interactive)
      if confirm "是否现在应用以上优化配置？"; then
        require_root
        write_config_file
        apply_runtime_sysctls
        try_live_qdisc
        if [ "${#APPLY_FAILURES[@]}" -eq 0 ]; then
          ok "运行时 sysctl 已全部应用成功"
        else
          warn "以下键即时应用失败，但配置文件已写入：${APPLY_FAILURES[*]}"
        fi
      else
        note "未修改系统。你可以稍后运行: sudo sh $SCRIPT_NAME --apply --print-config"
      fi
      ;;
  esac
}

main "$@"
