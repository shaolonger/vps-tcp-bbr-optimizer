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

SCRIPT_NAME="${VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE:-$(basename "$0")}"
SCRIPT_VERSION="0.2.1"

DEFAULT_CONF_PATH="/etc/sysctl.d/99-vps-tcp-bbr-optimizer.conf"
STATE_DIR="/var/lib/vps-tcp-bbr-optimizer"
BACKUP_DIR="${STATE_DIR}/backups"

ACTION="interactive"
ASSUME_YES=0
NO_NETWORK_TEST=0
JSON_OUTPUT=0
PRINT_CONFIG=0
APPLY_LIVE_QDISC=1
DEEP_DIAGNOSTICS=0

USER_BANDWIDTH_MBPS=""
USER_RTT_MS=""
USER_CONCURRENCY=""
REGION="global"
PRESET="custom"
PROFILE="balanced"
TUNING_MODE="safe"
WORKLOAD="generic"
QDISC_CHOICE="auto"
CONF_PATH="$DEFAULT_CONF_PATH"

USER_SET_PRESET=0
USER_SET_PROFILE=0
USER_SET_TUNING_MODE=0
USER_SET_WORKLOAD=0
USER_SET_QDISC=0
USER_SET_CONCURRENCY=0
USER_SET_DEEP=0

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
DEEP_TARGET=""
TRACEPATH_PMTU=0
TRACEPATH_HOPS=0
MTR_TARGET_LOSS=""
MTR_TARGET_AVG=""

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
RECOMMENDED_MTU_PROBING=1
RECOMMENDED_TCP_ECN=""
RECOMMENDED_TCP_NO_METRICS_SAVE=""
RECOMMENDED_TCP_FIN_TIMEOUT=""
RECOMMENDED_TCP_TW_REUSE=""
RECOMMENDED_IP_LOCAL_PORT_RANGE=""
RECOMMENDED_NETDEV_BUDGET=""
RECOMMENDED_NETDEV_BUDGET_USECS=""
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
  --deep                 启用更深入的链路诊断（tracepath/mtr），会稍慢一些。
  --no-network-test      跳过 RTT 探测，使用地区默认 RTT 估算。
  --region NAME          主要服务地区: china, asia, us, eu, global。默认 global。
  --preset NAME          预设场景: custom, proxy-heavy。默认 custom。
  --profile NAME         优化侧重: balanced, throughput, latency。默认 balanced。
  --tuning-mode NAME     调优强度: safe, performance, extreme。默认 safe。
  --workload NAME        业务类型: generic, proxy, streaming, gaming, bulk。默认 generic。
  --qdisc NAME           队列算法: auto, fq, fq_codel, fq_pie, cake。默认 auto。
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
  4. 直接运行时会进入交互向导，所有主要参数都能逐步选择，并带推荐默认值。
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

tty_printf() {
  if [ -w /dev/tty ]; then
    printf "$@" >/dev/tty
  else
    printf "$@"
  fi
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

confirm_default() {
  local prompt="$1"
  local default_yes="$2"
  local answer=""
  local suffix="[y/N]"

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if ! can_prompt; then
    [ "$default_yes" -eq 1 ]
    return
  fi

  if [ "$default_yes" -eq 1 ]; then
    suffix="[Y/n]"
  fi

  answer="$(prompt_read "$prompt $suffix: ")"
  if [ -z "$answer" ]; then
    [ "$default_yes" -eq 1 ]
    return
  fi

  case "${answer,,}" in
    y|yes)
      return 0
      ;;
    n|no)
      return 1
      ;;
    *)
      [ "$default_yes" -eq 1 ]
      return
      ;;
  esac
}

prompt_text_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=""

  if ! can_prompt; then
    printf '%s' "$default_value"
    return
  fi

  answer="$(prompt_read "$prompt [$default_value]: ")"
  if [ -z "$answer" ]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$answer"
  fi
}

prompt_integer_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=""

  if ! can_prompt; then
    printf '%s' "$default_value"
    return
  fi

  while true; do
    answer="$(prompt_read "$prompt [$default_value]: ")"
    if [ -z "$answer" ]; then
      printf '%s' "$default_value"
      return
    fi

    if is_integer "$answer" && [ "$answer" -gt 0 ]; then
      printf '%s' "$answer"
      return
    fi

    tty_printf '请输入正整数。\n'
  done
}

