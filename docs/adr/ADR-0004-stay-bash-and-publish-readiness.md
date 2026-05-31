# ADR-0004: 全体アーキテクチャ方針の再確認（Bash 維持と公開準備）

## ステータス

承認済み（2026-04-29）

ADR-0001 を継承・補強する。

## コンテキスト

パブリック公開（OSS としての発信）に向けて、`agentyard` の実装言語と配布形式を再検討する必要が生じた。具体的には以下の選択肢が候補に挙がった。

1. **Bash 維持**: 現行の `install.sh` + `scripts/setup-local-*.sh` を Bash のまま継続し、保守性は責務分割で解決する。
2. **TypeScript + npm パッケージ化**: `@ozzylabs/agentyard` として npm に publish し、`npx` 経由で実行させる。
3. **Bun 単一バイナリ**: TypeScript で書き、Bun で単一バイナリにコンパイルして GitHub Release で配布する。
4. **Deno**: 同様に Deno の `deno install` ベースで配布する。

検討の背景として以下があった。

- 現状の `setup-local-linux.sh` が 1461 行の一枚岩になっており、保守性が課題視されている。
- 「洗練された対話 UI」「ライフサイクル管理」「プロフェッショナルなリリース運用」を実現したいという要望があった。
- 公開時の第一印象とユーザー体験を底上げしたい。

## 決定

**Bash + `curl | bash` 配布を維持する**。

保守性の課題は **`scripts/lib/*.sh` への責務分割と bats テスト導入** で解決する。「洗練された UI」「ライフサイクル管理」「プロリリース」の各要望は、それぞれ独立した手段で達成する。

- 言語: Bash（POSIX sh ではなく bash 4+ を前提とする。対象 OS で標準搭載されているため）
- 配布: GitHub の `install.sh` を `curl --proto '=https' --tlsv1.2 -fsSL ... | bash` で実行
- リリース: `release-please` で GitHub Release + CHANGELOG 自動化（npm registry は使わない）
- 公開準備: README ストーリー、デモ可視化、SHA256 チェックサム配布

## 理由

### 1. 依存最小化（ADR-0001 の継承）

agentyard は **ランタイム導入前** に実行されるツールである。Node.js 自身に依存させることは、依存解決の循環構造（`install.sh` で Node を入れた後に `npx` でメインロジックを呼ぶ）を生み、ツールの本質的役割と矛盾する。

### 2. 業界標準

OS 環境セットアップ系の主要 OSS はすべて `curl | sh` 系を採用している。

| ツール | 配布形式 |
|---|---|
| oh-my-zsh | curl \| bash |
| Homebrew | curl \| bash (Ruby) |
| mise | curl \| sh (Rust バイナリ) |
| chezmoi | curl \| sh (Go バイナリ) |
| starship | curl \| sh (Rust バイナリ) |
| rustup | curl \| sh (Rust バイナリ) |
| n (Node version manager) | curl \| bash（Node ツールだが npm 経由しない） |

npm 化された `create-*` 系は **プロジェクトひな型生成ツール** であり、本プロジェクトとはドメインが異なる。

### 3. ROI

公開時のユーザー adoption は、配布形式ではなく **README 品質・デモ・哲学の言語化** で決まる。npm 化に投じる開発・保守コストは、これらの公開面整備に振り向けた方が効果的である。

### 4. 公開時の第一印象

`curl | bash` で何の依存もなく動くツールは、ユーザーから見た「最初の一歩のハードル」が最低水準にある。Node.js のインストールを要求する設計は、対象が「ランタイムを持っていないユーザー」である本プロジェクトでは逆効果。

### 5. 保守性は分離で解決可能

setup スクリプトの肥大化（1461 行）は **言語選択の問題ではなく責務分離の不徹底** である。`scripts/lib/*.sh` への分割と bats テスト導入で、TypeScript リライトと同等の保守性向上が、コスト 1 桁少なく達成できる。

## 却下した代替案

### TypeScript + npm パッケージ化

- 上記「依存最小化」と直接矛盾する。
- 業界標準と乖離する。
- 掲げた便益（Lifecycle Management・Doctor・release-please）はすべて Bash でも達成可能であり、npm 化を必須とする論拠が成立しない。
- 公開時の adoption に与える効果は限定的で、コスト対効果が見合わない。

### Bun 単一バイナリ

- バイナリ配布のメリット（依存ゼロ）は `curl | bash` でも本質的に同じ。
- クロスコンパイル・バイナリサイズ・署名/検証の運用負荷が増える。
- Bash の保守性問題は責務分割で解決済みであり、バイナリ化の動機が薄い。

### Deno

- 上記 TS+npm と同じ依存最小化問題を抱える。
- エコシステム成熟度・ユーザーの実行環境普及度で Node に劣り、配布対象として不利。

## 影響

### アーキテクチャへの影響

- ADR-0001 の方針を継続する。本 ADR は ADR-0001 を **supersede** ではなく **補強・再確認** する位置付けである。
- `scripts/setup-local-linux.sh` は `scripts/lib/*.sh` への責務分割を行う（別 issue）。
- `scripts/doctor.sh` を新設し、Doctor 機能を Bash で実装する（別 issue）。

### リリース運用への影響

- `release-please` を `simple` モードで導入し、Conventional Commits → SemVer → CHANGELOG → GitHub Release を自動化する。
- npm registry / Trusted Publishing / `npm publish --provenance` は対象外。
- リリースアセットとして `install.sh` と `install.sh.sha256` を GitHub Release に添付する。

### 公開準備への影響

- README に哲学セクション、TLS 明示推奨コマンド、検査手順、SHA256 検証手順、デモ GIF/SVG を追加する。
- `README.md` と `README.ja.md` を同期更新する。

### テストへの影響

- bats を用いた lib モジュール単位のユニットテストを CI で実行する。
- 既存の `shellcheck` / `shfmt` チェックは継続する。

## 関連 ADR

- **ADR-0001** 全体アーキテクチャ（Bash ベース） — 本 ADR が継承・補強する
- **ADR-0002** ツール選定（mise, uv, Docker 等） — 影響なし
- **ADR-0003** 設定管理方針（chezmoi, Auto/Interactive モード） — 影響なし
