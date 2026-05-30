#!/bin/bash
# shellcheck disable=SC2088  # チルダはログメッセージ内の表示用であり、パス展開は不要
# shellcheck disable=SC2016  # シェル設定に遅延展開させる文字列をそのまま書き込む
set -e

# ========================================
# macOS ローカル環境セットアップスクリプト
# ----------------------------------------
# Phase 1 Wave 1: setup-local-linux.sh と同じく mise を入口にした
# 共通フローで開発環境を整える。Linux 側との重複を最小化するため、
# OS 固有の依存（Homebrew、apt の代替）以外はすべて mise / uv tool に集約する。
#
# 検証範囲（canary.yaml の macOS ジョブで CI 緑を維持）:
#   - mise（公式インストーラ）
#   - mise 経由のランタイム / CLI（node, pnpm, python, uv, gitleaks, ast-grep,
#     yq, just, zoxide, shellcheck）
#   - uv tool（markitdown[all]）
#
# Docker Desktop / AI エージェント CLI の自動セットアップは macOS では
# 未対応（ライセンス・インタラクティブ認証の都合）。READMEの該当章を参照。
# ========================================

# ========================================
# グローバル変数（インストール対象フラグ）
# ========================================
INSTALL_MISE_LANGUAGES="${INSTALL_MISE_LANGUAGES:-1}" # node + pnpm + python + uv
INSTALL_GIT_TOOLS="${INSTALL_GIT_TOOLS:-1}"           # gitleaks（mise 経由）
INSTALL_AI_POWER_TOOLS="${INSTALL_AI_POWER_TOOLS:-1}" # ast-grep, yq, markitdown
INSTALL_DEV_TOOLS="${INSTALL_DEV_TOOLS:-1}"           # just, zoxide, shellcheck, chezmoi
INSTALL_ZELLIJ="${INSTALL_ZELLIJ:-0}"                 # Zellij（opt-in、mise 経由）

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MISE_BIN="$HOME/.local/bin/mise"

# ========================================
# ユーティリティ関数
# ========================================

# 非対話モードかどうかを判定
# AGENTIC_BOOTSTRAP_ASSUME_YES=1（旧名 BOOTSTRAP_ASSUME_YES もフォールバック）
# または CI=true でプロンプトを自動回答する
_is_non_interactive() {
  [ "${AGENTIC_BOOTSTRAP_ASSUME_YES:-${BOOTSTRAP_ASSUME_YES:-0}}" = "1" ] || [ "${CI:-}" = "true" ]
}

# パイプ実行時 (curl ... | bash) でも対話プロンプトが動作するよう、
# stdin が tty でなく /dev/tty が読める場合は /dev/tty にフォールバックする。
if [ ! -t 0 ] && [ -r /dev/tty ] && ! _is_non_interactive; then
  exec </dev/tty
fi

# シェル設定ファイルに行を追加する関数（Linux 側と同一仕様）
add_to_shell_config() {
  local file="$1"
  local pattern="$2"
  local lines="$3"
  local description="$4"

  if [ -f "$file" ]; then
    if grep -q "$pattern" "$file" 2>/dev/null; then
      echo "  ⏭️  $file には既に設定済み"
    else
      echo "" >>"$file"
      echo "$lines" >>"$file"
      echo "  ✅ $description"
    fi
  else
    echo "  ⚠️  $file が見つかりません（必要に応じて手動で追加してください）"
  fi
}

# mise を $HOME ディレクトリで実行するラッパー
# リポジトリ内（CWD に .mise.toml がある場所）で `--global` 操作を行うと
# mise が「ローカル設定がグローバルを上書きする」WARN を毎回出すため、
# サブシェルで $HOME に移動してから呼び出す。
_mise_at_home() {
  (cd "$HOME" && "$MISE_BIN" "$@")
}

# install.sh が同梱する `<repo>/.mise.toml` を mise の信頼設定に登録する。
# 詳細は scripts/lib/mise.sh の同名関数のコメントを参照（Linux/macOS で同一仕様）。
mise_trust_repo_config() {
  local repo_root="$1"
  local config="$repo_root/.mise.toml"

  if [ ! -f "$config" ]; then
    return 0
  fi
  if ! [ -x "$MISE_BIN" ]; then
    return 0
  fi

  if _mise_at_home trust "$config" >/dev/null 2>&1; then
    echo "  ✅ $config を mise の信頼設定に登録しました"
  else
    echo "  ⚠️  $config の trust 登録に失敗しました（手動で 'mise trust $config' を実行してください）"
  fi
  return 0
}