choose_from_list() {
  local prompt="$1"
  local default_value="$2"
  shift 2
  local entries=("$@")
  local entry=""
  local value=""
  local desc=""
  local answer=""
  local index=1
  local default_index=1
  local selected_index=0

  if ! can_prompt; then
    printf '%s' "$default_value"
    return
  fi

  while true; do
    tty_printf '\n%s\n' "$prompt"
    index=1
    default_index=1
    for entry in "${entries[@]}"; do
      value="${entry%%::*}"
      desc="${entry#*::}"
      if [ "$desc" = "$entry" ]; then
        desc=""
      fi

      if [ "$value" = "$default_value" ]; then
        default_index="$index"
        tty_printf '  %d) %s [推荐默认] %s\n' "$index" "$value" "$desc"
      else
        tty_printf '  %d) %s %s\n' "$index" "$value" "$desc"
      fi
      index=$(( index + 1 ))
    done

    answer="$(prompt_read "请选择 [默认 $default_index]: ")"
    if [ -z "$answer" ]; then
      printf '%s' "$default_value"
      return
    fi

    if is_integer "$answer"; then
      if [ "$answer" -ge 1 ] && [ "$answer" -le "${#entries[@]}" ]; then
        selected_index=$(( answer - 1 ))
        entry="${entries[$selected_index]}"
        printf '%s' "${entry%%::*}"
        return
      fi
    fi

    for entry in "${entries[@]}"; do
      value="${entry%%::*}"
      if [ "$answer" = "$value" ]; then
        printf '%s' "$value"
        return
      fi
    done

    tty_printf '输入无效，请重新选择。\n'
  done
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
      --deep)
        DEEP_DIAGNOSTICS=1
        USER_SET_DEEP=1
        ;;
      --no-network-test)
        NO_NETWORK_TEST=1
        ;;
      --region)
        shift
        REGION="${1:-}"
        ;;
      --preset)
        shift
        PRESET="${1:-}"
        USER_SET_PRESET=1
        ;;
      --profile)
        shift
        PROFILE="${1:-}"
        USER_SET_PROFILE=1
        ;;
      --tuning-mode)
        shift
        TUNING_MODE="${1:-}"
        USER_SET_TUNING_MODE=1
        ;;
      --workload)
        shift
        WORKLOAD="${1:-}"
        USER_SET_WORKLOAD=1
        ;;
      --qdisc)
        shift
        QDISC_CHOICE="${1:-}"
        USER_SET_QDISC=1
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
        USER_SET_CONCURRENCY=1
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

  case "$PRESET" in
    custom|proxy-heavy)
      ;;
    *)
      die "--preset 仅支持: custom, proxy-heavy"
      ;;
  esac

  case "$PROFILE" in
    balanced|throughput|latency)
      ;;
    *)
      die "--profile 仅支持: balanced, throughput, latency"
      ;;
  esac

  case "$TUNING_MODE" in
    safe|performance|extreme)
      ;;
    *)
      die "--tuning-mode 仅支持: safe, performance, extreme"
      ;;
  esac

  case "$WORKLOAD" in
    generic|proxy|streaming|gaming|bulk)
      ;;
    *)
      die "--workload 仅支持: generic, proxy, streaming, gaming, bulk"
      ;;
  esac

  case "$QDISC_CHOICE" in
    auto|fq|fq_codel|fq_pie|cake)
      ;;
    *)
      die "--qdisc 仅支持: auto, fq, fq_codel, fq_pie, cake"
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
    apk:tracepath)
      printf '%s' "iputils-tracepath"
      ;;
    apk:mtr)
      printf '%s' "mtr"
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
    apt:tracepath)
      printf '%s' "iputils-tracepath"
      ;;
    apt:mtr)
      printf '%s' "mtr-tiny"
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
    dnf:tracepath|yum:tracepath)
      printf '%s' "iputils"
      ;;
    dnf:mtr|yum:mtr)
      printf '%s' "mtr"
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

ensure_requested_optional_capability() {
  local capability="$1"
  local binary="$2"
  local package_name=""

  if command_exists "$binary"; then
    return 0
  fi

  package_name="$(package_for_capability "$capability")"
  if [ -z "$package_name" ]; then
    warn "缺少 $binary，无法识别当前系统的安装包，深度诊断将跳过这部分。"
    return 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    info "深度诊断需要 $binary，正在尝试安装 $package_name ..."
    if install_packages "$package_name"; then
      if command_exists "$binary"; then
        ok "已安装 $binary"
        return 0
      fi
    fi
  fi

  warn "缺少 $binary，深度诊断将跳过这部分。可安装包: $package_name"
  return 1
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

region_description() {
  case "$1" in
    china)
      printf '%s' "中国大陆链路为主"
      ;;
    asia)
      printf '%s' "亚洲跨区综合"
      ;;
    us)
      printf '%s' "北美方向"
      ;;
    eu)
      printf '%s' "欧洲方向"
      ;;
    *)
      printf '%s' "全球混合业务"
      ;;
  esac
}

preset_description() {
  case "$1" in
    proxy-heavy)
      printf '%s' "高并发代理/中转/落地机，自动偏向 throughput + performance + proxy + fq"
      ;;
    *)
      printf '%s' "手动组合所有参数"
      ;;
  esac
}

profile_description() {
  case "$1" in
    latency)
      printf '%s' "偏低延迟和交互体验"
      ;;
    throughput)
      printf '%s' "偏吞吐和大带宽传输"
      ;;
    *)
      printf '%s' "吞吐与延迟折中"
      ;;
  esac
}

tuning_mode_description() {
  case "$1" in
    performance)
      printf '%s' "适度更激进，扩大缓冲和队列预算"
      ;;
    extreme)
      printf '%s' "更激进，包含更多高风险高收益参数"
      ;;
    *)
      printf '%s' "更保守，优先兼容与稳定"
      ;;
  esac
}

workload_description() {
  case "$1" in
    proxy)
      printf '%s' "大量短连接/中转/反代"
      ;;
    streaming)
      printf '%s' "视频流或连续发送"
      ;;
    gaming)
      printf '%s' "小包交互和低延迟"
      ;;
    bulk)
      printf '%s' "大文件、备份、测速、复制"
      ;;
    *)
      printf '%s' "通用业务"
      ;;
  esac
}

