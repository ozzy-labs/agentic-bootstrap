#!/bin/bash
# scripts/lib/install-multiplexer.sh
# Terminal multiplexer (zellij / tmux) のインストール。
#
# multiplexer は好みが大きく分かれるため、すべて opt-in（デフォルト OFF）で
# `INSTALL_*` 環境変数または対話セレクタで明示有効化された場合のみ導入する。
# zellij は aqua レジストリ経由で mise pinned、tmux は apt パッケージ（Linux のみ自動化）。
# macOS で `INSTALL_TMUX=1` を渡しても自動インストールはせず、手動案内のみ表示する
# （macOS は mise-first 方針で、setup-local-macos.sh は brew install を一切使わない）。

# Terminal multiplexer ツールのインストール（opt-in）
install_multiplexer_tools() {
  local any_installed=0

  # zellij（mise 経由、aqua バックエンド）
  if [ "${INSTALL_ZELLIJ:-0}" = "1" ]; then
    [ "$any_installed" = "0" ] && {
      echo ""
      echo "🪟 Terminal multiplexer をインストール中..."
      any_installed=1
    }

    ensure_mise_installed || return 1
    mise_use_global "zellij@0.44.3" "Zellij"
  fi

  # tmux（apt、Linux のみ自動化）
  # design decision #5: ~/.tmux.conf は chezmoi 経由ではなく install_multiplexer_tools 内で
  # 直書きする（chezmoi にすると非 opt-in ユーザーにも飛ぶため）。既存ファイルは尊重する。
  if [ "${INSTALL_TMUX:-0}" = "1" ]; then
    [ "$any_installed" = "0" ] && {
      echo ""
      echo "🪟 Terminal multiplexer をインストール中..."
      any_installed=1
    }

    apt_install_or_upgrade "tmux" "tmux" "tmux"

    # ~/.tmux.conf を新規ホストでは書き出し、既存ホストでは尊重する
    if command -v tmux &>/dev/null; then
      if [ -f "$HOME/.tmux.conf" ]; then
        echo "  ⏭️  ~/.tmux.conf は既に存在（上書きしません）"
      else
        cat >"$HOME/.tmux.conf" <<'TMUXCONF'
# truecolor + 256color
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"

# UX 基本
set -g mouse on
set -g history-limit 50000

# window/pane index を 1 始まりに（左手キーで届きやすい）
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# config 即時リロード
bind r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"
TMUXCONF
        echo "  ✅ ~/.tmux.conf を作成しました"
      fi
    fi
  fi

  # NOTE: 末尾を `[ X = "1" ] && echo` にすると any_installed=0 のとき
  # 関数が exit 1 を返し、set -e でスクリプト全体が落ちる。明示的に if/then を使う。
  if [ "$any_installed" = "1" ]; then
    echo "✅ Terminal multiplexer インストール完了"
  fi
}
