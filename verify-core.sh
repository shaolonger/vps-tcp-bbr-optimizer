#!/bin/sh

if [ "${VPS_TCP_BBR_OPTIMIZER_VERIFY_BASH_STAGE:-0}" != "1" ]; then
  if command -v bash >/dev/null 2>&1; then
    VPS_TCP_BBR_OPTIMIZER_VERIFY_BASH_STAGE=1 exec bash "$0" "$@"
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
    VPS_TCP_BBR_OPTIMIZER_VERIFY_BASH_STAGE=1 exec bash "$0" "$@"
  fi

  echo "bash 安装后仍不可用，请检查系统环境。" >&2
  exit 1
fi

unset VPS_TCP_BBR_OPTIMIZER_VERIFY_BASH_STAGE

set -euo pipefail

RAW_NAME="$(basename "$0" 2>/dev/null || printf 'verify-core.sh')"
case "$RAW_NAME" in
  sh|bash|dash)
    SCRIPT_NAME="${VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE:-verify.sh}"
    ;;
  *)
    SCRIPT_NAME="${VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE:-$RAW_NAME}"
    ;;
esac

SCRIPT_VERSION="0.2.1"
STATE_DIR="${VPS_TCP_BBR_OPTIMIZER_VERIFY_STATE_DIR:-/var/lib/vps-tcp-bbr-optimizer/verify}"
BASELINE_FILE="${STATE_DIR}/baseline.snapshot"
CURRENT_FILE="${STATE_DIR}/current.snapshot"
CONF_PATH="${VPS_TCP_BBR_OPTIMIZER_CONF_PATH:-/etc/sysctl.d/99-vps-tcp-bbr-optimizer.conf}"

MODE="auto"
PING_TARGET="${VPS_TCP_BBR_OPTIMIZER_VERIFY_TARGET:-1.1.1.1}"
PING_ENABLED=1

GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[31m')"
BLUE="$(printf '\033[34m')"
GRAY="$(printf '\033[90m')"
RESET="$(printf '\033[0m')"

SYSCTL_KEYS=(
  "net.ipv4.tcp_congestion_control"
  "net.core.default_qdisc"
  "net.ipv4.tcp_mtu_probing"
  "net.ipv4.tcp_slow_start_after_idle"
  "net.ipv4.tcp_fastopen"
  "net.ipv4.tcp_ecn"
  "net.ipv4.tcp_no_metrics_save"
  "net.ipv4.tcp_fin_timeout"
  "net.ipv4.tcp_tw_reuse"
  "net.ipv4.ip_local_port_range"
  "net.ipv4.tcp_sack"
  "net.ipv4.tcp_window_scaling"
  "net.core.rmem_max"
  "net.core.wmem_max"
  "net.core.rmem_default"
  "net.core.wmem_default"
  "net.core.somaxconn"
  "net.core.netdev_max_backlog"
  "net.core.netdev_budget"
  "net.core.netdev_budget_usecs"
  "net.ipv4.tcp_max_syn_backlog"
  "net.ipv4.tcp_rmem"
  "net.ipv4.tcp_wmem"
  "net.ipv4.tcp_notsent_lowat"
  "net.netfilter.nf_conntrack_max"
  "fs.file-max"
)

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

用途:
  生成 VPS TCP/BBR 优化前后的控制台对比报告。

用法:
  sudo sh $SCRIPT_NAME
  sudo sh $SCRIPT_NAME --before
  sudo sh $SCRIPT_NAME --after
  sudo sh $SCRIPT_NAME --current-only
  sudo sh $SCRIPT_NAME --reset

模式:
  默认 auto:
    - 如果没有基线，就保存一份“执行前”基线
    - 如果已经有基线，就抓取当前状态并输出前后对比

选项:
  --before               强制覆盖保存基线快照。
  --after                基于已保存基线生成前后对比报告。
  --current-only         只显示当前状态与已安装配置的一致性，不做前后对比。
  --reset                删除已保存的基线和当前快照。
  --target HOST          指定 ping 对比目标，默认 1.1.1.1。
  --no-ping              跳过 ping 指标，只比较配置与 qdisc。
  --help, -h             显示帮助。

典型流程:
  1. 安装前运行一次:  curl -fsSL .../verify.sh | sudo sh
  2. 应用优化脚本
  3. 再运行一次同样命令，自动输出前后对比报告
EOF
}