qdisc_description() {
  case "$1" in
    fq_codel)
      printf '%s' "更偏低延迟，适合交互式流量"
      ;;
    fq_pie)
      printf '%s' "AQM 更积极，适合复杂拥塞链路"
      ;;
    cake)
      printf '%s' "功能强但更吃 CPU，常用于整形场景"
      ;;
    fq)
      printf '%s' "和 BBR 配合稳定，适合大多数 VPS"
      ;;
    *)
      printf '%s' "按业务自动选择"
      ;;
  esac
}

qdisc_module_name() {
  case "$1" in
    fq)
      printf '%s' "sch_fq"
      ;;
    fq_codel)
      printf '%s' "sch_fq_codel"
      ;;
    fq_pie)
      printf '%s' "sch_fq_pie"
      ;;
    cake)
      printf '%s' "sch_cake"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

validate_qdisc_support_if_possible() {
  local qdisc="$1"
  local module_name=""

  module_name="$(qdisc_module_name "$qdisc")"
  if [ -z "$module_name" ]; then
    return 0
  fi

  if [ -d "/sys/module/$module_name" ] || awk '{print $1}' /proc/modules 2>/dev/null | grep -qx "$module_name"; then
    return 0
  fi

  if command_exists modprobe && [ "$(id -u)" -eq 0 ]; then
    if modprobe "$module_name" >/dev/null 2>&1; then
      return 0
    fi
    warn "当前内核似乎不支持 $qdisc，已自动回退到 fq。"
    RECOMMENDED_QDISC="fq"
    return 1
  fi

  note "未能预先验证 $qdisc 的模块支持；如果内核不支持，apply 阶段会回退到持久化配置。"
  return 0
}

primary_target_for_region() {
  region_targets "$REGION" | awk 'NF {print; exit}'
}

apply_preset_defaults() {
  case "$PRESET" in
    proxy-heavy)
      if [ "$USER_SET_PROFILE" -eq 0 ]; then
        PROFILE="throughput"
      fi
      if [ "$USER_SET_TUNING_MODE" -eq 0 ]; then
        TUNING_MODE="performance"
      fi
      if [ "$USER_SET_WORKLOAD" -eq 0 ]; then
        WORKLOAD="proxy"
      fi
      if [ "$USER_SET_QDISC" -eq 0 ]; then
        QDISC_CHOICE="fq"
      fi
      if [ "$USER_SET_DEEP" -eq 0 ]; then
        DEEP_DIAGNOSTICS=1
      fi
      ;;
  esac
}

preset_concurrency_floor() {
  case "$PRESET" in
    proxy-heavy)
      clamp $(( CPU_CORES * 4096 )) 8192 32768
      ;;
    *)
      printf '0'
      ;;
  esac
}

bandwidth_hint_value() {
  if [ -n "$USER_BANDWIDTH_MBPS" ]; then
    printf '%s' "$USER_BANDWIDTH_MBPS"
  elif [ "$IFACE_SPEED_MBPS" -gt 0 ]; then
    printf '%s' "$IFACE_SPEED_MBPS"
  else
    printf '1000'
  fi
}

auto_concurrency_hint() {
  local bw=0
  local conn_hint=0
  local preset_floor=0

  bw="$(bandwidth_hint_value)"
  conn_hint=$(( CPU_CORES * 1024 ))

  if [ "$bw" -ge 1000 ]; then
    conn_hint=$(( conn_hint + 1024 ))
  fi

  case "$WORKLOAD" in
    proxy)
      conn_hint=$(( conn_hint * 2 ))
      ;;
    streaming)
      conn_hint=$(( conn_hint * 12 / 10 ))
      ;;
    gaming)
      conn_hint=$(( conn_hint * 8 / 10 ))
      ;;
    bulk)
      conn_hint=$(( conn_hint * 11 / 10 ))
      ;;
  esac

  case "$TUNING_MODE" in
    performance)
      conn_hint=$(( conn_hint * 13 / 10 ))
      ;;
    extreme)
      conn_hint=$(( conn_hint * 16 / 10 ))
      ;;
  esac

  preset_floor="$(preset_concurrency_floor)"
  if [ "$preset_floor" -gt 0 ] && [ "$conn_hint" -lt "$preset_floor" ]; then
    conn_hint="$preset_floor"
  fi

  clamp "$conn_hint" 1024 32768
}

