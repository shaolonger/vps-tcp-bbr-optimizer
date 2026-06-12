#!/bin/sh

set -eu

REPO="${VPS_TCP_BBR_OPTIMIZER_REPO:-shaolonger/vps-tcp-bbr-optimizer}"
REF="${VPS_TCP_BBR_OPTIMIZER_REF:-main}"
SCRIPT_PATH="${VPS_TCP_BBR_OPTIMIZER_SCRIPT:-vps-tcp-bbr-optimizer.sh}"
SCRIPT_URL="${VPS_TCP_BBR_OPTIMIZER_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/${SCRIPT_PATH}}"

info() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

download_script() {
  local output_file="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SCRIPT_URL" -o "$output_file"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$output_file" "$SCRIPT_URL"
    return 0
  fi

  fail "缺少 curl 或 wget，无法下载主脚本。"
}

main() {
  local tmp_file=""
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/vps-tcp-bbr-optimizer.XXXXXX")"
  trap 'rm -f "$tmp_file"' EXIT INT TERM

  info "下载主脚本: $SCRIPT_URL"
  download_script "$tmp_file"
  chmod +x "$tmp_file"

  info "启动主脚本..."
  info "默认会进入交互式向导，按回车即可采用推荐默认值。"
  export VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE="${VPS_TCP_BBR_OPTIMIZER_SCRIPT_NAME_OVERRIDE:-install.sh}"
  exec sh "$tmp_file" "$@"
}

main "$@"
