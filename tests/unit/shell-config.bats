#!/usr/bin/env bats
# shellcheck disable=SC2016
# =======================================================================
# tests/unit/shell-config.bats
# -----------------------------------------------------------------------
# scripts/lib/shell_config.sh と scripts/lib/detect.sh の関数を検証する。
# add_to_shell_config の冪等性・パターン検出・エッジケース、および
# _is_non_interactive の環境変数判定を確認する。
#
# HOME を BATS_TEST_TMPDIR に差し替えて実ホームディレクトリを汚染しない。
# =======================================================================

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # 実ホームを汚染しないよう tmpdir を HOME として使用
  export HOME="$BATS_TEST_TMPDIR"

  # Git identity の設定 (canonical pattern)
  git config --global user.email "test@example.com"
  git config --global user.name "Test User"

  # 関連 lib を直接 source する（メイン処理を走らせない）
  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/detect.sh"
  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/shell_config.sh"
}

# ------------------------------------------------------------------
# _is_non_interactive
# ------------------------------------------------------------------

@test "_is_non_interactive: returns true when AGENTYARD_ASSUME_YES=1 (canonical)" {
  AGENTYARD_ASSUME_YES=1
  unset AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  run _is_non_interactive
  [ "$status" -eq 0 ]
}

@test "_is_non_interactive: returns true when CI=true" {
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
  CI=true
  run _is_non_interactive
  [ "$status" -eq 0 ]
}

@test "_is_non_interactive: returns false when neither env is set" {
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  run _is_non_interactive
  [ "$status" -ne 0 ]
}

@test "_is_non_interactive: returns false for other values" {
  # shellcheck disable=SC2034  # 変数は sourced 関数経由で参照される
  AGENTYARD_ASSUME_YES=0
  unset AGENTIC_BOOTSTRAP_ASSUME_YES BOOTSTRAP_ASSUME_YES
  # shellcheck disable=SC2034
  CI=false
  run _is_non_interactive
  [ "$status" -ne 0 ]
}

@test "_is_non_interactive: legacy AGENTIC_BOOTSTRAP_ASSUME_YES=1 still triggers non-interactive (fallback)" {
  unset AGENTYARD_ASSUME_YES BOOTSTRAP_ASSUME_YES CI
  AGENTIC_BOOTSTRAP_ASSUME_YES=1
  run _is_non_interactive
  [ "$status" -eq 0 ]
}

@test "_is_non_interactive: legacy BOOTSTRAP_ASSUME_YES=1 still triggers non-interactive (fallback)" {
  unset AGENTYARD_ASSUME_YES AGENTIC_BOOTSTRAP_ASSUME_YES CI
  BOOTSTRAP_ASSUME_YES=1
  run _is_non_interactive
  [ "$status" -eq 0 ]
}

@test "_is_non_interactive: AGENTYARD_ASSUME_YES takes precedence over legacy names" {
  # canonical 0 / legacy 1 → canonical が優先されて非対話モードにならない
  AGENTYARD_ASSUME_YES=0
  AGENTIC_BOOTSTRAP_ASSUME_YES=1
  BOOTSTRAP_ASSUME_YES=1
  unset CI
  run _is_non_interactive
  [ "$status" -ne 0 ]
}

@test "_is_non_interactive: AGENTIC_BOOTSTRAP_ASSUME_YES takes precedence over BOOTSTRAP_ASSUME_YES" {
  # legacy1 0 / legacy2 1 → legacy1 が優先される (canonical unset 時)
  unset AGENTYARD_ASSUME_YES CI
  AGENTIC_BOOTSTRAP_ASSUME_YES=0
  BOOTSTRAP_ASSUME_YES=1
  run _is_non_interactive
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------------
# add_to_shell_config: 未存在ファイル
# ------------------------------------------------------------------

@test "add_to_shell_config: warns when target file does not exist (.bashrc)" {
  run add_to_shell_config "$HOME/.bashrc" "PATTERN" "CONTENT" "DESC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"見つかりません"* ]]
  [ ! -f "$HOME/.bashrc" ]
}

@test "add_to_shell_config: zsh-specific warning mentions zsh" {
  run add_to_shell_config "$HOME/.zshrc" "PATTERN" "CONTENT" "DESC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zsh を使用していない場合は問題ありません"* ]]
}

# ------------------------------------------------------------------
# add_to_shell_config: 新規パターン追加
# ------------------------------------------------------------------

@test "add_to_shell_config: appends new content when pattern not found" {
  touch "$HOME/.bashrc"
  run add_to_shell_config "$HOME/.bashrc" "EXPORT_FOO" "export FOO=1" "added FOO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added FOO"* ]]
  grep -q "export FOO=1" "$HOME/.bashrc"
}