# mise を初期化（未インストールならインストール、既存なら自己更新）
ensure_mise_installed() {
  if [ "${_MISE_INITIALIZED:-0}" = "1" ]; then
    return 0
  fi

  echo ""
  echo "⚡ mise（バージョン管理）を準備中..."

  if ! [ -x "$MISE_BIN" ]; then
    # 注意: curl | sh パターンは mise 公式のインストール方法（HTTPS使用）
    if ! curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
      echo "⚠️  mise のインストールに失敗しました"
      echo "ℹ️  対処法:"
      echo "    1. ネットワーク接続を確認"
      echo "    2. curl のインストール状態を確認: command -v curl"
      echo "ℹ️  手動で確認: curl -fsSL https://mise.run | sh"
      return 1
    fi
    echo "  ✅ mise インストール完了"
  else
    echo "  ℹ️  mise を最新版に更新中..."
    "$MISE_BIN" self-update -y >/dev/null 2>&1 || true
    echo "  ⏭️  mise は最新版です ($("$MISE_BIN" --version 2>/dev/null | head -n1))"
  fi

  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

  # シェル統合（mise activate）
  add_to_shell_config "$HOME/.zshrc" '# mise（バージョン管理）' '# mise（バージョン管理）
eval "$("$HOME/.local/bin/mise" activate zsh)"' "~/.zshrc に mise 初期化を追加しました"
  add_to_shell_config "$HOME/.bash_profile" '# mise（バージョン管理）' '# mise（バージョン管理）
eval "$("$HOME/.local/bin/mise" activate bash)"' "~/.bash_profile に mise 初期化を追加しました"
  add_to_shell_config "$HOME/.bashrc" '# mise（バージョン管理）' '# mise（バージョン管理）
eval "$("$HOME/.local/bin/mise" activate bash)"' "~/.bashrc に mise 初期化を追加しました"

  _MISE_INITIALIZED=1
  return 0
}

# mise でグローバルツールを導入する汎用ヘルパー（ADR-0006: mise use -g 適用）
# $1: tool_spec（例: node@lts, python@latest, gitleaks@8.30.1, github:astral-sh/uv@0.11.9）
# $2: display_name（表示名）
mise_use_global() {
  local tool_spec="$1"
  local display_name="$2"
  local tool_name="${tool_spec%%@*}"

  if ! [ -x "$MISE_BIN" ]; then
    echo "  ⚠️  mise が利用できません（$display_name はスキップ）"
    return 1
  fi

  if _mise_at_home ls --global 2>/dev/null | awk '{print $1}' | grep -qx "$tool_name"; then
    _mise_at_home use --global "$tool_spec" >/dev/null 2>&1 || true
    _mise_at_home install "$tool_spec" >/dev/null 2>&1 || true
    echo "  ⏭️  $display_name は導入済み・最新化しました"
  else
    if _mise_at_home use --global "$tool_spec" >/dev/null; then
      echo "  ✅ $display_name インストール完了"
    else
      echo "  ⚠️  $display_name のインストールに失敗しました"
      echo "ℹ️  手動で確認: mise use --global $tool_spec"
      return 1
    fi
  fi
}

# ========================================
# インストール関数群
# ========================================

# mise + 言語環境（Node.js + pnpm + Python + uv）
install_mise_and_languages() {
  [ "$INSTALL_MISE_LANGUAGES" != "1" ] && return

  ensure_mise_installed || return 1

  # バージョン方針: aqua レジストリ経由のツールは具体パッチ版に明示ピン。
  # uv は aqua の signer_workflow が Immutable Release に追従していないため
  # github バックエンドに切替。詳細は scripts/lib/install-languages.sh のヘッダ参照。
  echo ""
  echo "📦 Node.js / pnpm / Python / uv を mise でインストール中..."
  mise_use_global "node@lts" "Node.js LTS"
  mise_use_global "pnpm@10.33.2" "pnpm"
  mise_use_global "python@latest" "Python"
  mise_use_global "github:astral-sh/uv@0.11.9" "uv"
  echo "✅ mise + 言語環境インストール完了"
}