run_interactive_wizard() {
  local rtt_mode="ping"
  local bandwidth_mode="auto"
  local concurrency_mode="auto"
  local concurrency_default=""

  if [ "$ACTION" != "interactive" ] || [ "$ASSUME_YES" -eq 1 ]; then
    return
  fi

  if ! can_prompt; then
    note "当前环境不可交互，将继续使用默认参数。"
    return
  fi

  tty_printf '\n============================================================\n'
  tty_printf '%s v%s 交互向导\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  tty_printf '============================================================\n'
  tty_printf '检测到系统: %s %s | Kernel %s | RAM %sMB | IFACE %s | BBR %s\n' \
    "$OS_NAME" "$OS_VERSION" "$KERNEL_RELEASE" "$RAM_MB" "${DEFAULT_IFACE:-unknown}" \
    "$( [ "$BBR_AVAILABLE" -eq 1 ] && printf yes || printf no )"
  tty_printf '按回车可直接采用推荐默认值。\n'

  PRESET="$(choose_from_list \
    "1/10 选择场景预设" \
    "$PRESET" \
    "custom::$(preset_description custom)" \
    "proxy-heavy::$(preset_description proxy-heavy)")"
  USER_SET_PRESET=1
  apply_preset_defaults

  REGION="$(choose_from_list \
    "2/10 选择主要服务地区" \
    "$REGION" \
    "global::$(region_description global)" \
    "china::$(region_description china)" \
    "asia::$(region_description asia)" \
    "us::$(region_description us)" \
    "eu::$(region_description eu)")"

  PROFILE="$(choose_from_list \
    "3/10 选择优化侧重" \
    "$PROFILE" \
    "balanced::$(profile_description balanced)" \
    "throughput::$(profile_description throughput)" \
    "latency::$(profile_description latency)")"
  USER_SET_PROFILE=1

  TUNING_MODE="$(choose_from_list \
    "4/10 选择调优强度" \
    "$TUNING_MODE" \
    "safe::$(tuning_mode_description safe)" \
    "performance::$(tuning_mode_description performance)" \
    "extreme::$(tuning_mode_description extreme)")"
  USER_SET_TUNING_MODE=1

  WORKLOAD="$(choose_from_list \
    "5/10 选择业务负载类型" \
    "$WORKLOAD" \
    "generic::$(workload_description generic)" \
    "proxy::$(workload_description proxy)" \
    "streaming::$(workload_description streaming)" \
    "gaming::$(workload_description gaming)" \
    "bulk::$(workload_description bulk)")"
  USER_SET_WORKLOAD=1

  QDISC_CHOICE="$(choose_from_list \
    "6/10 选择 qdisc 队列算法" \
    "$QDISC_CHOICE" \
    "auto::$(qdisc_description auto)" \
    "fq::$(qdisc_description fq)" \
    "fq_codel::$(qdisc_description fq_codel)" \
    "fq_pie::$(qdisc_description fq_pie)" \
    "cake::$(qdisc_description cake)")"
  USER_SET_QDISC=1

  if confirm_default "7/10 是否启用深度链路诊断（tracepath/mtr，会稍慢）" "$DEEP_DIAGNOSTICS" ; then
    DEEP_DIAGNOSTICS=1
  else
    DEEP_DIAGNOSTICS=0
  fi
  USER_SET_DEEP=1

  if [ -n "$USER_RTT_MS" ]; then
    rtt_mode="manual"
  elif [ "$NO_NETWORK_TEST" -eq 1 ] || ! command_exists ping; then
    rtt_mode="default"
  fi

  rtt_mode="$(choose_from_list \
    "8/10 选择 RTT 估算方式" \
    "$rtt_mode" \
    "ping::实时 ping 探测，推荐" \
    "default::跳过探测，直接使用地区默认 RTT" \
    "manual::手动输入典型 RTT")"

  case "$rtt_mode" in
    manual)
      USER_RTT_MS="$(prompt_integer_default "请输入典型 RTT（毫秒）" "$(region_default_rtt "$REGION")")"
      NO_NETWORK_TEST=1
      ;;
    default)
      USER_RTT_MS=""
      NO_NETWORK_TEST=1
      ;;
    *)
      USER_RTT_MS=""
      NO_NETWORK_TEST=0
      ;;
  esac

  if [ -n "$USER_BANDWIDTH_MBPS" ]; then
    bandwidth_mode="manual"
  fi

  bandwidth_mode="$(choose_from_list \
    "9/10 选择带宽来源" \
    "$bandwidth_mode" \
    "auto::使用网卡速率/默认估算" \
    "manual::手动输入带宽上限")"

  if [ "$bandwidth_mode" = "manual" ]; then
    USER_BANDWIDTH_MBPS="$(prompt_integer_default "请输入带宽上限（Mbps）" "$(bandwidth_hint_value)")"
  else
    USER_BANDWIDTH_MBPS=""
  fi

  concurrency_default="$(auto_concurrency_hint)"
  if [ -n "$USER_CONCURRENCY" ]; then
    concurrency_mode="manual"
    concurrency_default="$USER_CONCURRENCY"
  fi

  concurrency_mode="$(choose_from_list \
    "10/10 选择预计并发连接数" \
    "$concurrency_mode" \
    "auto::按 CPU/带宽/业务类型自动估算（推荐 $concurrency_default）" \
    "manual::手动输入并发连接数")"

  if [ "$concurrency_mode" = "manual" ]; then
    USER_CONCURRENCY="$(prompt_integer_default "请输入预计活跃并发连接数" "$concurrency_default")"
  else
    USER_CONCURRENCY=""
  fi

  if ! confirm_default "是否保持默认配置文件路径 $CONF_PATH" 1; then
    CONF_PATH="$(prompt_text_default "请输入新的配置文件路径" "$CONF_PATH")"
  fi

  if confirm_default "应用时是否尝试即时切换当前网卡 qdisc（mq 网卡会自动跳过）" 1; then
    APPLY_LIVE_QDISC=1
  else
    APPLY_LIVE_QDISC=0
  fi
}

