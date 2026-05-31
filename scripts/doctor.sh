#!/bin/bash
# scripts/doctor.sh
# 開発環境の整合性を診断し、問題があれば修復ヒントを提示する。
#
# Exit code:
#   0 = 健全（warn / error なし）
#   1 = 警告あり（推奨ツール未インストール、軽微な drift 等）
#   2 = エラーあり（必須ツール欠落、修復が必要）
#
# Usage:
#   ./install.sh doctor          # 通常実行
#   ./scripts/doctor.sh          # 直接実行も可

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/detect.sh
. "$SCRIPT_DIR/lib/detect.sh"
# shellcheck source=lib/prompts.sh
. "$SCRIPT_DIR/lib/prompts.sh"
# shellcheck source=lib/shell_config.sh
. "$SCRIPT_DIR/lib/shell_config.sh"
# shellcheck source=lib/apt.sh
. "$SCRIPT_DIR/lib/apt.sh"
# shellcheck source=lib/mise.sh
. "$SCRIPT_DIR/lib/mise.sh"
# shellcheck source=lib/doctor-checks.sh
. "$SCRIPT_DIR/lib/doctor-checks.sh"

# Doctor は読み取り専用の診断であり対話プロンプトを伴わない。
# tty fallback は不要なので呼び出さない。

# ========================================
# 結果集計バケット
# ========================================
# 各エントリは "STATUS|CATEGORY|MESSAGE|FIX_HINT" 形式
# FIX_HINT は省略可
_DOCTOR_RESULTS=()

# 結果を記録するヘルパー
# $1: status (ok / warn / error)
# $2: category (system-tools / mise / chezmoi 等)
# $3: message
# $4: fix_hint（省略可）
doctor_record() {
  local status="$1"
  local category="$2"
  local message="$3"
  local fix_hint="${4:-}"
  _DOCTOR_RESULTS+=("$status|$category|$message|$fix_hint")
}

# ========================================
# 診断実行
# ========================================

echo "🩺 agentyard doctor を実行中..."
echo ""

check_system_tools
check_mise
check_mise_managed_tools
check_chezmoi_drift
check_zshrc_d

# ========================================
# 結果表示と集計
# ========================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 診断結果"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ok_count=0
warn_count=0
error_count=0
fix_hints=()

for result in "${_DOCTOR_RESULTS[@]}"; do
  IFS='|' read -r status category message fix_hint <<<"$result"
  case "$status" in
  ok)
    icon="✅"
    ok_count=$((ok_count + 1))
    ;;
  warn)
    icon="⚠️ "
    warn_count=$((warn_count + 1))
    ;;
  error)
    icon="❌"
    error_count=$((error_count + 1))
    ;;
  *)
    icon="?"
    ;;
  esac
  printf '%s [%s] %s\n' "$icon" "$category" "$message"
  if [ -n "$fix_hint" ] && [ "$status" != "ok" ]; then
    printf '   ↳ 対処: %s\n' "$fix_hint"
    fix_hints+=("$fix_hint")
  fi
done

echo ""
printf 'サマリー: ✅ %d  ⚠️  %d  ❌ %d\n' "$ok_count" "$warn_count" "$error_count"
echo ""

# ========================================
# 終了処理
# ========================================

if [ "$error_count" -gt 0 ]; then
  echo "❌ エラーがあります。上記の対処コマンドを実行してから再度 doctor を実行してください。"
  exit 2
elif [ "$warn_count" -gt 0 ]; then
  echo "⚠️  警告があります。必要に応じて対処コマンドを実行してください。"
  exit 1
else
  echo "🎉 環境は健全です。"
  exit 0
fi