info() {
  printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"
}

ok() {
  printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"
}

warn() {
  printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"
}

die() {
  printf "%s[FAIL]%s %s\n" "$RED" "$RESET" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_linux() {
  [ "$(uname -s)" = "Linux" ] || die "此脚本仅支持 Linux。"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 或 sudo 运行。"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --before)
        MODE="before"
        ;;
      --after)
        MODE="after"
        ;;
      --current-only)
        MODE="current"
        ;;
      --reset)
        MODE="reset"
        ;;
      --target)
        shift
        PING_TARGET="${1:-}"
        ;;
      --no-ping)
        PING_ENABLED=0
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

  [ -n "$PING_TARGET" ] || PING_TARGET="1.1.1.1"
}

ensure_sysctl() {
  command_exists sysctl || die "缺少 sysctl 命令。"
}

ensure_ip() {
  command_exists ip || die "缺少 ip 命令。"
}

write_record() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  printf '%s\t%s\t%s\n' "$section" "$key" "$(normalize_value "$value")" >>"$file"
}

read_record() {
  local file="$1"
  local section="$2"
  local key="$3"
  [ -f "$file" ] || return 0
  awk -F '\t' -v want_section="$section" -v want_key="$key" '
    $1 == want_section && $2 == want_key {
      print $3
      exit
    }
  ' "$file"
}

normalize_value() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
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

get_root_qdisc() {
  local iface="$1"
  if command_exists tc && [ -n "$iface" ]; then
    tc qdisc show dev "$iface" 2>/dev/null | awk 'NR == 1 {print $2; exit}'
  fi
}

get_root_qdisc_full() {
  local iface="$1"
  if command_exists tc && [ -n "$iface" ]; then
    tc qdisc show dev "$iface" 2>/dev/null | awk 'NR == 1 {sub(/^qdisc /, ""); print; exit}'
  fi
}

capture_ping_metrics() {
  local out_file="$1"
  local ping_line=""
  local min_ms=""
  local avg_ms=""
  local max_ms=""

  if [ "$PING_ENABLED" -ne 1 ]; then
    write_record "$out_file" "metric" "ping_enabled" "0"
    return
  fi

  if ! command_exists ping; then
    write_record "$out_file" "metric" "ping_enabled" "0"
    write_record "$out_file" "metric" "ping_status" "missing"
    return
  fi

  ping_line="$(
    {
      ping -c 6 -W 1 "$PING_TARGET" 2>/dev/null ||
      ping -c 6 "$PING_TARGET" 2>/dev/null ||
      true
    } | awk -F'= ' '/rtt|round-trip/ {print $2; exit}'
  )"

  write_record "$out_file" "metric" "ping_enabled" "1"
  write_record "$out_file" "metric" "ping_target" "$PING_TARGET"

  if [ -z "$ping_line" ]; then
    write_record "$out_file" "metric" "ping_status" "failed"
    return
  fi

  min_ms="$(printf '%s' "$ping_line" | cut -d'/' -f1 | tr -d ' ')"
  avg_ms="$(printf '%s' "$ping_line" | cut -d'/' -f2 | tr -d ' ')"
  max_ms="$(printf '%s' "$ping_line" | cut -d'/' -f3 | tr -d ' ')"

  write_record "$out_file" "metric" "ping_status" "ok"
  write_record "$out_file" "metric" "ping_min_ms" "$min_ms"
  write_record "$out_file" "metric" "ping_avg_ms" "$avg_ms"
  write_record "$out_file" "metric" "ping_max_ms" "$max_ms"
}