@test "add_to_shell_config: preserves existing content" {
  echo "# existing line" >"$HOME/.bashrc"
  run add_to_shell_config "$HOME/.bashrc" "EXPORT_FOO" "export FOO=1" "added FOO"
  [ "$status" -eq 0 ]
  grep -q "existing line" "$HOME/.bashrc"
  grep -q "export FOO=1" "$HOME/.bashrc"
}

# ------------------------------------------------------------------
# add_to_shell_config: 冪等性
# ------------------------------------------------------------------

@test "add_to_shell_config: skips when pattern already present" {
  echo "export FOO=1" >"$HOME/.bashrc"
  run add_to_shell_config "$HOME/.bashrc" "FOO=1" "export FOO=1" "added FOO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に設定済み"* ]]
  # 行数が増えていない
  [ "$(wc -l <"$HOME/.bashrc")" -eq 1 ]
}

@test "add_to_shell_config: running twice does not duplicate content" {
  # 契約: pattern は追加される content 内に存在するものを指定する
  touch "$HOME/.bashrc"
  add_to_shell_config "$HOME/.bashrc" "export FOO=1" "export FOO=1" "added FOO" >/dev/null
  add_to_shell_config "$HOME/.bashrc" "export FOO=1" "export FOO=1" "added FOO" >/dev/null
  # パターン出現回数は 1 回のみ
  [ "$(grep -c "export FOO=1" "$HOME/.bashrc")" -eq 1 ]
}

@test "add_to_shell_config: running three times still yields single occurrence" {
  touch "$HOME/.bashrc"
  for _i in 1 2 3; do
    add_to_shell_config "$HOME/.bashrc" "export FOO=1" "export FOO=1" "added FOO" >/dev/null
  done
  [ "$(grep -c "export FOO=1" "$HOME/.bashrc")" -eq 1 ]
}

# ------------------------------------------------------------------
# add_to_shell_config: パターンマッチ
# ------------------------------------------------------------------

@test "add_to_shell_config: pattern substring matches existing content" {
  cat >"$HOME/.bashrc" <<'BASHRC'
# Some shell integration
eval "$(mise activate bash)"
BASHRC
  run add_to_shell_config "$HOME/.bashrc" "mise activate bash" "eval \"\$(mise activate bash)\"" "mise init"
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に設定済み"* ]]
}

@test "add_to_shell_config: different pattern adds alongside existing" {
  cat >"$HOME/.bashrc" <<'BASHRC'
eval "$(mise activate bash)"
BASHRC
  run add_to_shell_config "$HOME/.bashrc" "zoxide init" 'eval "$(zoxide init bash)"' "zoxide init"
  [ "$status" -eq 0 ]
  grep -q "mise activate" "$HOME/.bashrc"
  grep -q "zoxide init" "$HOME/.bashrc"
}

# ------------------------------------------------------------------
# add_to_shell_config: 複数行コンテンツ
# ------------------------------------------------------------------

@test "add_to_shell_config: multi-line content is appended verbatim" {
  touch "$HOME/.bashrc"
  multi='# comment
export FOO=1
export BAR=2'
  add_to_shell_config "$HOME/.bashrc" "FOO=1" "$multi" "multi" >/dev/null
  grep -q "^# comment$" "$HOME/.bashrc"
  grep -q "^export FOO=1$" "$HOME/.bashrc"
  grep -q "^export BAR=2$" "$HOME/.bashrc"
}

# ------------------------------------------------------------------
# ~/.zshrc.d/ 方式の検証
# ------------------------------------------------------------------

@test "add_to_shell_config: ~/.zshrc.d/ sourcing logic is idempotent" {
  touch "$HOME/.zshrc"
  # setup-local-linux.sh 内で使っている実際の呼び出しをシミュレート
  local content='# OzzyLabs 推奨設定の読み込み（~/.zshrc.d/*.zsh）
if [ -d ~/.zshrc.d ]; then
  for file in ~/.zshrc.d/*.zsh; do
    [ -r "$file" ] && source "$file"
  done
  unset file
fi'

  # 1回目
  run add_to_shell_config "$HOME/.zshrc" "zshrc.d" "$content" "zshrc.d"
  [ "$status" -eq 0 ]
  grep -q "zshrc.d" "$HOME/.zshrc"

  # 2回目（冪等性の確認）
  run add_to_shell_config "$HOME/.zshrc" "zshrc.d" "$content" "zshrc.d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に設定済み"* ]]
  # このブロック自体に zshrc.d が3回含まれるため、1回分の注入で 3 ヒットする
  [ "$(grep -c "zshrc.d" "$HOME/.zshrc")" -eq 3 ]
}
