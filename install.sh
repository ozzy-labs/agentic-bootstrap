#!/usr/bin/env bash
set -euo pipefail

readonly REPO_OWNER="ozzy-labs"
readonly REPO_NAME="agentyard"
readonly DEFAULT_REF="${AGENTYARD_REF:-${AGENTIC_BOOTSTRAP_REF:-${BOOTSTRAP_REF:-main}}}"

# OS 判定: install.sh local / all が dispatch 先のスクリプトを切り替えるために使う
detect_os() {
  case "$(uname -s)" in
  Linux*) printf 'linux' ;;
  Darwin*) printf 'darwin' ;;
  *) printf 'unknown' ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [zsh|local|all|update|doctor] [--ref <git-ref>] [--auto|--interactive]
  curl -fsSL https://raw.githubusercontent.com/ozzy-labs/agentyard/main/install.sh | bash -s -- [zsh|local|all|update|doctor] [--ref <git-ref>] [--auto|--interactive]

Commands:
  zsh     Run scripts/setup-zsh-linux.sh (Linux/WSL only; macOS skips with a notice)
  local   Run the host setup script for the detected OS
            - Linux  → scripts/setup-local-linux.sh
            - macOS  → scripts/setup-local-macos.sh
  all     Run zsh setup (when supported) + local setup in order (default)
  update  Run scripts/update-tools.sh (batch-update mise/uv/npm managed tools)
  doctor  Run scripts/doctor.sh (diagnose environment integrity, exit 0/1/2)

Options:
  --ref <git-ref>  Download scripts from the specified branch, tag, or commit
  -y, --auto       Apply recommended settings without prompts (non-interactive)
  --interactive    Confirm settings interactively (default)
  -h, --help       Show this help message

Environment:
  AGENTYARD_REF          Default git ref to download when running remotely
                         (legacy: AGENTIC_BOOTSTRAP_REF, BOOTSTRAP_REF are honored as fallbacks)
  AGENTYARD_ASSUME_YES   1 = non-interactive, auto-accept "default Y" prompts and
                         skip "default N" prompts. CI=true also forces this on.
                         (legacy: AGENTIC_BOOTSTRAP_ASSUME_YES, BOOTSTRAP_ASSUME_YES
                         are honored as fallbacks; set via -y/--auto/--interactive too)
  SETUP_LOG              Passed through to the underlying setup/update script(s)
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

download_to_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
    return
  fi

  die "curl or wget is required to download setup files"
}

run_script() {
  local script_path="$1"

  [ -x "$script_path" ] || chmod +x "$script_path"
  log ""
  log "==> Running $(basename "$script_path")"
  "$script_path"
}

local_setup_script_for_os() {
  local base_dir="$1"
  local os
  os="$(detect_os)"
  case "$os" in
  linux) printf '%s/scripts/setup-local-linux.sh' "$base_dir" ;;
  darwin) printf '%s/scripts/setup-local-macos.sh' "$base_dir" ;;
  *) die "Unsupported OS: $(uname -s) (only Linux and macOS are supported)" ;;
  esac
}

run_zsh_setup_if_supported() {
  local base_dir="$1"
  local os
  os="$(detect_os)"
  if [ "$os" = "darwin" ]; then
    log ""
    log "ℹ️  Skipping setup-zsh-linux.sh on macOS (use the system zsh; oh-my-zsh can be installed manually if desired)."
    return 0
  fi
  run_script "$base_dir/scripts/setup-zsh-linux.sh"
}

run_local() {
  local target="$1"
  local base_dir="$2"

  case "$target" in
  zsh)
    run_zsh_setup_if_supported "$base_dir"
    ;;
  local)
    run_script "$(local_setup_script_for_os "$base_dir")"
    ;;
  all)
    run_zsh_setup_if_supported "$base_dir"
    run_script "$(local_setup_script_for_os "$base_dir")"
    ;;
  update)
    run_script "$base_dir/scripts/update-tools.sh"
    ;;
  doctor)
    run_script "$base_dir/scripts/doctor.sh"
    ;;
  *)
    die "Unknown command: $target"
    ;;
  esac
}

main() {
  local target="all"
  local ref="$DEFAULT_REF"

  while [ "$#" -gt 0 ]; do
    case "$1" in
    zsh | local | all | update | doctor)
      target="$1"
      ;;
    --ref)
      [ "$#" -ge 2 ] || die "--ref requires a value"
      ref="$2"
      shift
      ;;
    -y | --auto)
      export AGENTYARD_ASSUME_YES=1
      ;;
    --interactive)
      export AGENTYARD_ASSUME_YES=0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
    esac
    shift
  done

  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    local source_path
    source_path="${BASH_SOURCE[0]}"
    if [ -f "$source_path" ]; then
      local script_dir
      script_dir="$(cd "$(dirname "$source_path")" && pwd)"
      # Local-checkout fast path: skip the download if the dispatched script
      # for the current OS exists alongside install.sh.
      local local_script
      if local_script="$(local_setup_script_for_os "$script_dir" 2>/dev/null)" &&
        [ -f "$local_script" ]; then
        run_local "$target" "$script_dir"
        return
      fi
    fi
  fi

  require_command tar
  require_command mktemp

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # trap は EXIT 発火時点（main 関数を抜けた後）にも評価されるため、
  # local 変数を遅延展開すると set -u 下で unbound variable になる。
  # ここでは tmp_dir の値を即時展開して固定文字列としてトラップに焼き込む。
  # mktemp -d はシングルクォートを含むパスを返さないため安全。
  # shellcheck disable=SC2064  # 即時展開は意図的（local スコープ問題の回避）
  trap "rm -rf -- '$tmp_dir'" EXIT

  local archive_url
  archive_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${ref}"

  log "==> Downloading ${REPO_OWNER}/${REPO_NAME} (${ref})"
  download_to_stdout "$archive_url" | tar -xzf - -C "$tmp_dir"

  local extracted_dir
  extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
  [ -n "$extracted_dir" ] || die "Failed to unpack downloaded archive"

  run_local "$target" "$extracted_dir"
}

main "$@"
