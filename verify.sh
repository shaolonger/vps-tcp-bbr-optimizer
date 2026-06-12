#!/bin/sh

set -eu

REPO="${VPS_TCP_BBR_OPTIMIZER_REPO:-shaolonger/vps-tcp-bbr-optimizer}"
REF="${VPS_TCP_BBR_OPTIMIZER_REF:-main}"
VERIFY_SCRIPT_PATH="${VPS_TCP_BBR_OPTIMIZER_VERIFY_SCRIPT:-verify-core.sh}"
VERIFY_URL="${VPS_TCP_BBR_OPTIMIZER_VERIFY_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/${VERIFY_SCRIPT_PATH}}"

info() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

download_script() {
  output_file="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$VERIFY_URL" -o "$output_file"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$output_file" "$VERIFY_URL"
    return 0
  fi

  fail "缺少 curl 或 wget，无法下载验证脚本。"
}

run_local_or_remote() {
  local_dir=""
  local_file=""
  tmp_file=""

  local_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || local_dir=""
  local_file="${local_dir}/${VERIFY_SCRIPT_PATH}"

  export VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE="${VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE:-verify.sh}"

  if [ -n "$local_dir" ] && [ -f "$local_file" ] && [ "$local_file" != "$0" ]; then
    exec sh "$local_file" "$@"
  fi

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/vps-tcp-bbr-verify.XXXXXX")"
  trap 'rm -f "$tmp_file"' EXIT INT TERM

  info "下载验证脚本: $VERIFY_URL"
  download_script "$tmp_file"
  chmod +x "$tmp_file"

  info "启动验证脚本..."
  exec sh "$tmp_file" "$@"
}

run_local_or_remote "$@"
