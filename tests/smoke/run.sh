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

# scripts/lib/*.sh の構文チェック（audit gap δ-2）。
# トップレベル 6 スクリプトしか syntax check していなかったため、lib 配下に
# bash -n エラーが混入すると smoke を通過し integration まで検知が遅れていた。
# ここで全 lib を網羅的にチェックする。
for lib in scripts/lib/*.sh; do
  assert_success "syntax check: $lib" bash -n "$lib"
done

# ------------------------------------------------------------------
# 4. doctor.sh exit code 範囲チェック（audit gap δ-3）
# ------------------------------------------------------------------
#
# doctor は 0 / 1 / 2 を返す仕様（README §6.5.2）。smoke は health check
# ではなく「doctor が発火し、仕様範囲内の exit code を返す」ことの sanity
# check に徹する。仕様 0/1/2 をそのまま全て受け入れる:
#   - 0: 健全
#   - 1: warn あり（推奨ツール未導入等）
#   - 2: error あり（必須ツール欠落等）— CI runner や mise キャッシュ状態次第で
#        起こりうる。doctor 自体が動いて結果を返している事実は意味があるので
#        smoke では pass とする（健全性チェックは integration / canary が担当）。
#   - 3+: 仕様外。doctor 自身の bug 候補なので fail。
#
# 過去の narrow 版（0/1 のみ許容）は CI runner で exit=2 が出て smoke を
# 落としたため、spec 通り {0,1,2} に戻した（PR #163 follow-up）。
#
# NOTE: 本スクリプトは `set -u` のみで `set -e` を使わない。errexit を grab する
# 必要がないため `|| doctor_exit=$?` で exit code を捕捉する pattern を使う。
printf '▶ doctor.sh exit code in {0,1,2}\n'
doctor_exit=0
bash scripts/doctor.sh >/dev/null 2>&1 || doctor_exit=$?
if [ "$doctor_exit" -ge 0 ] && [ "$doctor_exit" -le 2 ]; then
  printf '  ✅ pass (exit=%d)\n' "$doctor_exit"
  PASS=$((PASS + 1))
else
  printf '  ❌ fail (exit=%d, expected 0/1/2 per README §6.5.2)\n' "$doctor_exit"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# 5. rename identifier pins
# ------------------------------------------------------------------
#
# 旧名 agentic-bootstrap → 新名 agentyard のリネーム後、誤って旧名に
# 戻る regression や typo を merge 前に検知するための固定。CI 上で
# lefthook は直接実行されないため、hook id rename はここでないと検知不能。

assert_stdout_contains "install.sh --help advertises AGENTYARD_REF" \
  "AGENTYARD_REF" \
  bash install.sh --help

assert_stdout_contains "install.sh --help advertises AGENTYARD_ASSUME_YES" \
  "AGENTYARD_ASSUME_YES" \
  bash install.sh --help

assert_stdout_contains "install.sh --help points to ozzy-labs/agentyard" \
  "ozzy-labs/agentyard" \
  bash install.sh --help

assert_success "install.sh REPO_NAME is agentyard" \
  grep -q '^readonly REPO_NAME="agentyard"$' install.sh

assert_success "lefthook.yaml defines agentyard-shell hook" \
  grep -q '^[[:space:]]*agentyard-shell:' lefthook.yaml

assert_success "lefthook.yaml defines agentyard-trivy hook" \
  grep -q '^[[:space:]]*agentyard-trivy:' lefthook.yaml

assert_success "release-please-config.json declares package-name agentyard" \
  grep -q '"package-name": "agentyard"' release-please-config.json

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