# Git セキュリティツール（gitleaks）
install_git_security_tools() {
  [ "$INSTALL_GIT_TOOLS" != "1" ] && return

  ensure_mise_installed || return 1

  echo ""
  echo "🔒 Git セキュリティツール（gitleaks）を mise でインストール中..."
  mise_use_global "gitleaks@8.30.1" "gitleaks"
}

# AI パワーツール: ast-grep / yq（mise）+ markitdown（uv tool）
install_ai_power_tools() {
  [ "$INSTALL_AI_POWER_TOOLS" != "1" ] && return

  ensure_mise_installed || return 1

  echo ""
  echo "🧠 AI パワーツールをインストール中..."
  mise_use_global "ast-grep@0.42.1" "ast-grep"
  mise_use_global "yq@4.53.2" "yq"

  if command -v uv &>/dev/null; then
    if ! uv tool list 2>/dev/null | grep -q "^markitdown"; then
      uv tool install "markitdown[all]" >/dev/null
      echo "  ✅ markitdown[all] インストール完了"
    else
      uv tool upgrade markitdown >/dev/null 2>&1 || true
      echo "  ⏭️  markitdown は導入済み・最新化しました"
    fi
  else
    echo "  ⚠️  uv が見つからないため markitdown はスキップしました"
  fi
}

# Terminal multiplexer（opt-in、mise 経由）
# zellij は aqua バックエンドで導入。tmux は macOS では自動化対象外（README §6.3.2 参照）。
install_multiplexer_tools() {
  [ "${INSTALL_ZELLIJ:-0}" != "1" ] && return

  ensure_mise_installed || return 1

  echo ""
  echo "🪟 Terminal multiplexer をインストール中..."
  mise_use_global "zellij@0.44.3" "Zellij"
}

