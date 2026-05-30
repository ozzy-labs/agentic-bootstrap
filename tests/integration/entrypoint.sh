#!/bin/bash
# =======================================================================
# tests/integration/entrypoint.sh
# -----------------------------------------------------------------------
# コンテナ内で install.sh local を 2 回実行し、主要ツールの導入と
# 冪等性を検証する。
# =======================================================================
set -eo pipefail

RUN1_LOG="/tmp/run1.log"
RUN2_LOG="/tmp/run2.log"
RUN3_LOG="/tmp/run3.log"
ASSERT_SCRIPT="/workspace/tests/integration/assert-tools.sh"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '🔵 1st run — setup from scratch\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if ! /workspace/install.sh local 2>&1 | tee "$RUN1_LOG"; then
  echo "❌ 1st run failed"
  exit 1
fi

# 致命的エラーキーワードの検出。
# install.sh は version display 等で `2>/dev/null` を多用しており、
# 終了コードだけでは silent failure を捕まえられない。
# 実例:
#   - mise の untrusted config エラー（`.mise.toml` を信頼登録していない場合に
#     shim 呼び出しが拒否される。https://github.com/ozzy-labs/agentic-bootstrap/issues 参照）
#   - apt の Signed-By 競合（旧 add-apt-repository 由来 `.sources` と新 `.list` の併存）
# install.sh が表向き完走しても、これらキーワードがログに出ていれば実環境では
# ユーザーに見えるエラーが発生しているので、ここで明示的に弾く。
assert_no_fatal_errors() {
  local log="$1"
  local label="$2"
  local pattern='mise ERROR|^E: |Conflicting values set for option|unbound variable|: command not found'
  if grep -E "$pattern" "$log"; then
    echo "❌ $label: fatal-keyword stderr が検出されました（上記参照）"
    exit 1
  fi
}
assert_no_fatal_errors "$RUN1_LOG" "1st run"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '🔍 Asserting tool installations\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

# 新しく設定された PATH / シェル統合を反映してから assert を実行
# shellcheck disable=SC1091
source "$HOME/.bashrc" || true
if ! bash "$ASSERT_SCRIPT"; then
  echo "❌ Tool assertions failed after 1st run"
  exit 1
fi

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '🔵 2nd run — idempotency check\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
if ! /workspace/install.sh local 2>&1 | tee "$RUN2_LOG"; then
  echo "❌ 2nd run failed"
  exit 1
fi
assert_no_fatal_errors "$RUN2_LOG" "2nd run"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '📊 Idempotency verdict\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

# 冪等性の判定基準:
#   1. 2 回目実行が正常終了している（ここまで到達した時点で set -e により保証）
#   2. ~/.bashrc 内のシェル設定行が重複していない（add_to_shell_config の冪等性）
#   3. 2 回目は「すでに導入済み」マーカー (⏭️) が少なくとも 1 件以上出ている
#      （完全に再インストールしているわけではないことを示す）
RUN2_INSTALL_COUNT=$(grep -c 'インストール完了' "$RUN2_LOG" || true)
RUN2_SKIP_COUNT=$(grep -c '⏭️' "$RUN2_LOG" || true)

printf '2nd run "インストール完了" markers: %s\n' "$RUN2_INSTALL_COUNT"
printf '2nd run "⏭️" markers:              %s\n' "$RUN2_SKIP_COUNT"

if [ "$RUN2_SKIP_COUNT" -lt 5 ]; then
  echo "❌ Expected many '⏭️' markers on 2nd run but saw only $RUN2_SKIP_COUNT"
  echo "   (scripts should mostly skip already-installed tools)"
  exit 1
fi

# シェル設定の重複チェック（唯一のアンカー行だけを見る）
# PNPM_HOME ブロックは `export PNPM_HOME=` と `export PATH="$PNPM_HOME:..."` の 2 行を
# 含むため、単純な "PNPM_HOME" カウントでは 2 回マッチしてしまう。
# add_to_shell_config は冒頭コメント行（"# ..."）を一意なアンカーとして挿入するため、
# そのコメント行の出現回数をチェックするのが最も堅牢。
for anchor in \
  "# mise（バージョン管理）" \
  "# pnpm グローバルパッケージ" \
  "# ローカルユーザー向けバイナリ" \
  'eval "$(zoxide init bash)"'; do
  count=$(grep -cF "$anchor" "$HOME/.bashrc" || true)
  if [ "$count" -gt 1 ]; then
    echo "❌ Shell config duplication: '$anchor' appears $count times in ~/.bashrc"
    exit 1
  fi
done

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '🔵 Pipe-mode regression (curl|bash style)\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

