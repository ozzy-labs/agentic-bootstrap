#!/bin/bash
# scripts/lib/detect.sh
# 環境判定ヘルパー（OS / 対話モード / WSL / Ubuntu/Debian 互換性）
# このファイルは source して利用する。直接実行しない。

# 非対話モードかどうかを判定
# AGENTIC_BOOTSTRAP_ASSUME_YES=1（旧名 BOOTSTRAP_ASSUME_YES もフォールバック）
# または CI=true でプロンプトを自動回答する
_is_non_interactive() {
  [ "${AGENTIC_BOOTSTRAP_ASSUME_YES:-${BOOTSTRAP_ASSUME_YES:-0}}" = "1" ] || [ "${CI:-}" = "true" ]
}

# /etc/os-release を読み Ubuntu/Debian 系かを判定
_is_ubuntu_or_debian() {
  [ -f /etc/os-release ] && grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null
}

# macOS（Darwin カーネル）かを判定
# 共有 lib のフロー分岐（OS 固有の rc ファイル等）に利用する。
_is_darwin() {
  [ "$(uname -s)" = "Darwin" ]
}

# /etc/os-release から PRETTY_NAME を取得
_os_pretty_name() {
  if [ -f /etc/os-release ]; then
    grep PRETTY_NAME /etc/os-release | cut -d'"' -f2
  else
    uname -s
  fi
}
