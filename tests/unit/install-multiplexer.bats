#!/usr/bin/env bats
# =======================================================================
# tests/unit/install-multiplexer.bats
# -----------------------------------------------------------------------
# scripts/lib/install-multiplexer.sh の install_multiplexer_tools 関数を
# 検証する。apt_install_or_upgrade / mise_use_global / ensure_mise_installed
# をすべてモックして、外部依存（apt, mise, network）を一切呼ばない。
#
# 検証範囲（audit gap δ-1 part 2）:
#   - INSTALL_TMUX=1 → apt 経路が呼ばれ、~/.tmux.conf が新規作成される
#   - INSTALL_TMUX=1 + 既存 ~/.tmux.conf → スキップログ / 上書きしない
#   - INSTALL_TMUX=0 / INSTALL_ZELLIJ=0 → no-op（何も呼ばない）
#   - INSTALL_ZELLIJ=1 → mise_use_global("zellij@...") が呼ばれる
#
# NOTE: macOS 経路（INSTALL_TMUX=1 でも apt を呼ばず notice のみ）は
# scripts/lib/install-multiplexer.sh ではなく scripts/setup-local-macos.sh
# 内の同名関数で実装されている（lib 化されていない）。
# canary-macos workflow が weekly に macOS ランナーで実行カバーするため、
# bats 化は当面 deferred。lib 化された折に本ファイルへテスト追加すること。
# =======================================================================

# `run !` 形式（bats >= 1.5.0）を使う。SC2314 回避のため。
bats_require_minimum_version 1.5.0

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # HOME を tempdir に差し替え（~/.tmux.conf の検査用）
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  # モック呼び出しログ
  export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
  : >"$MOCK_LOG"

  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/install-multiplexer.sh"

  # install_multiplexer_tools が呼ぶ外部関数を全てモック。
  # source の後に定義しないと lib 内同名関数で上書きされるリスクは無いが
  # （これらは lib 内では未定義の外部依存）、明示性のため後段で定義する。
  apt_install_or_upgrade() {
    echo "apt_install_or_upgrade $*" >>"$MOCK_LOG"
    return 0
  }
  export -f apt_install_or_upgrade

  ensure_mise_installed() {
    echo "ensure_mise_installed" >>"$MOCK_LOG"
    return 0
  }
  export -f ensure_mise_installed

  mise_use_global() {
    echo "mise_use_global $*" >>"$MOCK_LOG"
    return 0
  }
  export -f mise_use_global

  # tmux コマンドの存在検知をモック（command -v tmux が true を返すように）
  # ~/.tmux.conf 書き出しブロックは `command -v tmux &>/dev/null` ガード下にある。
  # PATH に偽 tmux を置く方が builtin command の override より堅牢。
  mkdir -p "$BATS_TEST_TMPDIR/fake-bin"
  cat >"$BATS_TEST_TMPDIR/fake-bin/tmux" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/fake-bin/tmux"
  export PATH="$BATS_TEST_TMPDIR/fake-bin:$PATH"
}

# ------------------------------------------------------------------
# INSTALL_TMUX / INSTALL_ZELLIJ 未指定 → no-op
# ------------------------------------------------------------------

@test "install_multiplexer_tools: no-op when both flags are unset" {
  unset INSTALL_TMUX
  unset INSTALL_ZELLIJ

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
  [ ! -f "$HOME/.tmux.conf" ]
}

# ------------------------------------------------------------------
# INSTALL_TMUX=0 / INSTALL_ZELLIJ=0 → no-op
# ------------------------------------------------------------------

@test "install_multiplexer_tools: no-op when both flags are 0" {
  export INSTALL_TMUX=0
  export INSTALL_ZELLIJ=0

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
  [ ! -f "$HOME/.tmux.conf" ]
}

# ------------------------------------------------------------------
# INSTALL_TMUX=1 → apt_install_or_upgrade("tmux", ...) を呼ぶ
# ------------------------------------------------------------------