run_deep_diagnostics() {
  local target=""
  local trace_output=""
  local mtr_output=""
  local mtr_line=""

  if [ "$DEEP_DIAGNOSTICS" -ne 1 ]; then
    return
  fi

  target="$(primary_target_for_region)"
  if [ -z "$target" ]; then
    warn "无法确定深度诊断目标，已跳过。"
    return
  fi

  DEEP_TARGET="$target"
  ensure_requested_optional_capability "tracepath" "tracepath" || true
  ensure_requested_optional_capability "mtr" "mtr" || true

  if command_exists tracepath; then
    trace_output="$({ tracepath -n "$target" 2>/dev/null || true; })"
    TRACEPATH_PMTU="$(printf '%s\n' "$trace_output" | awk '
      /pmtu/ {
        for (i = 1; i <= NF; i++) {
          if ($i == "pmtu") {
            print $(i + 1)
            exit
          }
        }
      }
    ')"
    TRACEPATH_HOPS="$(printf '%s\n' "$trace_output" | awk '
      /^[[:space:]]*[0-9]+\??:/ {
        hop=$1
        gsub("\\?:", "", hop)
        gsub(":", "", hop)
        last=hop
      }
      END {print last + 0}
    ')"
    [ -n "$TRACEPATH_PMTU" ] || TRACEPATH_PMTU=0
    [ -n "$TRACEPATH_HOPS" ] || TRACEPATH_HOPS=0
  fi

  if command_exists mtr; then
    mtr_output="$({ mtr --report --report-cycles 3 --no-dns "$target" 2>/dev/null || true; })"
    mtr_line="$(printf '%s\n' "$mtr_output" | awk '/^[[:space:]]*[0-9]+\.\|--/ {line=$0} END {print line}')"
    if [ -n "$mtr_line" ]; then
      MTR_TARGET_LOSS="$(printf '%s\n' "$mtr_line" | awk '{gsub("%", "", $3); print $3}')"
      MTR_TARGET_AVG="$(printf '%s\n' "$mtr_line" | awk '{print int($6 + 0.5)}')"
    fi
  fi

  if [ "$TRACEPATH_PMTU" -gt 0 ]; then
    note "深度诊断: $DEEP_TARGET 的 path MTU 约为 $TRACEPATH_PMTU，链路跳数约 $TRACEPATH_HOPS。"
  fi

  if [ -n "$MTR_TARGET_LOSS" ] && [ -n "$MTR_TARGET_AVG" ]; then
    note "深度诊断: $DEEP_TARGET 的 mtr 终点平均延迟约 ${MTR_TARGET_AVG}ms，丢包约 ${MTR_TARGET_LOSS}%。"
  fi
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
  local buffer_mode_pct=100
  local conn_mode_pct=100
  local buffer_workload_pct=100
  local conn_workload_pct=100
  local notsent_pct=100
  local backlog_cap=16384
  local somaxconn_cap=8192
  local conntrack_cap=1048576
  local filemax_cap=2097152

  resolve_bandwidth
  probe_rtt
  run_deep_diagnostics

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

  case "$TUNING_MODE" in
    performance)
      buffer_mode_pct=125
      conn_mode_pct=130
      backlog_cap=32768
      somaxconn_cap=16384
      conntrack_cap=2097152
      filemax_cap=4194304
      RECOMMENDED_TCP_ECN="1"
      RECOMMENDED_TCP_NO_METRICS_SAVE="1"
      RECOMMENDED_IP_LOCAL_PORT_RANGE="10240 65535"
      RECOMMENDED_NETDEV_BUDGET="600"
      RECOMMENDED_NETDEV_BUDGET_USECS="6000"
      ;;
    extreme)
      buffer_mode_pct=150
      conn_mode_pct=160
      backlog_cap=65535
      somaxconn_cap=32768
      conntrack_cap=4194304
      filemax_cap=8388608
      RECOMMENDED_TCP_ECN="1"
      RECOMMENDED_TCP_NO_METRICS_SAVE="1"
      RECOMMENDED_IP_LOCAL_PORT_RANGE="10240 65535"
      RECOMMENDED_NETDEV_BUDGET="800"
      RECOMMENDED_NETDEV_BUDGET_USECS="8000"
      RECOMMENDED_TCP_FIN_TIMEOUT="15"
      RECOMMENDED_TCP_TW_REUSE="1"
      warn "你选择了 extreme 模式，将启用更激进的队列/端口/连接回收参数，建议先在低峰期或灰度环境验证。"
      ;;
    *)
      RECOMMENDED_TCP_ECN=""
      RECOMMENDED_TCP_NO_METRICS_SAVE=""
      RECOMMENDED_IP_LOCAL_PORT_RANGE=""
      RECOMMENDED_NETDEV_BUDGET=""
      RECOMMENDED_NETDEV_BUDGET_USECS=""
      RECOMMENDED_TCP_FIN_TIMEOUT=""
      RECOMMENDED_TCP_TW_REUSE=""
      ;;
  esac

  case "$WORKLOAD" in
    proxy)
      buffer_workload_pct=110
      conn_workload_pct=180
      notsent_pct=125
      ;;
    streaming)
      buffer_workload_pct=125
      conn_workload_pct=120
      notsent_pct=160
      ;;
    gaming)
      buffer_workload_pct=70
      conn_workload_pct=85
      notsent_pct=60
      ;;
    bulk)
      buffer_workload_pct=145
      conn_workload_pct=115
      notsent_pct=185
      ;;
    *)
      ;;
  esac

  if [ "$PRESET" = "proxy-heavy" ]; then
    if [ "$buffer_workload_pct" -lt 120 ]; then
      buffer_workload_pct=120
    fi
    if [ "$conn_workload_pct" -lt 220 ]; then
      conn_workload_pct=220
    fi
    if [ "$notsent_pct" -lt 140 ]; then
      notsent_pct=140
    fi
    if [ "$somaxconn_cap" -lt 32768 ]; then
      somaxconn_cap=32768
    fi
    if [ "$backlog_cap" -lt 65535 ]; then
      backlog_cap=65535
    fi
    if [ "$conntrack_cap" -lt 4194304 ]; then
      conntrack_cap=4194304
    fi
    if [ "$filemax_cap" -lt 8388608 ]; then
      filemax_cap=8388608
    fi
    [ -n "$RECOMMENDED_TCP_ECN" ] || RECOMMENDED_TCP_ECN="1"
    [ -n "$RECOMMENDED_TCP_NO_METRICS_SAVE" ] || RECOMMENDED_TCP_NO_METRICS_SAVE="1"
    [ -n "$RECOMMENDED_IP_LOCAL_PORT_RANGE" ] || RECOMMENDED_IP_LOCAL_PORT_RANGE="10240 65535"
    [ -n "$RECOMMENDED_NETDEV_BUDGET" ] || RECOMMENDED_NETDEV_BUDGET="600"
    [ -n "$RECOMMENDED_NETDEV_BUDGET_USECS" ] || RECOMMENDED_NETDEV_BUDGET_USECS="6000"
    note "已启用 proxy-heavy 预设：会优先放大代理机场景下的连接、队列和端口预算。"
  fi

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

  ram_budget_bytes=$(( RAM_MB * 1024 * 1024 * min_percent * buffer_mode_pct / 10000 ))
  bdp_bytes=$(( EFFECTIVE_BANDWIDTH_MBPS * 125 * ESTIMATED_RTT_MS ))
  raw_buffer=$(( bdp_bytes * profile_factor * rtt_factor * buffer_mode_pct * buffer_workload_pct / 1000000 ))

  if [ "$TRACEPATH_HOPS" -ge 12 ] && { [ "$PROFILE" = "throughput" ] || [ "$WORKLOAD" = "bulk" ] || [ "$WORKLOAD" = "streaming" ]; }; then
    raw_buffer=$(( raw_buffer * 11 / 10 ))
  fi

  if [ "$ram_budget_bytes" -lt "$min_buffer" ]; then
    ram_budget_bytes="$min_buffer"
  fi

  RECOMMENDED_BUFFER_BYTES="$(clamp "$raw_buffer" "$min_buffer" "$ram_budget_bytes")"
  RECOMMENDED_BUFFER_BYTES="$(clamp "$RECOMMENDED_BUFFER_BYTES" "$min_buffer" "$max_buffer")"

  default_rmem=$(( RECOMMENDED_BUFFER_BYTES / 8 ))
  default_wmem=$(( RECOMMENDED_BUFFER_BYTES / 16 ))

  RECOMMENDED_RMEM_DEFAULT="$(clamp "$default_rmem" $(( 128 * 1024 )) $(( 4 * 1024 * 1024 )))"
  RECOMMENDED_WMEM_DEFAULT="$(clamp "$default_wmem" $(( 64 * 1024 )) $(( 2 * 1024 * 1024 )))"
  RECOMMENDED_NOTSENT_LOWAT="$(clamp $(( RECOMMENDED_BUFFER_BYTES * notsent_pct / 25600 )) 8192 524288)"

  if [ -n "$USER_CONCURRENCY" ]; then
    conn_hint="$USER_CONCURRENCY"
  else
    conn_hint="$(auto_concurrency_hint)"
  fi

  RECOMMENDED_SOMAXCONN="$(clamp "$conn_hint" 1024 "$somaxconn_cap")"
  RECOMMENDED_BACKLOG="$(clamp $(( RECOMMENDED_SOMAXCONN * 2 )) 2048 "$backlog_cap")"
  RECOMMENDED_SYN_BACKLOG="$(clamp $(( RECOMMENDED_SOMAXCONN * 2 )) 2048 "$backlog_cap")"
  RECOMMENDED_CONNTRACK_MAX="$(clamp $(( RAM_MB * 128 * conn_mode_pct * conn_workload_pct / 10000 )) 65536 "$conntrack_cap")"
  RECOMMENDED_FILE_MAX="$(clamp $(( RAM_MB * 512 * conn_mode_pct * conn_workload_pct / 10000 )) 131072 "$filemax_cap")"

  RECOMMENDED_MTU_PROBING=1
  if [ "$TRACEPATH_PMTU" -gt 0 ] && [ "$IFACE_MTU" -gt 0 ] && [ "$TRACEPATH_PMTU" -lt "$IFACE_MTU" ]; then
    RECOMMENDED_MTU_PROBING=2
    note "链路 path MTU 小于网卡 MTU，已把 tcp_mtu_probing 提升为 2，以便更积极地自适应。"
  elif [ "$TUNING_MODE" = "extreme" ]; then
    RECOMMENDED_MTU_PROBING=2
  fi

  if [ "$BBR_AVAILABLE" -eq 1 ]; then
    RECOMMENDED_CC="bbr"
  elif printf '%s\n' "$AVAILABLE_CC" | grep -qw cubic; then
    RECOMMENDED_CC="cubic"
    warn "当前内核未检测到 bbr，已回退为 cubic。若需要 BBR，请先升级或启用支持 BBR 的内核模块。"
  else
    RECOMMENDED_CC="$CURRENT_CC"
    warn "未检测到可用的 bbr/cubic 切换目标，将保持当前拥塞控制算法。"
  fi

  case "$QDISC_CHOICE" in
    auto)
      if [ "$PROFILE" = "latency" ] || [ "$WORKLOAD" = "gaming" ]; then
        RECOMMENDED_QDISC="fq_codel"
      else
        RECOMMENDED_QDISC="fq"
      fi
      ;;
    *)
      RECOMMENDED_QDISC="$QDISC_CHOICE"
      ;;
  esac
  validate_qdisc_support_if_possible "$RECOMMENDED_QDISC" || true

  if [ "$RECOMMENDED_QDISC" = "cake" ] && [ "$EFFECTIVE_BANDWIDTH_MBPS" -ge 5000 ]; then
    warn "你选择了 cake，但当前带宽较高；cake 的 CPU 开销可能明显高于 fq/fq_codel。"
  fi

  if [ "$CURRENT_QDISC" = "mq" ]; then
    LIVE_QDISC_SAFE=0
    note "当前网卡 root qdisc 为 mq，多队列设备上跳过 live replace，改为仅写入 default_qdisc=${RECOMMENDED_QDISC}。"
  elif [ "$CURRENT_QDISC" = "unknown" ] || [ -z "$DEFAULT_IFACE" ]; then
    LIVE_QDISC_SAFE=0
  else
    LIVE_QDISC_SAFE=1
  fi

  if [ "$SWAP_MB" -eq 0 ] && [ "$RAM_MB" -lt 1024 ]; then
    warn "检测到内存较小且无 Swap，建议先补充少量 Swap 再压测。"
  fi

  if [ -n "$MTR_TARGET_LOSS" ] && awk -v loss="$MTR_TARGET_LOSS" 'BEGIN {exit !(loss + 0 > 1.0)}'; then
    warn "深度诊断发现链路存在可见丢包（约 ${MTR_TARGET_LOSS}%），极致调优前建议先检查回程质量和上游拥塞。"
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
  emit_sysctl_if_supported "net.ipv4.tcp_mtu_probing" "$RECOMMENDED_MTU_PROBING"
  emit_sysctl_if_supported "net.ipv4.tcp_slow_start_after_idle" "0"
  emit_sysctl_if_supported "net.ipv4.tcp_fastopen" "3"
  emit_sysctl_if_supported "net.ipv4.tcp_notsent_lowat" "$RECOMMENDED_NOTSENT_LOWAT"
  emit_sysctl_if_supported "net.ipv4.tcp_timestamps" "1"
  emit_sysctl_if_supported "net.ipv4.tcp_syncookies" "1"
  emit_sysctl_if_supported "fs.file-max" "$RECOMMENDED_FILE_MAX"

  if [ -n "$RECOMMENDED_TCP_ECN" ]; then
    emit_sysctl_if_supported "net.ipv4.tcp_ecn" "$RECOMMENDED_TCP_ECN"
  fi

  if [ -n "$RECOMMENDED_TCP_NO_METRICS_SAVE" ]; then
    emit_sysctl_if_supported "net.ipv4.tcp_no_metrics_save" "$RECOMMENDED_TCP_NO_METRICS_SAVE"
  fi

  if [ -n "$RECOMMENDED_TCP_FIN_TIMEOUT" ]; then
    emit_sysctl_if_supported "net.ipv4.tcp_fin_timeout" "$RECOMMENDED_TCP_FIN_TIMEOUT"
  fi

  if [ -n "$RECOMMENDED_TCP_TW_REUSE" ]; then
    emit_sysctl_if_supported "net.ipv4.tcp_tw_reuse" "$RECOMMENDED_TCP_TW_REUSE"
  fi

  if [ -n "$RECOMMENDED_IP_LOCAL_PORT_RANGE" ]; then
    emit_sysctl_if_supported "net.ipv4.ip_local_port_range" "$RECOMMENDED_IP_LOCAL_PORT_RANGE"
  fi

  if [ -n "$RECOMMENDED_NETDEV_BUDGET" ]; then
    emit_sysctl_if_supported "net.core.netdev_budget" "$RECOMMENDED_NETDEV_BUDGET"
  fi

  if [ -n "$RECOMMENDED_NETDEV_BUDGET_USECS" ]; then
    emit_sysctl_if_supported "net.core.netdev_budget_usecs" "$RECOMMENDED_NETDEV_BUDGET_USECS"
  fi

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
# Preset: $PRESET
# Profile: $PROFILE
# Tuning mode: $TUNING_MODE
# Workload: $WORKLOAD
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

  if [ "$CURRENT_QDISC" = "$RECOMMENDED_QDISC" ]; then
    return
  fi

  if tc qdisc replace dev "$DEFAULT_IFACE" root "$RECOMMENDED_QDISC" >/dev/null 2>&1; then
    ok "已为 $DEFAULT_IFACE 即时切换 root qdisc -> $RECOMMENDED_QDISC"
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
  Preset        : $PRESET
  Tuning mode   : $TUNING_MODE
  Workload      : $WORKLOAD
  Congestion    : $RECOMMENDED_CC
  default_qdisc : $RECOMMENDED_QDISC
  Buffer max    : $RECOMMENDED_BUFFER_BYTES bytes
  tcp_rmem      : 4096 ${RECOMMENDED_RMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}
  tcp_wmem      : 4096 ${RECOMMENDED_WMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}
  tcp_mtu_probe : $RECOMMENDED_MTU_PROBING
  tcp_notsent   : $RECOMMENDED_NOTSENT_LOWAT
  somaxconn     : $RECOMMENDED_SOMAXCONN
  backlog       : $RECOMMENDED_BACKLOG
  syn_backlog   : $RECOMMENDED_SYN_BACKLOG
  conntrack     : $RECOMMENDED_CONNTRACK_MAX
  file-max      : $RECOMMENDED_FILE_MAX