# 開発補助ツール: just / zoxide / shellcheck / chezmoi（mise）
install_dev_tools() {
  [ "$INSTALL_DEV_TOOLS" != "1" ] && return

  ensure_mise_installed || return 1

  echo ""
  echo "🛠️ 開発補助ツールをインストール中..."
  mise_use_global "just@1.50.0" "just"
  mise_use_global "zoxide@0.9.9" "zoxide"
  mise_use_global "shellcheck@0.11.0" "shellcheck"
  mise_use_global "chezmoi@2.70.2" "chezmoi"

  add_to_shell_config "$HOME/.zshrc" "zoxide init zsh" 'eval "$(zoxide init zsh)"' "~/.zshrc に zoxide 初期化を追加しました"
  add_to_shell_config "$HOME/.bash_profile" "zoxide init bash" 'eval "$(zoxide init bash)"' "~/.bash_profile に zoxide 初期化を追加しました"
  add_to_shell_config "$HOME/.bashrc" "zoxide init bash" 'eval "$(zoxide init bash)"' "~/.bashrc に zoxide 初期化を追加しました"

  # ~/.zshrc.d/ 方式のセットアップ
  echo "📁 ~/.zshrc.d/ を準備中..."
  mkdir -p ~/.zshrc.d
  add_to_shell_config "$HOME/.zshrc" "zshrc.d" '# OzzyLabs 推奨設定の読み込み（~/.zshrc.d/*.zsh）
if [ -d ~/.zshrc.d ]; then
  for file in ~/.zshrc.d/*.zsh; do
    [ -r "$file" ] && source "$file"
  done
  unset file
fi' "~/.zshrc に ~/.zshrc.d/ の読み込み設定を追加しました"

  # chezmoi による設定適用（ADR-0003）
  local repo_root
  repo_root="$(dirname "$SCRIPT_DIR")"
  if [ -d "$repo_root/dotfiles" ]; then
    echo ""
    echo "🏠 chezmoi で推奨設定を適用中..."
    if _is_non_interactive; then
      _mise_at_home exec chezmoi -- chezmoi apply --force --source "$repo_root/dotfiles"
    else
      _mise_at_home exec chezmoi -- chezmoi apply --interactive --source "$repo_root/dotfiles"
    fi
    echo "  ✅ chezmoi による設定適用完了"
  fi
}

# ========================================
# メイン処理開始
# ========================================

# ログ出力機能（SETUP_LOG 環境変数が設定されている場合）
if [ -n "${SETUP_LOG:-}" ]; then
  if [ "$SETUP_LOG" = "1" ] || [ "$SETUP_LOG" = "true" ]; then
    LOG_FILE="$HOME/setup-local-macos-$(date +%Y%m%d-%H%M%S).log"
  else
    LOG_FILE="$SETUP_LOG"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "ℹ️  ログを $LOG_FILE に記録します"
fi

echo "🚀 macOS ローカル環境セットアップ開始（mise を入口にした共通フロー）"
echo ""

# 1. 環境チェック
if [ "$(uname -s)" != "Darwin" ]; then
  echo "⚠️  このスクリプトは macOS 専用です（現在の OS: $(uname -s)）"
  echo "ℹ️  Linux 環境では scripts/setup-local-linux.sh を使用してください"
  exit 1
fi

echo "✅ 実行環境チェック完了 ($(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null))"
echo ""

# 2. 依存ツールの確認: curl は macOS に標準同梱
if ! command -v curl >/dev/null 2>&1; then
  echo "⚠️  curl が見つかりません（macOS 標準同梱のはずです）"
  exit 1
fi

# 3. インストール処理
install_mise_and_languages
# install.sh が同梱する .mise.toml を信頼。これをやらないと末尾サマリで
# `node --version` 等の mise shim 呼び出しが "not trusted" で失敗する。
mise_trust_repo_config "$(dirname "$SCRIPT_DIR")"
install_git_security_tools
install_ai_power_tools
install_multiplexer_tools
install_dev_tools

# ========================================
# セットアップ完了サマリー
# ========================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 セットアップ結果"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚡ バージョン管理:"
echo "  mise:           $("$MISE_BIN" --version 2>/dev/null | head -n1 || echo '未インストール')"
echo ""
echo "📦 言語ランタイム:"
echo "  Node.js:        $(_mise_at_home exec node@lts -- node --version 2>/dev/null || echo '未インストール')"
echo "  pnpm:           $(_mise_at_home exec pnpm -- pnpm --version 2>/dev/null || echo '未インストール')"
echo "  Python:         $(_mise_at_home exec python -- python3 --version 2>/dev/null || echo '未インストール')"
echo "  uv:             $(_mise_at_home exec uv -- uv --version 2>/dev/null | head -n1 || echo '未インストール')"
echo ""
echo "🔒 Git セキュリティ:"
echo "  gitleaks:       $(_mise_at_home exec gitleaks -- gitleaks version 2>/dev/null || echo '未インストール')"
echo ""
echo "🧠 AI パワーツール:"
echo "  ast-grep:       $(_mise_at_home exec ast-grep -- ast-grep --version 2>/dev/null || echo '未インストール')"
echo "  yq:             $(_mise_at_home exec yq -- yq --version 2>/dev/null || echo '未インストール')"
echo "  markitdown:     $(command -v markitdown >/dev/null && markitdown --version 2>/dev/null || echo '未インストール')"
echo ""
echo "🛠️ 開発補助ツール:"
echo "  just:           $(_mise_at_home exec just -- just --version 2>/dev/null || echo '未インストール')"
echo "  zoxide:         $(_mise_at_home exec zoxide -- zoxide --version 2>/dev/null || echo '未インストール')"
echo "  shellcheck:     $(_mise_at_home exec shellcheck -- shellcheck --version 2>/dev/null | awk '/^version:/{print $2}' || echo '未インストール')"
echo "  chezmoi:        $(_mise_at_home exec chezmoi -- chezmoi --version 2>/dev/null || echo '未インストール')"
echo ""
echo "🪟 Terminal multiplexer:"
echo "  Zellij:         $(_mise_at_home exec zellij -- zellij --version 2>/dev/null || echo '未インストール (opt-in)')"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 macOS セットアップ完了！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ:"
echo "  1. シェルを再起動して mise activate を反映:"
echo "     exec \$SHELL -l"
echo ""
echo "  2. macOS では以下は手動セットアップが推奨です（自動化対象外）:"
echo "     - Docker Desktop（公式インストーラ: https://www.docker.com/products/docker-desktop）"
echo "     - AI エージェント CLI（Claude Code / Codex CLI / GitHub Copilot CLI / Gemini CLI）"
echo "     - クラウド CLI（aws / az / gcloud は brew install で導入可）"
echo ""
if [ -n "${LOG_FILE:-}" ]; then
  echo "ℹ️  セットアップログ: $LOG_FILE"
  echo ""
fi
