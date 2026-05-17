---
name: health
description: リポジトリ改修中に意図せず残る状態（working tree, stash, branch, worktree, PR, issue, actions など）と skill catalog 整合性を一発で確認し、16 領域のステータス表で俯瞰しつつ各項目に固定語彙の推奨アクションを inline で付与して報告する。`--deep` 指定時は `要確認` 項目を read-only コマンドで追加調査し、機械判定可能な範囲でラベルを格上げする。検査と提示のみで、削除・close 等の実行は行わない。
---

# health - リポジトリ状態の確認と推奨アクション提示

リポジトリ改修中に意図せず残る状態（中断中の git op、未 push commit、stale branch、open PR/issue、failed CI など）と skill catalog の整合性を 16 領域に渡って確認し、各項目に **固定語彙の推奨アクション** を inline で付与して報告する。

判断と実行はユーザーが行う。本スキルは検査と提示のみを担当し、削除・drop・prune・close 等は実行しない。

## 入力

- 引数なし → Phase 1 のみ実行（routine 互換、決定論的）
- `--deep` → Phase 1 完了後、`要確認` フラグが付いた項目に Phase 2 の追加調査を行う（後述）

`--deep` は明示時のみ有効。routine 経路（`/loop`, `schedule`）でも `--deep` がなければ Phase 1 のみ。

## 動作原則

- **並列実行:** 全領域のチェックコマンドを **同一メッセージ内の複数 Bash 呼び出し** で並列起動する（直列実行は禁止）。Phase 2 の追加調査も同様に並列起動する
- **per-check error handling:** あるチェックが失敗（gh 未認証、コマンド不在、network エラー等）しても他チェックは継続する。失敗した領域は section 内にエラー行を出力する
- **対話禁止:** AskUserQuestion を使わない
- **実行禁止:** 削除・drop・prune・close 等の解消アクションを実行しない（推奨を表示するのみ）。Phase 2 でも read-only コマンドのみ
- **推奨は固定語彙のみ:** 後述の語彙以外は使わない。Phase 2 でも語彙拡張はしない（既存ラベルへの書き換え or `要確認` 維持 + 根拠付与のみ）。Claude の自由判断で文言を生成しない
- **section 順序固定:** Broken state → Local artifacts → Triage(mine) → Triage(automation) の順で出力する。順序が暗黙の優先度を表現する
- **section 内ソート:** Routine 実行時の差分を安定化するため、各 section で **決定論的な順序** を採用する。具体的には:
  - 元コマンドが自然順を返すもの（`git stash list`, `git worktree list`, `git status -s`, `git submodule status`, `git tag -l`）は **元コマンドの順序を維持**
  - branch / PR / issue / failed run / draft release は **古い順（最終更新が古いものほど上）** で stale 項目を section 上部に集約する。具体的なソート方法は各 section で指定する（git は `--sort` 等のフラグ、gh は `--json` 結果の client side ソート）

## 推奨アクション語彙（固定）

| ラベル | 意味 / 推奨コマンド | 適用条件 |
|---|---|---|
| `delete` | `git branch -d <name>`（safe。force `-D` は推奨しない） | merged PR と紐づく local branch |
| `drop` | `git stash drop` | 紐づく branch なし、または閾値より古い stash |
| `prune` | `git remote prune origin` / `git worktree remove` | gone な tracking ref / orphaned worktree |
| `push` | `git push` | ahead で未 push、PR 未作成 |
| `fetch` | `git fetch --tags` | remote にあって local 未取得の tag |
| `要確認` | 機械判断不能、ユーザー目視 | 古い stash / 古い branch / failed CI run |
| `要対応` | human decision 必要 | open PR / open issue / review request / draft release |
| `abort or continue` | broken state の解消 | MERGE_HEAD / REBASE_HEAD / CHERRY_PICK_HEAD / BISECT_LOG |
| (なし) | 情報のみ表示 | working tree のファイル一覧 / submodule の通常状態 |

「閾値より古い」の目安は 14 日。