EOF

  if [ -n "$RECOMMENDED_IP_LOCAL_PORT_RANGE" ] || [ -n "$RECOMMENDED_TCP_ECN" ] || [ -n "$RECOMMENDED_TCP_TW_REUSE" ] || [ -n "$RECOMMENDED_TCP_FIN_TIMEOUT" ]; then
    printf '  extras        :'
    [ -n "$RECOMMENDED_TCP_ECN" ] && printf ' tcp_ecn=%s' "$RECOMMENDED_TCP_ECN"
    [ -n "$RECOMMENDED_TCP_NO_METRICS_SAVE" ] && printf ' tcp_no_metrics_save=%s' "$RECOMMENDED_TCP_NO_METRICS_SAVE"
    [ -n "$RECOMMENDED_TCP_FIN_TIMEOUT" ] && printf ' tcp_fin_timeout=%s' "$RECOMMENDED_TCP_FIN_TIMEOUT"
    [ -n "$RECOMMENDED_TCP_TW_REUSE" ] && printf ' tcp_tw_reuse=%s' "$RECOMMENDED_TCP_TW_REUSE"
    [ -n "$RECOMMENDED_IP_LOCAL_PORT_RANGE" ] && printf ' ip_local_port_range="%s"' "$RECOMMENDED_IP_LOCAL_PORT_RANGE"
    printf '\n'
  fi

  if [ "${#PING_RESULTS[@]}" -gt 0 ]; then
    printf '\nRTT 明细:\n'
    printf '  %s\n' "${PING_RESULTS[@]}"
  fi

  if [ "$DEEP_DIAGNOSTICS" -eq 1 ]; then
    printf '\n深度诊断:\n'
    printf '  Target        : %s\n' "${DEEP_TARGET:-unknown}"
    printf '  Tracepath MTU : %s\n' "${TRACEPATH_PMTU:-0}"
    printf '  Tracepath Hop : %s\n' "${TRACEPATH_HOPS:-0}"
    printf '  MTR Loss      : %s\n' "${MTR_TARGET_LOSS:-unknown}"
    printf '  MTR Avg       : %s ms\n' "${MTR_TARGET_AVG:-unknown}"
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
    "preset": "$(json_escape "$PRESET")",
    "profile": "$(json_escape "$PROFILE")",
    "tuning_mode": "$(json_escape "$TUNING_MODE")",
    "workload": "$(json_escape "$WORKLOAD")",
    "region": "$(json_escape "$REGION")",
    "congestion_control": "$(json_escape "$RECOMMENDED_CC")",
    "default_qdisc": "$(json_escape "$RECOMMENDED_QDISC")",
    "buffer_bytes": $RECOMMENDED_BUFFER_BYTES,
    "tcp_rmem": "4096 ${RECOMMENDED_RMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}",
    "tcp_wmem": "4096 ${RECOMMENDED_WMEM_DEFAULT} ${RECOMMENDED_BUFFER_BYTES}",
    "tcp_mtu_probing": $RECOMMENDED_MTU_PROBING,
    "tcp_notsent_lowat": $RECOMMENDED_NOTSENT_LOWAT,
    "somaxconn": $RECOMMENDED_SOMAXCONN,
    "netdev_max_backlog": $RECOMMENDED_BACKLOG,
    "tcp_max_syn_backlog": $RECOMMENDED_SYN_BACKLOG,
    "nf_conntrack_max": $RECOMMENDED_CONNTRACK_MAX,
    "file_max": $RECOMMENDED_FILE_MAX,
    "tcp_ecn": "$(json_escape "$RECOMMENDED_TCP_ECN")",
    "tcp_no_metrics_save": "$(json_escape "$RECOMMENDED_TCP_NO_METRICS_SAVE")",
    "tcp_fin_timeout": "$(json_escape "$RECOMMENDED_TCP_FIN_TIMEOUT")",
    "tcp_tw_reuse": "$(json_escape "$RECOMMENDED_TCP_TW_REUSE")",
    "ip_local_port_range": "$(json_escape "$RECOMMENDED_IP_LOCAL_PORT_RANGE")",
    "skipped_keys": $skipped_json
  },
  "deep_diagnostics": {
    "enabled": $DEEP_DIAGNOSTICS,
    "target": "$(json_escape "$DEEP_TARGET")",
    "tracepath_pmtu": $TRACEPATH_PMTU,
    "tracepath_hops": $TRACEPATH_HOPS,
    "mtr_loss_percent": "$(json_escape "$MTR_TARGET_LOSS")",
    "mtr_avg_ms": "$(json_escape "$MTR_TARGET_AVG")"
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
  apply_preset_defaults
  run_interactive_wizard
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
