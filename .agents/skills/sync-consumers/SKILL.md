---
name: sync-consumers
description: skills / commons の更新を sync-targets.yaml に記載された 14 consumer リポへ並列に push し、PR auto-merge まで完結させる。drive の Phase Final 仕様（worktree drift 検出 + cleanup）を踏襲する push 型同期スキル。
---

# sync-consumers - skills/commons の consumer 一括同期

`sync-targets.yaml` で宣言された consumer リポ群 (現在 14 件) に対し、`commons/scripts/sync-consumers.sh` を介して clone → bump → sync → branch/commit/PR まで並列実行する。各 target は独立 subagent (worktree 隔離) で進め、`--merge` 指定時は PR auto-merge まで仕掛けて終了する。

drive 派生スキルとして実装されており、subagent dispatch・並列度制御・Phase Final (worktree drift detection / cleanup / cross-cutting audit) は drive と同等の仕組みを共有する。重複保守を避けるため、Phase Final-1 / Phase Final-2 の具体手順は drive SKILL.md を参照する形を取る。

## 前提

- **sync-targets.yaml** が repo root に存在し、`schemas/sync-targets.schema.json` (draft 2020-12) に準拠していること
- **commons helper** (`commons/scripts/sync-consumers.sh`) が利用可能であること。helper は sub-issue #82 (commons portion) で実装される。本 skill は helper 完成までは **`--dry-run` 動作のみ**サポートする。helper 未整備のリポで `--dry-run` 以外を指定した場合、Phase 0 で警告を出して dry-run にフォールバックする
- `gh` CLI が認証済みで、target consumer 全 14 リポに対して push / PR 作成権限を持つこと

## 入力解析

### オプション

- `--source=skills|commons`: 同期元を指定する。既定は `skills`。`sync-targets.yaml` の `source` フィールドと不一致なら Phase 0 で abort
- `--dry-run`: 実 PR を作成せず、各 target に対する想定処理を表示する (commons helper 未整備でも動作)
- `--concurrency N`: 並列度を上書きする (既定 `min(4, target 数)`、N > 8 は警告のみ)
- `--merge`: 各 subagent で `gh pr merge --auto --squash` を実行し、auto-merge 完了 / polling まで進める
- `--filter <repo,repo>`: カンマ区切りで対象 consumer を絞り込む (例: `--filter ozzy-labs/agentyard,ozzy-labs/handbook`)。値は `owner/repo` 形式、`sync-targets.yaml` に未掲載の repo は警告して無視する

## Phase 0: schema validation + target 展開

1. **schema validation:**

   ```bash
   pnpm dlx ajv-cli@5 validate \
     -s schemas/sync-targets.schema.json \
     -d sync-targets.yaml \
     --strict=true \
     --spec=draft2020
   ```

   - 失敗時は abort
   - `pnpm dlx` を使う理由: 本 skill は sub-issue #82 (commons portion) で `ajv-cli` が devDeps に登録される前後どちらの状態でも動作する必要があるため。`pnpm exec` だと未導入時に command-not-found になる。`pnpm dlx ajv-cli@5` は network fetch するため offline では別途事前 install が必要 (CI / lefthook が `ajv-cli` を pin している場合はそちらが優先される)

2. **YAML パース + filter 適用:**
   - `sync-targets.yaml` を読み込む (`js-yaml` 等。本 skill では `pnpm dlx js-yaml` ではなく `yq` または node のスクリプトを Bash 経由で呼ぶ)
   - `disabled: true` の target は skip し、`disabled_reason` を warning として記録
   - `--filter` 指定があれば対象を絞り込む
   - 残った target が 0 件なら abort

3. **commons helper 存在確認:**
   - `command -v sync-consumers.sh` / `test -x <commons-path>/scripts/sync-consumers.sh` で helper を探す
   - 未整備かつ `--dry-run` 未指定なら **dry-run にフォールバック** し warning を出す (commons sub-issue 完成までの暫定挙動)

