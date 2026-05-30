#!/bin/bash
# shellcheck disable=SC2088  # チルダはログメッセージ内の表示用であり、パス展開は不要
# shellcheck disable=SC2016  # シェル設定に遅延展開させる文字列をそのまま書き込む
# scripts/lib/mise.sh
# mise のインストール・初期化・グローバルツール管理ヘルパー。
# このファイルは source して利用する。
# 前提: lib/detect.sh, lib/shell_config.sh が事前に source されていること
# （`ensure_mise_installed` が `_is_darwin` と `add_to_shell_config` を利用する）。

# mise バイナリのパス
MISE_BIN="${MISE_BIN:-$HOME/.local/bin/mise}"

# mise を初期化（未インストールならインストール、既存なら自己更新）
# 複数の install 関数から共通利用される冪等なエントリーポイント
ensure_mise_installed() {
  # 既に初期化済みの場合は再実行しない（同一セッション内のガード）
  if [ "${_MISE_INITIALIZED:-0}" = "1" ]; then
    return 0
  fi

  echo ""
  echo "⚡ mise（バージョン管理）を準備中..."

  if ! [ -x "$MISE_BIN" ]; then
    # 注意: curl | sh パターンは mise 公式のインストール方法（HTTPS使用）
    if ! curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
      echo "⚠️  mise のインストールに失敗しました"
      echo "ℹ️  考えられる原因:"
      echo "    - ネットワーク接続の問題"
      echo "    - curl が利用できない"
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

  # 以降のコマンドで mise とそのシム（node, npm, python, gitleaks 等）を使えるようにする
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

  # シェル統合（mise activate）を設定
  # 注意: パターンは書き込まれた文字列内に実在する部分列を使う必要がある。
  # eval 行には `" activate zsh)"` のように途中に `"` が入るため、
  # コメント行の固定文字列（"# mise（バージョン管理）"）をアンカーとして利用する。
  #
  # rc ファイルの差異:
  #   Linux  : ~/.zshrc, ~/.bashrc
  #   macOS  : ~/.zshrc, ~/.bash_profile, ~/.bashrc
  #     （macOS のターミナル.app は bash をログインシェルで起動するため
  #      ~/.bash_profile が一次読み込み対象。~/.bashrc も非ログインシェル向けに残す）
  local rc_files=("$HOME/.zshrc")
  if _is_darwin; then
    rc_files+=("$HOME/.bash_profile")
  fi
  rc_files+=("$HOME/.bashrc")

  local rc_file rc_display shell_kind activate_cmd
  for rc_file in "${rc_files[@]}"; do
    case "$rc_file" in
    *.zshrc) shell_kind="zsh" ;;
    *) shell_kind="bash" ;;
    esac
    # 表示用: $HOME を `~` に置換してメッセージ短縮（ログの可読性のため）
    rc_display="~${rc_file#"$HOME"}"
    activate_cmd='# mise（バージョン管理）
eval "$("$HOME/.local/bin/mise" activate '"$shell_kind"')"'
    add_to_shell_config "$rc_file" '# mise（バージョン管理）' "$activate_cmd" \
      "$rc_display に mise 初期化を追加しました"
  done

  _MISE_INITIALIZED=1
  return 0
}

# mise を $HOME ディレクトリで実行するラッパー
# リポジトリ内（CWD に .mise.toml がある場所）で `--global` 操作を行うと
# mise が「ローカル設定がグローバルを上書きする」WARN を毎回出すため、
# サブシェルで $HOME に移動してから呼び出す。`--global` の書き先は
# ~/.config/mise/config.toml で CWD の影響を受けないため、挙動は同じ。
_mise_at_home() {
  (cd "$HOME" && "$MISE_BIN" "$@")
}

# install.sh が同梱する `<repo>/.mise.toml` を mise の信頼設定に登録する。
# install.sh 末尾でインストール状況サマリを出すため `node --version` 等の
# mise shim を CWD = リポジトリで呼び出すが、未承認の .mise.toml があると
# mise が "Config files in ... are not trusted" でエラー終了するため、
# それを未然に防ぐ。
#
# trust 範囲は SCRIPT_DIR から解決した固定パスのみ（CWD やユーザ入力は不使用）。
# trust はファイル内容ハッシュ単位なので、後の改ざんで自動失効する。
# 同パターンは .devcontainer/Dockerfile でも採用済み。
#
# $1: repo_root（.mise.toml が存在することが期待される親ディレクトリ）
# 戻り値: 常に 0（trust 失敗は警告のみで先へ進める）
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

# mise でグローバルツールを導入する汎用ヘルパー
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

  # 既にグローバル設定済みかを確認
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
