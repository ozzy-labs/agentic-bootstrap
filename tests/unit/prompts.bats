#!/usr/bin/env bats
# =======================================================================
# tests/unit/prompts.bats
# -----------------------------------------------------------------------
# scripts/lib/prompts.sh の対話プロンプト関数を非対話モードで検証する。
# 対話モード（実際の read）はテスト困難なため、CI=true 経路のみ確認する。
#
# 注意: REPLY を検証するため、サブシェル経由ではなく現在のシェルで関数を呼ぶ。
# 出力は一時ファイルにリダイレクトしてから検査する。
# =======================================================================

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/detect.sh"
  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/prompts.sh"
  OUT_FILE="$BATS_TEST_TMPDIR/out.txt"
}

# ------------------------------------------------------------------
# _prompt_default_yes (non-interactive)
# ------------------------------------------------------------------

@test "_prompt_default_yes: sets REPLY=Y and prints suffix in non-interactive mode" {
  CI=true
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
  REPLY=""
  _prompt_default_yes "Continue? [Y/n]: " >"$OUT_FILE"
  [ "$REPLY" = "Y" ]
  grep -q "Y (non-interactive)" "$OUT_FILE"
}

@test "_prompt_default_yes: respects AGENTYARD_ASSUME_YES=1 (canonical)" {
  AGENTYARD_ASSUME_YES=1
  unset AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  REPLY=""
  _prompt_default_yes "Continue? [Y/n]: " >"$OUT_FILE"
  [ "$REPLY" = "Y" ]
  grep -q "Y (non-interactive)" "$OUT_FILE"
}

@test "_prompt_default_yes: legacy AGENTIC_BOOTSTRAP_ASSUME_YES=1 still works (fallback)" {
  unset AGENTYARD_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  AGENTIC_BOOTSTRAP_ASSUME_YES=1
  REPLY=""
  _prompt_default_yes "Continue? [Y/n]: " >"$OUT_FILE"
  [ "$REPLY" = "Y" ]
  grep -q "Y (non-interactive)" "$OUT_FILE"
}

@test "_prompt_default_yes: legacy BOOTSTRAP_ASSUME_YES=1 still works (fallback)" {
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES CI
  BOOTSTRAP_ASSUME_YES=1
  REPLY=""
  _prompt_default_yes "Continue? [Y/n]: " >"$OUT_FILE"
  [ "$REPLY" = "Y" ]
  grep -q "Y (non-interactive)" "$OUT_FILE"
}

# ------------------------------------------------------------------
# _prompt_default_no (non-interactive)
# ------------------------------------------------------------------

@test "_prompt_default_no: sets REPLY=N and prints suffix in non-interactive mode" {
  CI=true
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
  REPLY=""
  _prompt_default_no "Continue? [y/N]: " >"$OUT_FILE"
  [ "$REPLY" = "N" ]
  grep -q "N (non-interactive)" "$OUT_FILE"
}

@test "_prompt_default_no: respects AGENTYARD_ASSUME_YES=1 (canonical)" {
  AGENTYARD_ASSUME_YES=1
  unset AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  REPLY=""
  _prompt_default_no "Continue? [y/N]: " >"$OUT_FILE"
  [ "$REPLY" = "N" ]
}

@test "_prompt_default_no: legacy AGENTIC_BOOTSTRAP_ASSUME_YES=1 still works (fallback)" {
  unset AGENTYARD_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  AGENTIC_BOOTSTRAP_ASSUME_YES=1
  REPLY=""
  _prompt_default_no "Continue? [y/N]: " >"$OUT_FILE"
  [ "$REPLY" = "N" ]
}

@test "_prompt_default_no: legacy BOOTSTRAP_ASSUME_YES=1 still works (fallback)" {
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES CI
  BOOTSTRAP_ASSUME_YES=1
  REPLY=""
  _prompt_default_no "Continue? [y/N]: " >"$OUT_FILE"
  [ "$REPLY" = "N" ]
}

# ------------------------------------------------------------------
# _attach_tty_if_needed
#
# stdin が TTY または非対話モードのときは何もしない。
# stdin が非 TTY かつ /dev/tty が open 不能のときは fail-loud して exit 1 する。
#
# 注意: bats 自体が pipe で実行されるため、関数呼び出しは subshell に
# 隔離する。fail-loud 経路は `bash -c '...' </dev/null` でテストする。
# ------------------------------------------------------------------

@test "_attach_tty_if_needed: returns 0 when stdin is already a TTY" {
  # 関数を subshell で呼び、stdin を /dev/null にしないため
  # bats の stdin (通常は TTY、CI では非 TTY) をそのまま使う。
  # CI 上では下の non-interactive ケースと同等になるが、
  # 少なくとも exit/error にはならないことを検証する。
  CI=true
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
  run _attach_tty_if_needed
  [ "$status" -eq 0 ]
}

@test "_attach_tty_if_needed: returns 0 in non-interactive mode (CI=true)" {
  # 別 bash 経由で stdin を pipe (closed) にし、CI=true を立てて
  # 非対話モードの早期 return を確認する。
  run bash -c '
    set -e
    cd "'"$SCRIPT_ROOT"'"
    # shellcheck disable=SC1091
    . scripts/lib/detect.sh
    # shellcheck disable=SC1091
    . scripts/lib/prompts.sh
    unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
    CI=true _attach_tty_if_needed
    echo "ok"
  ' </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "_attach_tty_if_needed: returns 0 with AGENTYARD_ASSUME_YES=1 (canonical)" {
  run bash -c '
    set -e
    cd "'"$SCRIPT_ROOT"'"
    # shellcheck disable=SC1091
    . scripts/lib/detect.sh
    # shellcheck disable=SC1091
    . scripts/lib/prompts.sh
    unset CI AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
    AGENTYARD_ASSUME_YES=1 _attach_tty_if_needed
    echo "ok"
  ' </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "_attach_tty_if_needed: exits 1 with helpful message when stdin is pipe and /dev/tty unreachable" {
  # bash -c '...' </dev/null は controlling terminal を持たない subshell を作る。
  # この状態で /dev/tty を open すると "No such device or address" になり、
  # fail-loud 経路を踏む。
  #
  # この環境的前提が成り立たないホスト (controlling terminal が引き継がれる bats runner) では
  # skip する。
  if bash -c '{ exec </dev/tty; } 2>/dev/null' </dev/null; then
    skip "controlling terminal is reachable from subshell; cannot reproduce fail-loud scenario"
  fi
  run bash -c '
    cd "'"$SCRIPT_ROOT"'"
    # shellcheck disable=SC1091
    . scripts/lib/detect.sh
    # shellcheck disable=SC1091
    . scripts/lib/prompts.sh
    unset CI AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
    _attach_tty_if_needed
    echo "should not reach"
  ' </dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" != *"should not reach"* ]]
  [[ "$output" == *"対話プロンプト用の TTY を確保できませんでした"* ]]
  [[ "$output" == *"考えられる原因"* ]]
  [[ "$output" == *"対処法"* ]]
  # 3 つの workaround すべてが含まれることを確認
  [[ "$output" == *"ファイル経由"* ]]
  [[ "$output" == *"プロセス置換"* ]]
  [[ "$output" == *"AGENTYARD_ASSUME_YES=1"* ]]
}
