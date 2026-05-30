#!/bin/bash
# scripts/lib/install-multiplexer.sh
# Terminal multiplexer (zellij / tmux) のインストール。
#
# multiplexer は好みが大きく分かれるため、すべて opt-in（デフォルト OFF）で
# `INSTALL_*` 環境変数または対話セレクタで明示有効化された場合のみ導入する。
# zellij は aqua レジストリ経由で mise pinned、tmux は PR2 で追加予定。

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

  # NOTE: tmux は PR2 で追加予定（Linux 限定 apt インストール + ~/.tmux.conf 直書き）

  # NOTE: 末尾を `[ X = "1" ] && echo` にすると any_installed=0 のとき
  # 関数が exit 1 を返し、set -e でスクリプト全体が落ちる。明示的に if/then を使う。
  if [ "$any_installed" = "1" ]; then
    echo "✅ Terminal multiplexer インストール完了"
  fi
}