# README §4 で案内している `curl ... | bash -s -- ...` 実行形態の回帰テスト。
# 過去に以下 2 件のバグがどのテスト層でも検出されなかったため、
# pipe 経由の実行を明示的に踏ませて回帰を防ぐ:
#   1. install.sh の EXIT trap が `local tmp_dir` を遅延展開し、
#      set -u 下で unbound variable で死ぬ
#   2. setup-zsh-linux.sh の `read -p` が pipe 越し EOF + set -e で
#      入力プロンプト到達と同時に終了する

# --- 1. install.sh の EXIT trap が pipe 経由でも安全に発火することを確認 ---
# 存在しない ref を指定して download を確実に失敗させ、EXIT trap が
# unbound variable で死んでいないことだけを検証する（set -u 違反の検出）。
PIPE_INSTALL_LOG="/tmp/pipe-install.log"
cat /workspace/install.sh |
  AGENTIC_BOOTSTRAP_REF="non-existent-ref-for-trap-regression-$$" bash -s -- local \
    >"$PIPE_INSTALL_LOG" 2>&1 || true
if grep -qE "unbound variable" "$PIPE_INSTALL_LOG"; then
  echo "❌ install.sh emitted 'unbound variable' under pipe execution:"
  grep -E "unbound variable" "$PIPE_INSTALL_LOG" || true
  exit 1
fi
echo "✅ install.sh EXIT trap is safe under pipe execution"

# --- 2. setup-zsh-linux.sh が pipe 経由でも完走することを確認 ---
# CI=true により非対話モードで実行され、対話プロンプトはすべて既定値で
# 自動回答される。read -p が EOF で失敗していれば set -e で即死する。
PIPE_ZSH_LOG="/tmp/pipe-zsh.log"
if ! cat /workspace/scripts/setup-zsh-linux.sh | bash >"$PIPE_ZSH_LOG" 2>&1; then
  echo "❌ setup-zsh-linux.sh failed under pipe execution. Log:"
  cat "$PIPE_ZSH_LOG"
  exit 1
fi
if grep -qE "unbound variable" "$PIPE_ZSH_LOG"; then
  echo "❌ setup-zsh-linux.sh emitted 'unbound variable' under pipe execution"
  exit 1
fi
echo "✅ setup-zsh-linux.sh completes under pipe execution"

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '🔵 3rd run — opt-in multiplexer (INSTALL_TMUX=1 INSTALL_ZELLIJ=1)\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

# multiplexer は opt-in なので、既定の 1st / 2nd run では入らない。
# 3rd run で INSTALL_TMUX=1 / INSTALL_ZELLIJ=1 を明示して両方がインストールされ、
# assert-tools.sh が opt-in アサーションを満たすことを確認する。
# tmux 側は ~/.tmux.conf の新規作成（既存ファイル無し時）も検証する。
if ! INSTALL_TMUX=1 INSTALL_ZELLIJ=1 /workspace/install.sh local 2>&1 | tee "$RUN3_LOG"; then
  echo "❌ 3rd run (INSTALL_TMUX=1 INSTALL_ZELLIJ=1) failed"
  exit 1
fi
assert_no_fatal_errors "$RUN3_LOG" "3rd run"

# shellcheck disable=SC1091
source "$HOME/.bashrc" || true
if ! INSTALL_TMUX=1 INSTALL_ZELLIJ=1 bash "$ASSERT_SCRIPT"; then
  echo "❌ Tool assertions failed after 3rd run (INSTALL_TMUX=1 INSTALL_ZELLIJ=1)"
  exit 1
fi

# ~/.tmux.conf が新規ホストで作成されることを確認
# 同梱の最小構成（default-terminal "tmux-256color"）が書かれているはず。
if [ ! -f "$HOME/.tmux.conf" ]; then
  echo "❌ ~/.tmux.conf が作成されていません（INSTALL_TMUX=1 で新規作成されるはず）"
  exit 1
fi
if ! grep -q 'tmux-256color' "$HOME/.tmux.conf"; then
  echo "❌ ~/.tmux.conf に同梱の最小構成が書かれていません"
  cat "$HOME/.tmux.conf"
  exit 1
fi
echo "✅ ~/.tmux.conf created with bundled defaults"

# NOTE: setup-local-linux.sh の直接 pipe 実行テストは、scripts/lib/*.sh への
# 責務分割（#88）以降は実装と整合しないため削除した。実環境では
# install.sh が tarball を展開して setup-local-linux.sh を**ファイルとして**
# 実行する経路のみが使われる（pipe 経由で setup-local-linux.sh を直接呼ぶ
# 公開された経路は存在しない）。
#
# 元々この pipe テストが守っていた「pipe 経由 EOF + set -e + read -p の
# 相互作用」の不変条件は、scripts/lib/prompts.sh の bats unit test
# (tests/unit/prompts.bats) と setup-zsh-linux.sh の pipe テスト（上記）
# で引き続き検証している。

printf '\n✅ Integration test passed (both runs completed, no shell config duplication, pipe-mode OK)\n'