@test "install_multiplexer_tools: INSTALL_TMUX=1 invokes apt_install_or_upgrade" {
  export INSTALL_TMUX=1
  unset INSTALL_ZELLIJ

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  grep -q "apt_install_or_upgrade tmux tmux tmux" "$MOCK_LOG"
}

# ------------------------------------------------------------------
# INSTALL_TMUX=1 + ~/.tmux.conf 不在 → 新規作成、同梱内容書き込み
# ------------------------------------------------------------------

@test "install_multiplexer_tools: INSTALL_TMUX=1 creates ~/.tmux.conf when absent" {
  export INSTALL_TMUX=1
  unset INSTALL_ZELLIJ

  [ ! -f "$HOME/.tmux.conf" ]

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  [ -f "$HOME/.tmux.conf" ]
  grep -q 'tmux-256color' "$HOME/.tmux.conf"
  [[ "$output" == *"~/.tmux.conf を作成しました"* ]]
}

# ------------------------------------------------------------------
# INSTALL_TMUX=1 + ~/.tmux.conf 既存 → 上書きしない、スキップログ
# （audit gap δ-1: PR #150 の手動テスト項目 #2 を自動化）
# ------------------------------------------------------------------

@test "install_multiplexer_tools: INSTALL_TMUX=1 respects pre-existing ~/.tmux.conf" {
  export INSTALL_TMUX=1
  unset INSTALL_ZELLIJ

  local sentinel="# SENTINEL: pre-existing user config"
  cat >"$HOME/.tmux.conf" <<EOF
$sentinel
set -g status-bg colour234
EOF

  run install_multiplexer_tools
  [ "$status" -eq 0 ]

  # 既存ファイルが保持されている（sentinel が残っている）
  grep -qF "$sentinel" "$HOME/.tmux.conf"
  # スキップログが出ている
  [[ "$output" == *"上書きしません"* ]]
  # 同梱内容（tmux-256color）が混入していないこと。
  # NOTE: bats の `! cmd` は POSIX 例外で set -e から除外され、mid-test の
  # `! grep` は silently swallow される（SC2314）。`run !` 形式（bats >= 1.5.0）
  # で「cmd が non-zero 終了することを assert」する。grep -q が見つけてしまうと
  # bats が即 fail を報告する（追加の assert 不要）。
  run ! grep -q 'tmux-256color' "$HOME/.tmux.conf"
}

# ------------------------------------------------------------------
# INSTALL_ZELLIJ=1 → ensure_mise_installed + mise_use_global を呼ぶ
# ------------------------------------------------------------------

@test "install_multiplexer_tools: INSTALL_ZELLIJ=1 invokes mise_use_global" {
  unset INSTALL_TMUX
  export INSTALL_ZELLIJ=1

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  grep -q "ensure_mise_installed" "$MOCK_LOG"
  grep -q "mise_use_global zellij@" "$MOCK_LOG"
  [ ! -f "$HOME/.tmux.conf" ]
  # tmux 経路は呼ばれない（SC2314 回避: `run !` で「cmd が fail することを assert」）。
  # grep -q が apt_install_or_upgrade を見つけてしまうと bats が即 fail を報告する。
  run ! grep -q "apt_install_or_upgrade" "$MOCK_LOG"
}

# ------------------------------------------------------------------
# INSTALL_TMUX=1 + INSTALL_ZELLIJ=1 → 両経路が呼ばれる
# ------------------------------------------------------------------

@test "install_multiplexer_tools: both flags trigger both code paths" {
  export INSTALL_TMUX=1
  export INSTALL_ZELLIJ=1

  run install_multiplexer_tools
  [ "$status" -eq 0 ]
  grep -q "mise_use_global zellij@" "$MOCK_LOG"
  grep -q "apt_install_or_upgrade tmux tmux tmux" "$MOCK_LOG"
  [ -f "$HOME/.tmux.conf" ]
}
