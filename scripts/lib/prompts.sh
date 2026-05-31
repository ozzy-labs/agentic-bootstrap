#!/bin/bash
# scripts/lib/prompts.sh
# 対話プロンプトヘルパー。非対話モード（CI / AGENTYARD_ASSUME_YES、旧名 AGENTIC_BOOTSTRAP_ASSUME_YES / BOOTSTRAP_ASSUME_YES）では自動応答する。
# このファイルは source して利用する。前提: lib/detect.sh が事前に source されていること。

# [Y/n] プロンプト（既定 Y）を処理し、REPLY に結果を設定する
# 非対話時は read をスキップして REPLY=Y を即設定
# $1: プロンプト文字列
_prompt_default_yes() {
  local prompt="$1"
  if _is_non_interactive; then
    REPLY=Y
    printf '%sY (non-interactive)\n' "$prompt"
    return 0
  fi
  REPLY=""
  read -p "$prompt" -n 1 -r || true
  echo ""
}

# [y/N] プロンプト（既定 N）を処理し、REPLY に結果を設定する
# 非対話時は read をスキップして REPLY=N を即設定
# $1: プロンプト文字列
_prompt_default_no() {
  local prompt="$1"
  if _is_non_interactive; then
    REPLY=N
    printf '%sN (non-interactive)\n' "$prompt"
    return 0
  fi
  REPLY=""
  read -p "$prompt" -n 1 -r || true
  echo ""
}

# パイプ実行時 (curl ... | bash) でも対話プロンプトが動作するよう、
# stdin が tty でなく /dev/tty が読める場合は /dev/tty にフォールバックする。
# 非対話モード（CI / ASSUME_YES）ではフォールバックしない。
# 呼び出し側スクリプト先頭で `_attach_tty_if_needed` を呼ぶ。
#
# /dev/tty へのフォールバックが必要なのに失敗した場合（curl|bash + WSL2 等で
# /dev/tty が `No such device or address` になるケース）は、プロンプトが
# 表示されないまま read だけが進行する致命的 UX 不具合を避けるため、明示的
# なエラーメッセージを出して exit 1 する。silent fallback はしない。
_attach_tty_if_needed() {
  # 既に TTY を持っている / 非対話モード → 何もしない
  if [ -t 0 ] || _is_non_interactive; then
    return 0
  fi

  # /dev/tty への attach を試行
  # 注意: `exec </dev/tty 2>/dev/null` の 2>/dev/null は exec 自身の
  # redirection failure メッセージを抑止しない（bash の仕様）。
  # `{ exec ...; } 2>/dev/null` のグルーピング経由で抑止する必要がある。
  # グループ内の exec は親シェルの stdin を引き継ぐ（subshell ではないため）。
  if [ -c /dev/tty ] && { exec </dev/tty; } 2>/dev/null; then
    return 0
  fi

  # ここに来た時点で stdin は非 TTY、/dev/tty も open 不能。
  # 黙って続行すると read -p のプロンプトが一切表示されなくなるので fail-loud する。
  {
    printf '%s\n' "⚠️  対話プロンプト用の TTY を確保できませんでした"
    printf '%s\n' "ℹ️  考えられる原因:"
    printf '%s\n' "    - stdin が pipe で、/dev/tty へのフォールバックも失敗した"
    printf '%s\n' "    - curl ... | bash 実行時に /dev/tty が利用不可（WSL2 の一部環境 / コンテナ / サブシェル）"
    printf '%s\n' "ℹ️  対処法:"
    printf '%s\n' "    1. ファイル経由で実行する（推奨）:"
    printf '%s\n' "         curl --proto '=https' --tlsv1.2 -fsSL \\"
    printf '%s\n' "           https://raw.githubusercontent.com/ozzy-labs/agentyard/main/install.sh \\"
    printf '%s\n' "           -o /tmp/install.sh && bash /tmp/install.sh local"
    printf '%s\n' "    2. プロセス置換で実行する:"
    printf '%s\n' "         bash <(curl --proto '=https' --tlsv1.2 -fsSL \\"
    printf '%s\n' "           https://raw.githubusercontent.com/ozzy-labs/agentyard/main/install.sh) local"
    printf '%s\n' "    3. 非対話モードで実行する（全カテゴリを既定値でインストール）:"
    printf '%s\n' "         curl --proto '=https' --tlsv1.2 -fsSL \\"
    printf '%s\n' "           https://raw.githubusercontent.com/ozzy-labs/agentyard/main/install.sh \\"
    printf '%s\n' "           | AGENTYARD_ASSUME_YES=1 bash -s -- local"
  } >&2
  exit 1
}
