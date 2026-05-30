#!/usr/bin/env bats
# =======================================================================
# tests/unit/detect.bats
# -----------------------------------------------------------------------
# scripts/lib/detect.sh の OS / ディストリビューション判定関数を検証する。
# /etc/os-release をテンポラリファイルに差し替えて副作用なく確認する。
# =======================================================================

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$SCRIPT_ROOT/scripts/lib/detect.sh"
}

# ------------------------------------------------------------------
# _is_ubuntu_or_debian / _os_pretty_name
# ------------------------------------------------------------------
# 注意: これらの関数は /etc/os-release を直接参照する。
# 実環境での実行を前提とし、CI（Ubuntu）では _is_ubuntu_or_debian が真になることのみ確認する。

@test "_is_ubuntu_or_debian: returns true on Ubuntu/Debian (host check)" {
  if [ -f /etc/os-release ] && grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    run _is_ubuntu_or_debian
    [ "$status" -eq 0 ]
  else
    skip "Host is not Ubuntu/Debian"
  fi
}

@test "_os_pretty_name: returns non-empty string" {
  run _os_pretty_name
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "_os_pretty_name: matches PRETTY_NAME on systems with /etc/os-release" {
  if [ -f /etc/os-release ]; then
    expected=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    run _os_pretty_name
    [ "$output" = "$expected" ]
  else
    skip "/etc/os-release not present"
  fi
}

# ------------------------------------------------------------------
# _is_darwin
# ------------------------------------------------------------------
# `uname -s` をシム関数で差し替えて両ケースを確認する。
# 関数定義をローカル uname 関数で上書き → サブシェル run で評価。

@test "_is_darwin: returns 0 when uname -s reports Darwin" {
  uname() { echo "Darwin"; }
  export -f uname
  run _is_darwin
  [ "$status" -eq 0 ]
}

@test "_is_darwin: returns non-zero when uname -s reports Linux" {
  uname() { echo "Linux"; }
  export -f uname
  run _is_darwin
  [ "$status" -ne 0 ]
}

@test "_is_darwin: returns the actual host result (smoke)" {
  # 実際のホストでも呼べることを確認（CI: Linux ホスト → non-zero 想定）
  run _is_darwin
  if [ "$(uname -s)" = "Darwin" ]; then
    [ "$status" -eq 0 ]
  else
    [ "$status" -ne 0 ]
  fi
}
