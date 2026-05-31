#!/usr/bin/env bats
# shellcheck disable=SC2016
# =======================================================================
# tests/unit/install-config.bats
# -----------------------------------------------------------------------
# install.sh の DEFAULT_REF 解決ロジックを検証する。
#
# Precedence chain (install.sh:6):
#   AGENTYARD_REF (canonical)
#     > AGENTIC_BOOTSTRAP_REF (legacy 1)
#     > BOOTSTRAP_REF (legacy 2)
#     > "main" (fallback default)
#
# 各ケースは bash -c で subshell を起動し、install.sh を source する。
# 親プロセスで readonly が collide しないよう subshell 内で完結させる。
# install.sh は末尾の BASH_SOURCE ガードにより source 時は main() を実行しない。
# =======================================================================

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

_resolve_default_ref() {
  # 親環境の REF 系を意図せず継承しないよう env -i で隔離。
  # PATH と HOME は bash 起動に必要なため明示的に引き渡す。
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    "$@" \
    bash -c "source '$SCRIPT_ROOT/install.sh' && printf '%s' \"\$DEFAULT_REF\""
}

@test "DEFAULT_REF: fallback to 'main' when no env var is set" {
  result="$(_resolve_default_ref)"
  [ "$result" = "main" ]
}

@test "DEFAULT_REF: BOOTSTRAP_REF (legacy 2) is honored when only it is set" {
  result="$(_resolve_default_ref BOOTSTRAP_REF=legacy2-ref)"
  [ "$result" = "legacy2-ref" ]
}

@test "DEFAULT_REF: AGENTIC_BOOTSTRAP_REF (legacy 1) takes precedence over BOOTSTRAP_REF" {
  result="$(_resolve_default_ref AGENTIC_BOOTSTRAP_REF=legacy1-ref BOOTSTRAP_REF=legacy2-ref)"
  [ "$result" = "legacy1-ref" ]
}

@test "DEFAULT_REF: AGENTYARD_REF (canonical) takes precedence over both legacy names" {
  result="$(_resolve_default_ref AGENTYARD_REF=canonical-ref AGENTIC_BOOTSTRAP_REF=legacy1-ref BOOTSTRAP_REF=legacy2-ref)"
  [ "$result" = "canonical-ref" ]
}

@test "DEFAULT_REF: AGENTYARD_REF wins even when legacy 1 is set" {
  result="$(_resolve_default_ref AGENTYARD_REF=canonical-ref AGENTIC_BOOTSTRAP_REF=legacy1-ref)"
  [ "$result" = "canonical-ref" ]
}

@test "DEFAULT_REF: AGENTYARD_REF wins even when only legacy 2 is set alongside" {
  result="$(_resolve_default_ref AGENTYARD_REF=canonical-ref BOOTSTRAP_REF=legacy2-ref)"
  [ "$result" = "canonical-ref" ]
}

@test "DEFAULT_REF: empty AGENTYARD_REF falls through to AGENTIC_BOOTSTRAP_REF" {
  # ${VAR:-...} は VAR が unset OR empty のとき fallback する仕様
  result="$(_resolve_default_ref AGENTYARD_REF= AGENTIC_BOOTSTRAP_REF=legacy1-ref)"
  [ "$result" = "legacy1-ref" ]
}

@test "DEFAULT_REF: all empty falls through to 'main'" {
  result="$(_resolve_default_ref AGENTYARD_REF= AGENTIC_BOOTSTRAP_REF= BOOTSTRAP_REF=)"
  [ "$result" = "main" ]
}
