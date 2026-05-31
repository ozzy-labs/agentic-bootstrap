#!/bin/bash
# shellcheck disable=SC2088  # チルダはログメッセージ内の表示用であり、パス展開は不要
# scripts/lib/doctor-checks.sh
# Doctor サブコマンドが行う各診断ロジック。
# 各 check_* 関数は doctor_record 関数を呼んで結果を集計バケットに追記する。
# 前提: lib/detect.sh, lib/mise.sh が事前に source されていること。
# 前提: SCRIPT_DIR が定義されていること（リポジトリ内 dotfiles の解決用）。

# 1. システム基本ツールの検証
# agentyard が動くために最低限必要な CLI が揃っているかをチェック
check_system_tools() {
  local tools=(curl git unzip xz tar)
  local tool
  for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      doctor_record ok "system-tools" "$tool: 利用可能"
    else
      local fix
      if _is_ubuntu_or_debian; then
        case "$tool" in
        xz) fix="sudo apt-get install -y xz-utils" ;;
        *) fix="sudo apt-get install -y $tool" ;;
        esac
      else
        fix="brew install $tool"
      fi
      doctor_record error "system-tools" "$tool が見つかりません" "$fix"
    fi
  done
}

# 2. mise の存在確認と PATH 設定の検証
check_mise() {
  if [ -x "$MISE_BIN" ]; then
    local mise_version
    mise_version=$("$MISE_BIN" --version 2>/dev/null | head -n1)
    doctor_record ok "mise" "mise が利用可能 ($mise_version)"

    # PATH に ~/.local/bin と shims ディレクトリが含まれるか
    if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
      doctor_record ok "mise" "PATH に ~/.local/bin が含まれている"
    else
      doctor_record warn "mise" "PATH に ~/.local/bin が含まれていない（シェル再起動で反映される可能性あり）" \
        'export PATH="$HOME/.local/bin:$PATH"'
    fi

    if [[ ":$PATH:" == *":$HOME/.local/share/mise/shims:"* ]]; then
      doctor_record ok "mise" "PATH に mise shims が含まれている"
    else
      doctor_record warn "mise" "PATH に mise shims が含まれていない（mise activate が必要）" \
        'eval "$(mise activate bash)"  # または zsh'
    fi
  else
    doctor_record error "mise" "mise が未インストール ($MISE_BIN にバイナリなし)" \
      "curl -fsSL https://mise.run | sh"
  fi
}

# 3. mise 管理下の主要ツール（Node.js / pnpm / Python / uv）の整合性
check_mise_managed_tools() {
  if ! [ -x "$MISE_BIN" ]; then
    # mise 自体が無いため check_mise の方で error 報告済み。スキップ。
    return 0
  fi

  local expected=(node pnpm python uv)
  local managed_list
  managed_list=$(_mise_at_home ls --global 2>/dev/null | awk '{print $1}')

  local tool
  for tool in "${expected[@]}"; do
    if printf '%s\n' "$managed_list" | grep -qx "$tool"; then
      local installed_version
      installed_version=$(_mise_at_home current "$tool" 2>/dev/null || echo "?")
      doctor_record ok "mise-tools" "$tool は mise 管理下 (current: $installed_version)"
    else
      local recommended
      # NOTE: aqua レジストリ追従のずれによる破綻を避けるため、aqua バックエンド
      # 経由のツールは具体パッチ版にピンする。core バックエンド (node, python) は
      # 例外。バージョンは .mise.toml と同期させる。
      case "$tool" in
      node) recommended="node@lts" ;;
      pnpm) recommended="pnpm@10.33.2" ;;
      python) recommended="python@latest" ;;
      uv) recommended="github:astral-sh/uv@0.11.9" ;;
      *) recommended="$tool@latest" ;;
      esac
      doctor_record warn "mise-tools" "$tool が mise で管理されていない" \
        "mise use --global $recommended"
    fi
  done
}

# 4. chezmoi 管理下のドットファイルの drift 検出
check_chezmoi_drift() {
  if ! command -v chezmoi &>/dev/null; then
    doctor_record warn "chezmoi" "chezmoi が未インストール（drift 検出スキップ）" \
      "mise use --global chezmoi@2.70.2"
    return 0
  fi

  # SCRIPT_DIR は scripts/ ディレクトリ。1 つ上がリポジトリルート。
  local repo_root
  repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [ ! -d "$repo_root/dotfiles" ]; then
    doctor_record warn "chezmoi" "リポジトリ内に dotfiles/ がない（drift 検出スキップ）"
    return 0
  fi

  # chezmoi diff: drift がなければ空文字。エラーは無視する。
  local diff_output
  diff_output=$(chezmoi diff --source "$repo_root/dotfiles" 2>/dev/null || true)
  if [ -z "$diff_output" ]; then
    doctor_record ok "chezmoi" "ドットファイルに drift なし (source: $repo_root/dotfiles)"
  else
    local diff_lines
    diff_lines=$(printf '%s\n' "$diff_output" | wc -l)
    doctor_record warn "chezmoi" "ドットファイルに drift あり ($diff_lines 行の差分)" \
      "chezmoi apply --source $repo_root/dotfiles"
  fi
}

# 5. ~/.zshrc.d/ の読み込み設定の存在確認
check_zshrc_d() {
  if [ ! -d "$HOME/.zshrc.d" ]; then
    doctor_record warn "zshrc.d" "~/.zshrc.d/ ディレクトリが存在しない" \
      "mkdir -p ~/.zshrc.d"
    return 0
  fi

  if [ ! -f "$HOME/.zshrc" ]; then
    doctor_record warn "zshrc.d" "~/.zshrc が存在しない（zsh を使用していない場合は問題なし）"
    return 0
  fi

  if grep -q "zshrc.d" "$HOME/.zshrc"; then
    doctor_record ok "zshrc.d" "~/.zshrc.d/ の読み込み設定が ~/.zshrc に存在"
  else
    doctor_record warn "zshrc.d" "~/.zshrc.d/ の読み込み設定が ~/.zshrc に未追加" \
      "./install.sh local  # または手動で .zshrc に追加"
  fi
}
