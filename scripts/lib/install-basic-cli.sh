#!/bin/bash
# scripts/lib/install-basic-cli.sh
# 基本 CLI ツール（tree, fzf, jq, ripgrep, fd, unzip）のインストール。
# 前提: lib/apt.sh, lib/shell_config.sh が事前に source されていること。

# 2. 基本CLIツールのインストール
install_basic_cli_tools() {
  [ "$INSTALL_BASIC_CLI" != "1" ] && return

  echo ""
  echo "🔧 基本CLIツールをインストール中..."

  # tree
  apt_install_or_upgrade "tree" "tree" "tree"

  # fzf （初回インストール時のみシェル設定を追加）
  if ! command -v fzf &>/dev/null; then
    sudo apt-get install -y fzf
    echo "  ✅ fzf インストール完了"

    add_to_shell_config ~/.zshrc "source /usr/share/doc/fzf/examples/key-bindings.zsh" "# fzf キーバインド（Ctrl+R で履歴検索）
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh" "fzf キーバインドを ~/.zshrc に追加しました"

    add_to_shell_config ~/.bashrc "source /usr/share/doc/fzf/examples/key-bindings.bash" "# fzf キーバインド（Ctrl+R で履歴検索）
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash" "fzf キーバインドを ~/.bashrc に追加しました"
  else
    sudo apt-get install -y --only-upgrade fzf >/dev/null 2>&1
    echo "  ⏭️  fzf は最新版です"
  fi

  # jq
  apt_install_or_upgrade "jq" "jq" "jq"

  # ripgrep （コマンド名 rg）
  apt_install_or_upgrade "ripgrep" "ripgrep" "rg"

  # fd （Ubuntu では fd-find という名前。fd シンボリックリンクを ~/.local/bin に作成）
  if ! command -v fd &>/dev/null; then
    sudo apt-get install -y fd-find
    echo "  ✅ fd インストール完了"
    if [ ! -f "$HOME/.local/bin/fd" ]; then
      mkdir -p "$HOME/.local/bin"
      ln -s "$(which fdfind)" "$HOME/.local/bin/fd" 2>/dev/null || true
      echo "  ✅ fd コマンドのシンボリックリンクを作成しました"
    fi
  else
    sudo apt-get install -y --only-upgrade fd-find >/dev/null 2>&1
    echo "  ⏭️  fd は最新版です"
  fi

  # unzip （AWS CLI 等に必要）
  apt_install_or_upgrade "unzip" "unzip" "unzip"

  # NOTE: wslu / wslview は WSL2 専用ユーティリティのため、agentyard の
  # 共通フローからは除外している。WSL2 上で `wslview` が必要な場合は
  # 各 WSL ディストリで手動インストールする想定:
  #   sudo apt-get install -y wslu  # Ubuntu 22.04 / 24.04 では標準リポジトリに含まれる
  #   PPA: ppa:wslutilities/wslu

  echo "✅ 基本CLIツールインストール完了"
}