capture_snapshot() {
  local out_file="$1"
  local iface=""
  local root_qdisc=""
  local root_qdisc_full=""
  local key=""
  local value=""

  ensure_sysctl
  ensure_ip

  : >"$out_file"
  iface="$(get_default_iface)"
  root_qdisc="$(get_root_qdisc "$iface")"
  root_qdisc_full="$(get_root_qdisc_full "$iface")"

  write_record "$out_file" "meta" "timestamp" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  write_record "$out_file" "meta" "hostname" "$(hostname 2>/dev/null || printf 'unknown')"
  write_record "$out_file" "meta" "kernel" "$(uname -r 2>/dev/null || printf 'unknown')"
  write_record "$out_file" "meta" "iface" "${iface:-unknown}"
  write_record "$out_file" "meta" "root_qdisc" "${root_qdisc:-unknown}"
  write_record "$out_file" "meta" "root_qdisc_full" "${root_qdisc_full:-unknown}"

  for key in "${SYSCTL_KEYS[@]}"; do
    value="$(normalize_value "$(sysctl -n "$key" 2>/dev/null || printf '__missing__')")"
    write_record "$out_file" "sysctl" "$key" "$value"
  done

  capture_ping_metrics "$out_file"
}

config_value() {
  local key="$1"
  if [ ! -f "$CONF_PATH" ]; then
    return 0
  fi
  awk -F'=' -v want_key="$key" '
    $1 ~ /^[[:space:]]*#/ { next }
    {
      left=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == want_key) {
        right=$2
        gsub(/[[:space:]][[:space:]]+/, " ", right)
        sub(/^[[:space:]]+/, "", right)
        sub(/[[:space:]]+$/, "", right)
        print right
        exit
      }
    }
  ' "$CONF_PATH"
}

pretty_name() {
  case "$1" in
    net.ipv4.tcp_congestion_control) printf '%s' "拥塞控制" ;;
    net.core.default_qdisc) printf '%s' "默认 qdisc" ;;
    net.ipv4.tcp_mtu_probing) printf '%s' "MTU 探测" ;;
    net.ipv4.tcp_slow_start_after_idle) printf '%s' "空闲后慢启动" ;;
    net.ipv4.tcp_fastopen) printf '%s' "TCP Fast Open" ;;
    net.ipv4.tcp_ecn) printf '%s' "ECN" ;;
    net.ipv4.tcp_no_metrics_save) printf '%s' "No Metrics Save" ;;
    net.ipv4.tcp_fin_timeout) printf '%s' "FIN Timeout" ;;
    net.ipv4.tcp_tw_reuse) printf '%s' "TW Reuse" ;;
    net.ipv4.ip_local_port_range) printf '%s' "端口范围" ;;
    net.ipv4.tcp_sack) printf '%s' "SACK" ;;
    net.ipv4.tcp_window_scaling) printf '%s' "窗口缩放" ;;
    net.core.rmem_max) printf '%s' "rmem_max" ;;
    net.core.wmem_max) printf '%s' "wmem_max" ;;
    net.core.rmem_default) printf '%s' "rmem_default" ;;
    net.core.wmem_default) printf '%s' "wmem_default" ;;
    net.core.somaxconn) printf '%s' "somaxconn" ;;
    net.core.netdev_max_backlog) printf '%s' "netdev backlog" ;;
    net.core.netdev_budget) printf '%s' "netdev budget" ;;
    net.core.netdev_budget_usecs) printf '%s' "netdev budget usecs" ;;
    net.ipv4.tcp_max_syn_backlog) printf '%s' "syn backlog" ;;
    net.ipv4.tcp_rmem) printf '%s' "tcp_rmem" ;;
    net.ipv4.tcp_wmem) printf '%s' "tcp_wmem" ;;
    net.ipv4.tcp_notsent_lowat) printf '%s' "notsent_lowat" ;;
    net.netfilter.nf_conntrack_max) printf '%s' "conntrack max" ;;
    fs.file-max) printf '%s' "file-max" ;;
    ping_avg_ms) printf '%s' "Ping Avg (ms)" ;;
    root_qdisc) printf '%s' "Root qdisc" ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