## チェック対象（16 領域）

各領域について「コマンド」「推奨アクションの判定ルール」を定義する。

### Broken state

#### 1. interrupted git ops

- コマンド: `ls .git/MERGE_HEAD .git/REBASE_HEAD .git/CHERRY_PICK_HEAD .git/BISECT_LOG 2>/dev/null`
- 存在するファイル名を表示し、推奨アクション `abort or continue` を付与する

#### 2. conflict markers

- コマンド: `git diff --check`
- 出力されたファイル/行を表示し、推奨アクション `要確認` を付与する

### Local artifacts

#### 3. working tree

- コマンド: `git status -s`
- 出力をそのまま表示する。推奨アクションは付けない（情報のみ）

#### 4. stash

- コマンド: `git stash list --format='%gd %ci %gs'`
- 各 stash について経過日数を計算し:
  - 元 branch が現存しない → `drop`
  - 14 日以上経過 → `要確認`
  - それ以外 → 推奨なし

#### 5. local branch

- コマンド: `git branch -vv` および `git for-each-ref --sort=committerdate --format='%(refname:short) %(upstream:track) %(committerdate:relative)' refs/heads/`（古い順）
- PR 検出（**1 度だけ batch 取得**）: `gh pr list --state all --json number,state,mergedAt,headRefName --limit 100` を 1 回実行し、client side で local branch 名と `headRefName` を join する（branch ごとに gh を呼ばない）
- 各 branch について:
  - `worktree-agent-<id>` パターン（Claude Code harness が作る合成 branch）:
    - 対応する `.claude/worktrees/agent-<id>/` worktree が **存在する** → 推奨なし（使用中）
    - 対応する worktree が **存在しない** → タグ `drive synthetic` を付与し、`prune`（`git branch -D <branch>`。親 worktree が削除済みの orphan synthetic branch。[Issue #71](https://github.com/ozzy-labs/skills/issues/71)）
  - merged 済みの PR が存在し、かつ merge base 以降に追加 commit が **ない** → `delete`（PR 番号を表示）
  - merged 済みの PR が存在し、かつ merge base 以降に追加 commit が **ある** → `要確認`（PR 番号と追加 commit 数を表示。merge 後に作業継続したケース）
  - upstream なし、かつ最終 commit から 14 日以上 → `要確認`
  - upstream なし、かつ 1 commit 以上、かつ最終 commit から 14 日未満 → `push`（新規ブランチで未 push のケース）
  - upstream あり、ahead で未 push、関連 PR なし → `push`
  - それ以外 → 推奨なし

「追加 commit の有無」の判定: PR の merge commit と local branch の `git rev-list --count <merge-commit>..<branch>` を比較し、結果が 0 なら追加なし、1 以上なら追加あり。

`worktree-agent-<id>` の id 部分は `.claude/worktrees/agent-<id>/` の id と 1:1 対応する。判定手順:

1. #7 worktree チェックで取得した `git worktree list --porcelain` 結果から、`.claude/worktrees/agent-<id>/` パスの `<id>` を抽出して集合を作る（例: `{a33c59a3504b6dc3e, a6658497dd970cd6d}`）
2. 各 local branch 名のうち `worktree-agent-` で始まるものから prefix を除いた残り部分を id 候補として抽出
3. id 候補が手順 1 の集合に **含まれない** branch を orphan synthetic と判定する

branch ごとに `git worktree list` を呼ばない（#7 の結果を使い回す）。

表示例:

```text
#5 local branch:
  worktree-agent-a33c59...    drive synthetic, parent worktree missing  → prune (git branch -D)
  ci/playwright-...           merged (PR #117)                          → delete
```

#### 6. remote tracking

- コマンド: `git remote prune origin --dry-run`
- 表示された ref を列挙し、推奨アクション `prune` を付与する

#### 7. worktree

- コマンド: `git worktree list --porcelain`
- main worktree 以外を列挙する。`locked` 状態の worktree も漏らさず表示する（`git worktree list --porcelain` は `locked` も含めて出力するため通常通り扱えばよい）
- 各 worktree について判定:
  - パスが `.claude/worktrees/agent-*` パターン → タグ `drive orphan` を付与し、`prune` 推奨（`/drive` skill の Phase Final-2 cleanup を通らなかった残骸の可能性。異常終了 / interrupt / 手動 kill 等）
  - `locked` 状態 → タグ `locked` を併記。`prune` 推奨コマンドは `git worktree remove -f -f <path>` を提示する（`-f -f` の二重 force は Claude Code harness の `lock` 解除のため必須。[Issue #71](https://github.com/ozzy-labs/skills/issues/71)）
  - 関連 branch が merged または存在しない → `prune`
  - それ以外 → 推奨なし

タグは推奨アクションとは別軸の **分類ラベル** として表示する（推奨アクション語彙は固定のまま）。表示例:

```text
#7 worktree:
  /home/.../repo/.claude/worktrees/agent-a33c59... [ci/playwright-...]  drive orphan, locked  → prune (git worktree remove -f -f)
  /home/.../repo/.claude/worktrees/agent-a6658... [docs/html-js-...]    drive orphan, locked  → prune (git worktree remove -f -f)
  /home/.../repo/../old-feature                    [feat/old]           → prune
```

#### 8. submodule

- コマンド: `git submodule status`
- submodule がない場合は `(none)` 表示
- prefix が `+`（uncommitted）/ `-`（uninitialized）/ `U`（merge conflict）の場合は表示し、推奨アクション `要確認` を付与する

#### 9. tag

- コマンド: `git ls-remote --tags origin` と `git tag -l`
- local 側にあって remote にない → `push`
- remote 側にあって local にない → `fetch`

### Triage（mine）

#### 10. open PR (mine)

- コマンド: `gh pr list --author @me --state open --json number,title,isDraft,updatedAt`
- **client side で `updatedAt` 昇順にソート**してから表示する（古いほど上）
- 各 PR について:
  - draft → `要確認`
  - それ以外 → `要対応`

#### 11. open issue (assigned to me)

- コマンド: `gh issue list --assignee @me --state open --json number,title,updatedAt`
- **client side で `updatedAt` 昇順にソート**してから表示する（古いほど上）
- 各 issue を表示し、推奨アクション `要対応` を一律付与する。経過日数は表示行の補足情報として含める

#### 12. review request (waiting on me)

- コマンド: `gh pr list --search "is:open review-requested:@me" --json number,title,author,updatedAt`
- **client side で `updatedAt` 昇順にソート**してから表示する（古いほど上）
- 各 PR を表示し、推奨アクション `要対応` を付与する

#### 13. recent failed actions

- 前提: `git branch --show-current` で現在ブランチを取得する。空文字（detached HEAD）の場合は section に `(skipped: detached HEAD)` を表示し、コマンドを実行しない
- コマンド: `gh run list --branch "<current-branch>" --status failure --limit 5 --json databaseId,name,conclusion,createdAt,url`
- **client side で `createdAt` 昇順にソート**してから表示する（古いほど上）
- 各 run を表示し、推奨アクション `要確認` を付与する

#### 14. draft release

- コマンド: `gh release list --limit 20 --json name,tagName,isDraft,createdAt`
- isDraft=true のみ抽出し、**client side で `createdAt` 昇順にソート**してから表示する
- 推奨アクション `要対応` を付与する

### Triage（automation）

#### 15. automation PR

- コマンド: `gh pr list --state open --limit 100 --json number,title,author,updatedAt`
- **client side で author を判別**する（GitHub search の `author:` は OR 不可、AND になるため別アプローチを採る）。`author.login` が下記のパターンに一致するものを抽出:
  - `app/renovate` / `renovate[bot]`
  - `app/dependabot` / `dependabot[bot]`
  - `app/release-please` / `release-please[bot]`
  - その他 `*[bot]` または `app/*` 形式の機械作者
- 抽出後、**`updatedAt` 昇順にソート**してから表示する（古いほど上）
- 各 PR について author 種別と経過日数を表示し、推奨アクション `要対応` を付与する
- 該当なしの場合は section 自体を `(none)` で表示する

### Skill catalog consistency

#### 16. perspective MD frontmatter

review skill が参照する `src/skills/review/perspectives/<axis>.md`（[ADR-0025](https://github.com/ozzy-labs/handbook/blob/main/adr/0025-skills-review-multi-perspective.md)）の frontmatter スキーマと glob 妥当性を検証する。配信先（`.claude/skills/review/perspectives/` および `.agents/skills/review/perspectives/`）にも同じファイルが揃っているかを確認する。

- 検査対象ディレクトリ:
  - `src/skills/review/perspectives/<axis>.md`（SSOT）
  - `.claude/skills/review/perspectives/<axis>.md`（Claude Code 配信先）
  - `.agents/skills/review/perspectives/<axis>.md`（codex / gemini 配信先）
- 検査項目（順に実施）:
  1. SSOT に存在する `<axis>.md` のうち `README.md` 以外を列挙する
  2. 各観点 MD の frontmatter に **必須キー** `name`, `category`, `description`, `applies_when`, `default_enabled`, `severity_rules`, `exit_criteria` が揃っているか確認する（`skip_when` は任意）
  3. `name` がファイル名（拡張子なし）と一致するか
  4. `category` が `required` / `design` / `quality` / `ux` のいずれかか
  5. `applies_when` / `skip_when.diff_only_in` の各 glob が文字列として有効か（空でない、`/` ではじまらない、改行を含まない）
  6. `severity_rules` に `critical` / `warning` / `info` の 3 段階がすべて含まれているか
  7. `exit_criteria.drive_loop` に少なくとも `critical` の許容しきい値が含まれているか
  8. SSOT と配信先のファイル一覧が一致しているか（drift があれば `pnpm run build` の取り違えを示唆）
- 推奨アクション:
  - 必須キー欠落 / 値不正 → `要確認`（観点 MD の frontmatter を修正）
  - SSOT と配信先の drift → `要確認`（`pnpm run build` を実行して再生成）
  - すべて整合 → 推奨なし（情報のみ表示）

新しい観点 MD を追加した直後は **必ず本領域を確認** すること。SSOT のみで配信先に drift がある場合、review skill / `code-reviewer` agent が古い観点定義を読む。

## Phase 2: Investigation（`--deep` 時のみ）

`--deep` 指定時、Phase 1 で `要確認` フラグが付いた項目に対し read-only な追加調査を行い、機械判定可能な範囲でラベルを格上げする。

### 起動条件

- `--deep` フラグ明示時のみ実行する。デフォルト無効
- routine 経路（`/loop`, `schedule`）でも `--deep` がなければ起動しない（決定論性維持）
- Phase 1 の出力に `要確認` が 0 件なら自動スキップする

### 対象範囲

Phase 1 で `要確認` が付いた項目のうち、機械判定可能なものに限定する。

| 領域 | 調査コマンド（read-only） | ラベル更新ルール |
|---|---|---|
| 4. stash（14d+） | `git stash show -p stash@{N} \| git apply --check`（HEAD への clean apply 可否、exit code 0 = 可、非 0 = 不可） | clean apply 不可 → `drop` に格上げ / 可能 → `要確認` 維持 |
| 5. local branch（upstream なし、14d+） | `git cherry <trunk> <branch>`（trunk への取り込み判定。trunk は `main` を仮定する。`master` 等を使うリポでは将来 `gh repo view --json defaultBranchRef` で動的検出する案あり） | 全 `-` 印（trunk 含み済み）→ `delete` に格上げ / それ以外 → `要確認` 維持 |
| 5. local branch（merged PR + 追加 commit） | `git cherry <trunk> <branch>` 同上 | 全 `-` → `delete` に格上げ / それ以外 → `要確認` 維持 |
| 13. failed CI run | `gh run view <id> --log-failed \| tail -200` | グループに 1 件のみ → `要確認` 維持 + 「root cause: <1 行抜粋>」付与 / グループに 2 件以上 → 各グループ代表 run を `要対応` に格上げ + 「N 件同一エラー」付与、グループ内の他 run は `same as <代表 id>` 表示 |

### 対象外（Phase 2 でも `要確認` のまま、根拠も付与しない）

| 領域 | 除外理由 |
|---|---|
| 2. conflict markers | fixture / docs を破壊するリスク。片側採用提案は scope 違反 |
| 8. submodule 異常 | プロジェクト固有の判断必要。一般化した自動提案は誤誘導しやすい |
| triviality / transient 等の主観判定全般 | LLM の苦手領域、誤判定で破壊的提案につながる |

### 実行ルール

- **対象絞り込み:** Phase 1 で `要確認` フラグが付いた項目のみ調査する（「最新 N 件」ではない）
- **並列実行:** 全調査を **同一メッセージ内の複数 Bash 呼び出し** で並列起動する
- **CI ログ取得上限:** 詳細ログ取得は **最大 3 件まで**。Phase 1 で取得した failed run リスト（同一 branch、最大 5 件）の先頭 3 件を fetch し、後述の same-error 判定で **グループ化**する。4 件目以降は fetch せず、items 1-3 の代表グループ（最も古い run の id）と同一とみなして `same as <id>` 表示にする（保守的判定。詳細はユーザーに委ねる）
- **ログクリップ:** `gh run view --log-failed | tail -200` で末尾 200 行に制限する
- **same-error 判定:** `gh run view --log-failed` の出力（stdout）から ANSI エスケープシーケンスを除去後、各行を正規表現 `(error|Error|failed)[\s:].*$` でマッチさせる。マッチした行のうち**最後の行のマッチ部分のみ**を比較キーとして抽出する（job 名 / step 名 / タイムスタンプ等の行頭 prefix は対象外）。この文字列をキーとして items 1-3 間で完全一致比較してグループ化する。マッチが 0 件の場合はその run を独立グループ扱いとする（決定論性のため fuzzy matching はしない）
- **連続性の判定スコープ:** 「N 件同一エラー」の N は Phase 1 で取得した failed run リスト内（同一 branch、最大 5 件）でのグループ件数。リストを跨いだ判定はしない

### 語彙ポリシー

- 既存固定語彙 8 種から拡張しない（`要対応: rerun` 等の verb 付き形式は採用しない）
- Phase 2 の出力は次の 2 通りのみ:
  - **ラベル書き換え:** `要確認` → `delete` / `drop` / `要対応` のいずれか
  - **`要確認` 維持 + 根拠付与:** ラベルは変えず、項目末尾に `│ <1 行根拠>` を付与
- 根拠は各項目の右端に `│ <text>` 形式で 1 行付与する（パイプ文字 `│` は U+2502、矢印 `→` の後ろにスペースを挟んで配置）

### エラーハンドリング（Phase 2 固有）

| 状況 | 動作 |
|---|---|
| `git apply --check` 自体が失敗（patch corrupt 等） | 該当 stash は `要確認` 維持 + 根拠 `│ patch unreadable` |
| `gh run view --log-failed` が失敗 | 該当 run は `要確認` 維持 + 根拠 `│ log fetch failed` |
| `git cherry` がエラー（base ref 不在等） | 該当 branch は `要確認` 維持 + 根拠 `│ cherry check failed` |

Phase 2 のいずれかの調査が失敗しても他の調査は継続する。Phase 1 の出力は影響を受けない（書き換えがなければ Phase 1 ラベルがそのまま残る）。

## 明示的に除外する項目

| 項目 | 除外理由 |
|---|---|
| lockfile drift | 「意図せず残る」ではなく correctness 問題。lint/test/CI が拾う領域。言語特化 |
| gitignored-but-tracked file | rare すぎてノイズ源 |
| GitHub Actions caches / artifacts | ストレージ管理の領域、leftover 状態とは別概念 |

## 出力フォーマット

レポートは 2 ブロック構成:

1. **ステータス表**（先頭固定。16 領域を 1 表で俯瞰）
2. **非 clean section**（要対応事項のある領域のみ、compact list 形式）

### ステータス表

レポート先頭に必ず 16 行のテーブルを出力する。行順は固定（後述の section 順）で、ステータスアイコンと詳細列で各領域の状態を 1 行ずつ示す。

```text
| # | 領域 | 状態 | 詳細 |
|---|---|---|---|
| 1 | Interrupted git ops | <icon> | <detail> |
| 2 | Conflict markers | <icon> | <detail> |
| ... | ... | ... | ... |
| 15 | Automation PRs | <icon> | <detail> |
| 16 | Perspective MD frontmatter | <icon> | <detail> |
```

#### ステータスアイコン（固定）

| アイコン | 意味 | 適用条件 |
|---|---|---|
| `✅` | clean | 項目数 0 |
| `⚠️` | 非 clean | 推奨アクション付き項目が 1 件以上 |
| `❌` | error | 該当 section の取得が失敗 |
| `⏭️` | skipped | 該当 section が条件不成立で skip |

#### 詳細列（決定論的生成）

| 状態 | 詳細列の内容 |
|---|---|
| clean | `clean` |
| 非 clean（label 1 種類） | `<count> 件（<label>）` |
| 非 clean（label 複数） | `<count> 件（mixed: <l1>+<l2>+...）` ※ label は推奨アクション語彙の昇順固定（`abort or continue` / `delete` / `drop` / `fetch` / `prune` / `push` / `要対応` / `要確認`） |
| error | `error: <reason>` |
| skipped | `skipped: <reason>` |

- `<count>` は推奨アクション付き項目の総数。Phase 2 で `same as <id>` に書き換わった行は集約済みのためカウントしない
- 注: H2 section の `(<count>)` は section 内の総項目数（`same as` 行も含む）を示す。表の `<count>` は推奨アクション付き項目のみを数えるため、Phase 2 で `same as` グルーピングが起きた場合のみ両者は異なる（例: Phase 2 で 5 件の failed run が 1 代表 + 4 件の `same as` に整理されたとき、表は `1 件（要対応）`、H2 は `## Recent failed actions (5)`）
- Phase 2 でラベルが書き換わった場合（`要確認` → `drop` など）、表の "詳細" 列も書き換え後ラベルで再計算する

### 非 clean section

要対応事項のある領域のみ H2 section として出力する。section 順序は固定:

1. Interrupted git ops
2. Conflict markers
3. Working tree
4. Stash
5. Local branches
6. Remote tracking
7. Worktrees
8. Submodules
9. Tags
10. My open PRs
11. Issues assigned to me
12. Review requests on me
13. Recent failed actions
14. Draft releases
15. Automation PRs
16. Perspective MD frontmatter

各 section 内は **compact list 形式** で 1 行 1 項目を出力する:

```text
## <Section name> (<count>)
<item info>  → <label>  │ <Phase 2 rationale (--deep 時のみ)>
```

- 項目情報と推奨アクションの間は `→` で区切り、矢印の前後に半角スペースを 2 個ずつ挟む（列の整列と視認性のため）
- Phase 2 で根拠が付与された項目は末尾に `│ <text>` を付与する。パイプ `│` の前にスペース 2 個、`<text>` の前にスペース 1 個を挟む。Phase 1 のみの場合は付与しない
- `<count>` は section 内の項目数。section heading に件数のみ付与し、`(N → label)` 形式は採用しない（推奨アクションが mixed の場合に破綻するため）
- 列の整列は agent が項目幅から決める。表形式（markdown table）は項目部分には使わない（cell 幅と inline 根拠が衝突するため）

エラー section は `(error: <reason>)` を 1 行表示する。skip section は `(skipped: <reason>)` を 1 行表示する。これら error / skipped の section は **H2 section 側にも出力**し、ステータス表とあわせて 2 箇所で示す（表は俯瞰、H2 は 1 行詳細）。clean な領域は H2 section を出さない。

全 section が clean な場合は H2 section を一切出力せず、ステータス表のみで完結する。

### 出力例（Phase 1 のみ、引数なし）

```text
| # | 領域 | 状態 | 詳細 |
|---|---|---|---|
| 1 | Interrupted git ops | ✅ | clean |
| 2 | Conflict markers | ✅ | clean |
| 3 | Working tree | ✅ | clean |
| 4 | Stash | ⚠️ | 1 件（要確認） |
| 5 | Local branches | ✅ | clean |
| 6 | Remote tracking | ⚠️ | 5 件（prune） |
| 7 | Worktrees | ✅ | clean |
| 8 | Submodules | ✅ | clean |
| 9 | Tags | ⚠️ | 1 件（push） |
| 10 | My open PRs | ✅ | clean |
| 11 | Issues assigned to me | ✅ | clean |
| 12 | Review requests on me | ✅ | clean |
| 13 | Recent failed actions | ⚠️ | 5 件（要確認） |
| 14 | Draft releases | ✅ | clean |
| 15 | Automation PRs | ⚠️ | 2 件（要対応） |

## Stash (1)
stash@{0}  18d  feat/x  WIP            → 要確認

## Remote tracking (5)
origin/feat/old-1                       → prune
origin/feat/old-2                       → prune
origin/feat/old-3                       → prune
origin/feat/old-4                       → prune
origin/feat/old-5                       → prune

## Tags (1)
v0.2.0  local only                      → push

## Recent failed actions (5)
24924393951  9d  Sync commons           → 要確認
24971520228  7d  Sync commons           → 要確認
25274616099  1d  Sync commons           → 要確認
25274622229  1d  Sync commons           → 要確認
25274636372  1d  Sync commons           → 要確認

## Automation PRs (2)
#39  github-actions[bot]  1d  chore: sync commons defaults  → 要対応
#1   github-actions[bot]  0d  chore(main): release 0.1.0    → 要対応
```

### 出力例（`--deep` 時、Phase 2 適用後）

```text
| # | 領域 | 状態 | 詳細 |
|---|---|---|---|
| 1 | Interrupted git ops | ✅ | clean |
| 2 | Conflict markers | ✅ | clean |
| 3 | Working tree | ✅ | clean |
| 4 | Stash | ⚠️ | 1 件（drop） |
| 5 | Local branches | ✅ | clean |
| 6 | Remote tracking | ⚠️ | 5 件（prune） |
| 7 | Worktrees | ✅ | clean |
| 8 | Submodules | ✅ | clean |
| 9 | Tags | ✅ | clean |
| 10 | My open PRs | ✅ | clean |
| 11 | Issues assigned to me | ✅ | clean |
| 12 | Review requests on me | ✅ | clean |
| 13 | Recent failed actions | ⚠️ | 1 件（要対応） |
| 14 | Draft releases | ✅ | clean |
| 15 | Automation PRs | ✅ | clean |

## Stash (1)
stash@{0}  18d  feat/x  WIP            → drop          │ apply --check failed (conflicts with HEAD)

## Remote tracking (5)
origin/feat/old-1                       → prune
origin/feat/old-2                       → prune
origin/feat/old-3                       → prune
origin/feat/old-4                       → prune
origin/feat/old-5                       → prune

## Recent failed actions (5)
24924393951  9d  Sync commons           → 要対応       │ rsync exit 23 (5 件同一エラー)
24971520228  7d  Sync commons           → same as 24924393951
25274616099  1d  Sync commons           → same as 24924393951
25274622229  1d  Sync commons           → same as 24924393951
25274636372  1d  Sync commons           → same as 24924393951
```

注: Phase 2 によって stash が `要確認 → drop` に格上げされ、CI failure 5 件が `要確認 → 要対応 (1 件) + same as ... (4 件)` に整理された結果、ステータス表の Stash 詳細は `1 件（drop）`、Recent failed actions は `1 件（要対応）`（`same as` 行はカウント外）になる。

### 全 clean な場合の出力例

```text
| # | 領域 | 状態 | 詳細 |
|---|---|---|---|
| 1 | Interrupted git ops | ✅ | clean |
| 2 | Conflict markers | ✅ | clean |
| 3 | Working tree | ✅ | clean |
| 4 | Stash | ✅ | clean |
| 5 | Local branches | ✅ | clean |
| 6 | Remote tracking | ✅ | clean |
| 7 | Worktrees | ✅ | clean |
| 8 | Submodules | ✅ | clean |
| 9 | Tags | ✅ | clean |
| 10 | My open PRs | ✅ | clean |
| 11 | Issues assigned to me | ✅ | clean |
| 12 | Review requests on me | ✅ | clean |
| 13 | Recent failed actions | ✅ | clean |
| 14 | Draft releases | ✅ | clean |
| 15 | Automation PRs | ✅ | clean |
```

### エラー時の出力例

error / skipped は表で `❌` / `⏭️` アイコンと `error:` / `skipped:` 詳細列で示し、H2 section にも 1 行で再掲する:

```text
| # | 領域 | 状態 | 詳細 |
|---|---|---|---|
| 1 | Interrupted git ops | ✅ | clean |
| 2 | Conflict markers | ✅ | clean |
| 3 | Working tree | ✅ | clean |
| 4 | Stash | ✅ | clean |
| 5 | Local branches | ✅ | clean |
| 6 | Remote tracking | ✅ | clean |
| 7 | Worktrees | ✅ | clean |
| 8 | Submodules | ✅ | clean |
| 9 | Tags | ✅ | clean |
| 10 | My open PRs | ❌ | error: gh not authenticated |
| 11 | Issues assigned to me | ❌ | error: gh not authenticated |
| 12 | Review requests on me | ❌ | error: gh not authenticated |
| 13 | Recent failed actions | ⏭️ | skipped: detached HEAD |
| 14 | Draft releases | ❌ | error: gh not authenticated |
| 15 | Automation PRs | ❌ | error: gh not authenticated |

## My open PRs
(error: gh not authenticated)

## Issues assigned to me
(error: gh not authenticated)

## Review requests on me
(error: gh not authenticated)

## Recent failed actions
(skipped: detached HEAD)

## Draft releases
(error: gh not authenticated)

## Automation PRs
(error: gh not authenticated)
```

## エラーハンドリング

| 状況 | 動作 |
|---|---|
| `gh` コマンド不在 | Triage 系 5 section に `(error: gh not installed)` を表示し、git 系チェックは継続する |
| `gh` 未認証 | Triage 系 5 section に `(error: gh not authenticated)` を表示し、git 系チェックは継続する |
| `git` 個別コマンド失敗 | 該当 section に `(error: <stderr 1 行目>)` を表示し、他 section は継続する |
| GitHub remote なし | Triage 系 5 section に `(error: no GitHub remote)` を表示し、git 系チェックは継続する |
| network エラー | 該当 section に `(error: network)` を表示する |
| detached HEAD | Section 13 に `(skipped: detached HEAD)` を表示し、他 section は継続する |

全 section の実行は **失敗があっても中断しない**。

## 注意事項

- `.env` ファイルは読み取らない
- 削除・drop・prune・close 等の解消コマンドは **実行しない**（Phase 1/2 とも推奨表示のみ）
- branch 削除推奨は `git branch -d`（safe）。force delete `-D` は推奨に含めない
- severity ラベル（blocker / warning / info）は付与しない。section 順序が暗黙の優先度を表現する
- 推奨アクション語彙は固定。新規追加は SKILL.md 改訂で行う（Phase 2 でも語彙拡張はしない）
- `--deep` は明示時のみ有効。routine 実行で Phase 2 を走らせたい場合も `--deep` の明示が必須