4. **wave 構成の表示:**

   ```text
   sync-consumers 開始:
     Source:       skills (sync-targets.yaml)
     Targets:      14 件 (filter: -)
     並列度:        4 (既定: min(4, 14))
     --merge:      有効
     --dry-run:    無効
     Wave 1 (全 target 並列):
       ozzy-labs/agentyard, ozzy-labs/feedradar, ozzy-labs/handbook, ...
   ```

   target 間には依存関係がないため、全 target を 1 wave で並列実行する。並列度を超える分は semaphore 方式で空きスロット待ち。

## Phase 1: subagent dispatch (Wave 1)

各 target に対し `Agent` tool で subagent を起動する。drive オーケストレーションモードと同じ dispatch ルールに従う。

### 共通制約 (drive と同じ)

- **isolation:** worktree 隔離 (必須)
- **subagent_type:** `general-purpose`
- **並列起動:** 1 メッセージ内に複数 tool call を並べる
- **main への checkout 禁止:** subagent は自 worktree branch (consumer clone 内) で完結する
- **`--delete-branch` 禁止:** `gh pr merge --auto --squash` までに留める。ローカル branch / worktree の整理は親側 Phase Final で一括処理
- **Edit / Write の `file_path` 制約:** subagent の Edit / Write tool に渡す `file_path` は自 worktree path で始まる absolute path に限定 ([Issue #77](https://github.com/ozzy-labs/skills/issues/77))

### subagent prompt (target ごと)

各 subagent に対し以下を委譲する:

1. **commons helper の呼び出し:**

   ```bash
   commons/scripts/sync-consumers.sh \
     --source <skills|commons> \
     --target <owner/repo> \
     [--dry-run] \
     [--auto-merge] \
     [--branch-prefix <prefix>] \
     [--base-branch <branch>] \
     [--ssot-sha <sha>] \
     [--source-repo <local-path>]
   ```

   オプション詳細:
   - `--source`: `skills` または `commons` のいずれか必須。同期元 repo を指定
   - `--target`: `owner/repo` 形式必須。target consumer
   - `--dry-run`: 実 PR を作成せず、想定処理を JSON で stdout に
   - `--auto-merge`: `gh pr merge --auto --squash` まで実行 (`--delete-branch` は付けない)
   - `--branch-prefix`: PR ブランチ名の prefix (既定 `chore/sync-<source>`)。`<prefix>-<short-sha>` の形に展開される
   - `--base-branch`: clone 時の checkout 対象 (既定 `main`)
   - `--ssot-sha`: SOURCE 側の HEAD SHA を明示指定 (省略時は `git -C <source-repo> rev-parse HEAD`)
   - `--source-repo`: SOURCE repo のローカル clone path (省略時は `$HOME/github/ozzy-labs/<source>`)

   helper は内部で次を実行する:
   - target consumer を一時ディレクトリに clone (shallow, `--depth 50`)
   - `.commons/sync.yaml` の `skills_commit` (skills 同期時) または `commit` (commons 同期時) を最新 SHA に bump
   - `sync.sh` / `sync-skills.sh` を実行して `dist/` を consumer 側に反映
   - feature branch を作成し commit
   - `gh pr create` で sync PR を作成
   - `--auto-merge` 指定時は `gh pr merge --auto --squash` を実行 (`--delete-branch` は付けない)

2. **helper の戻り値 JSON (helper script 自身が stdout に出す):**

   ```json
   {
     "target": "ozzy-labs/<repo>",
     "branch": "<branch-name>",
     "pr_url": "<URL or null>",
     "pr_number": <N or null>,
     "status": "merged" | "merge-ready" | "auto-merge enabled" | "no-change" | "dry-run" | "failed",
     "error": "<message or null>"
   }
   ```

   - `--dry-run` の場合は `status: "dry-run"` を返し、追加で `would_run: [...]` フィールドに想定処理を列挙する (subagent 側で表示用に解釈)
   - 実 sync 経路で commit すべき変更がなければ `status: "no-change"`
   - PR 作成成功 + auto-merge 即時成功なら `status: "merged"`
   - PR 作成成功 + auto-merge enable (CI 待ち) なら `status: "auto-merge enabled"`
   - PR 作成成功 + auto-merge 試みなし or 失敗なら `status: "merge-ready"`
   - エラー (clone 失敗 / sed 失敗 / push 失敗等) は `status: "failed"` + `error` メッセージ、exit code 1

3. **subagent の戻り値 JSON:**

   subagent は helper の戻り値を受けて、以下の形で自身の戻り値を組み立てる:

   ```json
   {
     "target": "ozzy-labs/<repo>",
     "branch": "<branch-name>",
     "pr_url": "<URL or null>",
     "pr_number": <N or null>,
     "status": "merged" | "auto-merge enabled" | "merge-ready" | "no-change" | "skipped" | "failed",
     "no_change_reason": "<string if no-change>",
     "error": "<message if failed>",
     "final_head_state": {
       "symbolic_ref": "<git symbolic-ref HEAD>",
       "rev_parse_HEAD": "<sha>",
       "status_short": "<git status --short>"
     }
   }
   ```

   - `final_head_state` は subagent が自 worktree の HEAD 状態を申告するフィールド ([Issue #89](https://github.com/ozzy-labs/skills/issues/89) で drive 本体に既に採用済み)。helper の戻り値には含まれないため、subagent 側で `git symbolic-ref HEAD` / `git rev-parse HEAD` / `git status --short` を実行して埋める
   - subagent 側で「helper の `dry-run` 状態」を `no-change` 系として扱うか、`skipped` として扱うかは親側の選択 (本 skill では `skipped` は `--filter` 等で除外された target に使用)
   - `no_change_reason` は helper の no-change を受けた場合、または pinned / disabled を受けた場合の理由を string で記録

### 観測性

- 親は wave 起動時刻 `<T>` を ISO 8601 で記録し、30 秒間隔で `gh pr list --author @me --state open --search "created:>=<T>" --json number,url,headRefName,title` を polling
- 既知 PR との差分から新規作成 PR を検出し URL を即時表示

### wave 完了待ち

- 全 subagent 完了で wave 完了
- `--merge` 指定時は各 subagent が auto-merge セットまたは merged まで進めるため、wave 完了 = 全 target が auto-merge 状態以上

## Phase Final-1: 親 worktree 整合性チェック

drive Phase Final-1 と同等。`.agents/skills/drive/SKILL.md` の Phase Final-1 仕様 (7 軸検出 + `final_head_state` 交差確認 + `update-ref` ベース recovery シーケンス) を踏襲する。

### 軸 7 補足 (drive 本体に取り込み済み)

drive Phase Final-1 の軸 7 は本 skill で先行導入した後、[Issue #89](https://github.com/ozzy-labs/skills/issues/89) ([PR #93](https://github.com/ozzy-labs/skills/pull/93)) で drive 本体にも取り込まれた。本 skill では drive を参照するだけで重複保守はしない。

**軸 7. subagent worktree が `refs/heads/main` を握っていないか:**

```bash
# 今 run で起動した subagent worktree について
for WT in <subagent_worktree_paths>; do
  SUBAGENT_HEAD=$(git -C "$WT" symbolic-ref HEAD 2>/dev/null || echo "<detached>")
  if [ "$SUBAGENT_HEAD" = "refs/heads/main" ]; then
    echo "⚠️ subagent worktree $WT is holding refs/heads/main (drift source)"
  fi
done
```

subagent が自 worktree から `git switch main` 等で意図せず main ref を握ってしまうと、親の `refs/heads/main` ref が固定されて Phase Final-1 の軸 5 (`refs/heads/main == origin/main`) が更新できなくなる。本軸で先に検出しておくと、recovery シーケンスを実行する前にユーザーへ「該当 subagent の worktree から先に外す必要がある」と提示できる。

検出された場合は warning に追加し、軸 5 の recovery 前に該当 subagent worktree の cleanup (Phase Final-2) を優先するよう順序を入れ替える。

## Phase Final-2: subagent worktree cleanup

drive Phase Final-2 と同等。`.agents/skills/drive/SKILL.md` の Phase Final-2 仕様 (status 別の cleanup 分岐 + subshell 化 + `worktree-agent-<id>` synthetic branch の削除確認) を踏襲する。

### `cd <parent-worktree-root>` 必須化 (drive 本体に取り込み済み)

各 `git worktree remove -f -f <path>` 実行前に **必ず親 worktree のルートに `cd` してから** コマンドを呼ぶ。本制約は本 skill で先行導入した後、[Issue #90](https://github.com/ozzy-labs/skills/issues/90) ([PR #93](https://github.com/ozzy-labs/skills/pull/93)) で drive 本体にも取り込まれた。本 skill では drive を参照するだけで重複保守はしない。

```bash
PARENT_ROOT=<親 worktree の絶対 path>
for WT in <subagent_worktree_paths>; do
  # subshell で cd して隔離。subagent 由来の cwd 残骸に影響されない
  (
    cd "$PARENT_ROOT"
    BRANCH=$(git worktree list --porcelain | awk -v p="$WT" '...')
    git worktree remove -f -f "$WT"
    git branch -D "$BRANCH"
  )
done
```

理由: subagent の worktree 内に親 shell の cwd が残っていると、`git worktree remove` の解釈が「自身の所属する worktree を削除しろ」となり `fatal: cannot remove the current working directory` で失敗する。subshell + 明示 `cd` で確実に親側から実行することで回避する。

### no-change target の扱い

commons helper が `status: no-change` を返した target (consumer 側に diff が無く PR が作成されなかったケース) は **cleanup 対象**。`merged` と同じく cleanup ロジックを適用する。

## Phase Final-3: 集約レポート

drive Phase Final-4 と同様、整合性チェック・worktree cleanup・cross-cutting audit の結果を踏まえて出力する。target 数が固定 (14) のため、success / no-change / failed の集計を明示する。

```text
sync-consumers 完了 (10/14 merged, 2 no-change, 1 merge-ready, 1 failed):
  ozzy-labs/agentyard         | PR #234 | merged
  ozzy-labs/feedradar         | PR #56  | merged
  ozzy-labs/handbook          | -       | no-change
  ozzy-labs/create-agentic-app| PR #12  | merge-ready  (auto-merge blocked: branch protection)
  ozzy-labs/opshub            | -       | failed       (clone error: rate-limit)
  ...

集計:
  merged:           10
  no-change:        2
  merge-ready:      1
  failed:           1
  並列度:           4
  worktree cleanup: 12/14 removed (2 preserved: 1 merge-ready, 1 failed)
  cross-cutting:    none
```

## 失敗 semantics

| 状況 | 扱い | 後続 target への影響 |
|---|---|---|
| 個別 target の clone / helper 失敗 | failed | 影響なし (他 target は継続) |
| schema validation 失敗 | abort (Phase 0) | 全 target 中断 |
| commons helper 未整備 (`--dry-run` 未指定時) | dry-run へフォールバック | 全 target が dry-run になる |
| auto-merge セット失敗 (branch protection 等) | merge-ready | 影響なし |

## 注意事項

- `.env` ファイルは読み取り・ステージングしない
- `gh` CLI が未認証なら Phase 0 でエラー報告して中断する
- マージはデフォルトでは行わない。`--merge` 指定時のみ auto-merge を試行する
- 並列度 8 超過は警告のみ。GitHub Actions 同時実行枠 / API rate limit / コストに注意
- commons 側の対となる skill 実装は別 PR (sub-issue #84、commons repo) で進行中
- `commons/scripts/sync-consumers.sh` の最終仕様は sub-issue #82 (commons portion) で確定する。本 skill の subagent prompt 内の引数列は確定後に再確認する