status_text() {
  local before="$1"
  local current="$2"
  local expected="$3"

  if [ -n "$expected" ]; then
    if [ "$current" = "$expected" ]; then
      printf '%sMATCH%s' "$GREEN" "$RESET"
    else
      printf '%sDRIFT%s' "$RED" "$RESET"
    fi
    return
  fi

  if [ "$before" = "$current" ]; then
    printf '%sUNCHANGED%s' "$GRAY" "$RESET"
  else
    printf '%sCHANGED%s' "$YELLOW" "$RESET"
  fi
}

ping_status_text() {
  local before="$1"
  local current="$2"

  if [ -z "$before" ] || [ -z "$current" ] || [ "$before" = "failed" ] || [ "$current" = "failed" ]; then
    printf '%sN/A%s' "$GRAY" "$RESET"
    return
  fi

  awk -v b="$before" -v c="$current" '
    BEGIN {
      if (c + 0 < b + 0) {
        print "IMPROVED"
      } else if (c + 0 > b + 0) {
        print "WORSE"
      } else {
        print "UNCHANGED"
      }
    }
  '
}

print_line() {
  local name="$1"
  local before="$2"
  local current="$3"
  local expected="$4"
  local status="$5"
  printf '%-20s %-18s %-18s %-18s %s\n' "$name" "$before" "$current" "${expected:--}" "$status"
}

print_snapshot_summary() {
  local file="$1"
  printf '时间: %s\n' "$(read_record "$file" meta timestamp)"
  printf '主机: %s\n' "$(read_record "$file" meta hostname)"
  printf '内核: %s\n' "$(read_record "$file" meta kernel)"
  printf '网卡: %s\n' "$(read_record "$file" meta iface)"
  printf 'Root qdisc: %s\n' "$(read_record "$file" meta root_qdisc_full)"
  if [ "$(read_record "$file" metric ping_enabled)" = "1" ]; then
    printf 'Ping 目标: %s\n' "$(read_record "$file" metric ping_target)"
    if [ "$(read_record "$file" metric ping_status)" = "ok" ]; then
      printf 'Ping Avg: %s ms\n' "$(read_record "$file" metric ping_avg_ms)"
    else
      printf 'Ping Avg: %s\n' "$(read_record "$file" metric ping_status)"
    fi
  fi
}

save_baseline() {
  ensure_dirs
  capture_snapshot "$BASELINE_FILE"
  ok "已保存基线快照: $BASELINE_FILE"
  printf '\n当前基线摘要:\n'
  print_snapshot_summary "$BASELINE_FILE"
  printf '\n下一步:\n'
  printf '  1. 执行安装/优化脚本\n'
  printf '  2. 再次运行同一条 verify 命令，自动生成前后对比报告\n'
}

print_current_report() {
  local current_file="$1"
  local key=""
  local current=""
  local expected=""
  local matched=0
  local total=0

  printf '当前状态摘要:\n'
  print_snapshot_summary "$current_file"
  printf '\n配置一致性检查:\n'
  printf '%-20s %-18s %-18s %-18s %s\n' "项目" "Before" "Current" "Expected" "状态"
  printf '%s\n' "------------------------------------------------------------------------------------------"

  for key in "${SYSCTL_KEYS[@]}"; do
    current="$(read_record "$current_file" sysctl "$key")"
    expected="$(config_value "$key")"
    if [ -n "$expected" ]; then
      total=$(( total + 1 ))
      if [ "$current" = "$expected" ]; then
        matched=$(( matched + 1 ))
      fi
    fi
    print_line "$(pretty_name "$key")" "-" "$current" "$expected" "$(status_text "" "$current" "$expected")"
  done

  printf '\n'
  if [ "$total" -gt 0 ]; then
    printf '已安装配置匹配: %s/%s\n' "$matched" "$total"
  else
    warn "未找到 $CONF_PATH，无法对照已安装配置。"
  fi
}

