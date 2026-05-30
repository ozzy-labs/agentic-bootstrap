#!/bin/bash
# =======================================================================
# tests/smoke/run.sh
# -----------------------------------------------------------------------
# セットアップスクリプトに対する最速のサニティチェック。
# ネットワーク・sudo・apt を一切使わず、5 秒以内に完了するよう設計。
#
# 検証内容:
#   - install.sh の引数解析 / --help 出力
#   - update-tools.sh の引数解析 / --help / --dry-run 出力
#   - 全シェルスクリプトの構文チェック（bash -n）
#
# Usage:
#   ./tests/smoke/run.sh
# =======================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

PASS=0
FAIL=0
START_TIME=$(date +%s%N)

# ------------------------------------------------------------------
# ヘルパー関数
# ------------------------------------------------------------------

# $1: テスト名, $2...: コマンドと引数
# stdout をキャプチャし exit 0 を期待
assert_success() {
  local name="$1"
  shift
  printf '▶ %s\n' "$name"
  if "$@" >/dev/null 2>&1; then
    printf '  ✅ pass\n'
    PASS=$((PASS + 1))
  else
    printf '  ❌ fail (exit=%d, cmd: %s)\n' "$?" "$*"
    FAIL=$((FAIL + 1))
  fi
}

# $1: テスト名, $2...: コマンドと引数
# exit 非 0 を期待
assert_failure() {
  local name="$1"
  shift
  printf '▶ %s\n' "$name"
  if "$@" >/dev/null 2>&1; then
    printf '  ❌ fail (expected non-zero exit, got 0)\n'
    FAIL=$((FAIL + 1))
  else
    printf '  ✅ pass (exit=%d)\n' "$?"
    PASS=$((PASS + 1))
  fi
}

# $1: テスト名, $2: 期待するパターン, $3...: コマンドと引数
# stdout に期待パターンが含まれることを検証
assert_stdout_contains() {
  local name="$1"
  local pattern="$2"
  shift 2
  printf '▶ %s\n' "$name"
  local output
  if output=$("$@" 2>/dev/null); then
    if printf '%s' "$output" | grep -q -- "$pattern"; then
      printf '  ✅ pass\n'
      PASS=$((PASS + 1))
    else
      printf '  ❌ fail (missing pattern: %s)\n' "$pattern"
      FAIL=$((FAIL + 1))
    fi
  else
    printf '  ❌ fail (command exited non-zero)\n'
    FAIL=$((FAIL + 1))
  fi
}

# ------------------------------------------------------------------
# 1. install.sh の引数解析
# ------------------------------------------------------------------

assert_stdout_contains "install.sh --help prints Usage" \
  "Usage:" \
  bash install.sh --help

assert_stdout_contains "install.sh --help lists subcommands" \
  "zsh|local|all|update|doctor" \
  bash install.sh --help

assert_failure "install.sh rejects unknown flag" \
  bash install.sh --bogus-flag-xyz

assert_failure "install.sh rejects unknown positional arg" \
  bash install.sh unknown-subcommand

# README §4 のクイックスタートで案内している `curl ... | bash -s -- ...`
# 実行形態のサニティチェック。pipe 経由で実行されると BASH_SOURCE[0] が
# ファイルとして存在しないため、install.sh はダウンロード経路に入る。
# 過去に `local tmp_dir` を参照する EXIT trap が set -u 下で unbound に
# なる回帰があったため、--help でも pipe 経路のスモークを残す。
assert_stdout_contains "install.sh works via stdin pipe (curl|bash style)" \
  "Usage:" \
  bash -c 'cat install.sh | bash -s -- --help'

assert_stdout_contains "install.sh --ref accepts value via stdin pipe" \
  "Usage:" \
  bash -c 'cat install.sh | bash -s -- --ref main --help'

# ------------------------------------------------------------------
# 2. update-tools.sh の引数解析 / --dry-run
# ------------------------------------------------------------------

assert_stdout_contains "update-tools.sh --help prints header" \
  "update-tools.sh" \
  bash scripts/update-tools.sh --help

assert_stdout_contains "update-tools.sh --dry-run emits dry-run markers" \
  "dry-run" \
  bash scripts/update-tools.sh --dry-run

assert_failure "update-tools.sh rejects unknown flag" \
  bash scripts/update-tools.sh --bogus-flag-xyz

# ------------------------------------------------------------------
# 3. 構文チェック（bash -n）
# ------------------------------------------------------------------

assert_success "install.sh syntax check" \
  bash -n install.sh

assert_success "setup-local-linux.sh syntax check" \
  bash -n scripts/setup-local-linux.sh

assert_success "setup-local-macos.sh syntax check" \
  bash -n scripts/setup-local-macos.sh

assert_success "setup-zsh-linux.sh syntax check" \
  bash -n scripts/setup-zsh-linux.sh

assert_success "update-tools.sh syntax check" \
  bash -n scripts/update-tools.sh

assert_success "doctor.sh syntax check" \
  bash -n scripts/doctor.sh

# ------------------------------------------------------------------
# サマリー
# ------------------------------------------------------------------

END_TIME=$(date +%s%N)
ELAPSED_MS=$(((END_TIME - START_TIME) / 1000000))
TOTAL=$((PASS + FAIL))

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if [ "$FAIL" -eq 0 ]; then
  printf '✅ All %d smoke tests passed (%dms)\n' "$TOTAL" "$ELAPSED_MS"
  exit 0
else
  printf '❌ %d of %d smoke tests failed (%dms)\n' "$FAIL" "$TOTAL" "$ELAPSED_MS"
  exit 1
fi