compare_with_baseline() {
  local before_file="$1"
  local current_file="$2"
  local key=""
  local before=""
  local current=""
  local expected=""
  local matched=0
  local total=0
  local ping_before=""
  local ping_current=""
  local ping_eval=""
  local root_before=""
  local root_current=""

  printf '基线摘要:\n'
  print_snapshot_summary "$before_file"
  printf '\n当前摘要:\n'
  print_snapshot_summary "$current_file"
  printf '\n前后对比:\n'
  printf '%-20s %-18s %-18s %-18s %s\n' "项目" "Before" "Current" "Expected" "状态"
  printf '%s\n' "------------------------------------------------------------------------------------------"

  root_before="$(read_record "$before_file" meta root_qdisc)"
  root_current="$(read_record "$current_file" meta root_qdisc)"
  print_line "$(pretty_name root_qdisc)" "${root_before:-unknown}" "${root_current:-unknown}" "-" "$(status_text "$root_before" "$root_current" "")"

  for key in "${SYSCTL_KEYS[@]}"; do
    before="$(read_record "$before_file" sysctl "$key")"
    current="$(read_record "$current_file" sysctl "$key")"
    expected="$(config_value "$key")"
    if [ -n "$expected" ]; then
      total=$(( total + 1 ))
      if [ "$current" = "$expected" ]; then
        matched=$(( matched + 1 ))
      fi
    fi
    print_line "$(pretty_name "$key")" "$before" "$current" "$expected" "$(status_text "$before" "$current" "$expected")"
  done

  if [ "$(read_record "$before_file" metric ping_enabled)" = "1" ] && [ "$(read_record "$current_file" metric ping_enabled)" = "1" ]; then
    ping_before="$(read_record "$before_file" metric ping_avg_ms)"
    ping_current="$(read_record "$current_file" metric ping_avg_ms)"
    ping_eval="$(ping_status_text "$ping_before" "$ping_current")"
    print_line "$(pretty_name ping_avg_ms)" "${ping_before:--}" "${ping_current:--}" "-" "$ping_eval"
  fi

  printf '\n总结:\n'
  if [ "$total" -gt 0 ]; then
    printf '  已安装配置匹配: %s/%s\n' "$matched" "$total"
  else
    printf '  已安装配置匹配: 未检测到 %s\n' "$CONF_PATH"
  fi

  if [ "$root_current" = "mq" ]; then
    printf '  Root qdisc 提示: 当前为 mq，这在多队列网卡上很常见，不代表 fq 默认策略没有生效。\n'
  fi

  if [ -n "$ping_eval" ]; then
    printf '  Ping 结果: %s\n' "$ping_eval"
  fi
}

reset_state() {
  rm -f "$BASELINE_FILE" "$CURRENT_FILE"
  ok "已清空 verify 状态文件"
}

main() {
  parse_args "$@"
  require_linux
  require_root

  case "$MODE" in
    reset)
      reset_state
      exit 0
      ;;
    before)
      save_baseline
      exit 0
      ;;
    current)
      ensure_dirs
      capture_snapshot "$CURRENT_FILE"
      print_current_report "$CURRENT_FILE"
      exit 0
      ;;
    after)
      [ -f "$BASELINE_FILE" ] || die "未找到基线快照，请先运行一次 $SCRIPT_NAME 保存基线。"
      ensure_dirs
      capture_snapshot "$CURRENT_FILE"
      compare_with_baseline "$BASELINE_FILE" "$CURRENT_FILE"
      exit 0
      ;;
    auto)
      ensure_dirs
      if [ ! -f "$BASELINE_FILE" ]; then
        save_baseline
      else
        capture_snapshot "$CURRENT_FILE"
        compare_with_baseline "$BASELINE_FILE" "$CURRENT_FILE"
      fi
      ;;
  esac
}

main "$@"
