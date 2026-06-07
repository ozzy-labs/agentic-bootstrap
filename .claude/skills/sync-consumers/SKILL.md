---
description: skills / commons の更新を sync-targets.yaml に記載された 14 consumer リポへ並列に push し、PR auto-merge まで完結させる push 型同期スキル (drive 派生)。
argument-hint: "[--source=skills|commons] [--dry-run] [--concurrency N] [--merge] [--filter <repo,repo>]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, AskUserQuestion, Agent
---

# sync-consumers

`.agents/skills/sync-consumers/SKILL.md` を Read し、ワークフロー手順 (Phase 0 / Phase 1 / Phase Final-1 / Phase Final-2 / Phase Final-3) に従う。

**重要:** 本スキルは drive 派生のため、Phase Final-1 / Phase Final-2 の具体手順は `.agents/skills/drive/SKILL.md` を参照する形になっている。Phase Final-1 / Phase Final-2 を実行する際は **必ず drive SKILL.md も Read** し、6 軸検出 + recovery シーケンス + worktree cleanup の詳細手順を厳密に踏襲すること。本 skill 固有の追加軸 (Phase Final-1 軸 7) と追加制約 (Phase Final-2 の `cd <parent-worktree-root>` 必須化) は、drive 本体仕様に**上乗せ**する形で適用する。

## Claude Code 固有の追加事項

### 引数解析

`$ARGUMENTS` を解析し、以下のオプションを特定する:

- `--source=skills|commons` (既定 `skills`)
- `--dry-run` (既定 false)
- `--concurrency N` (既定 `min(4, target 数)`)
- `--merge` (既定 false)
- `--filter <repo,repo>` (省略時は `sync-targets.yaml` の全 target)

`sync-targets.yaml` の `source` フィールドと `--source` 指定が不一致なら Phase 0 で abort し、原因を表示する。

### Phase 0 の commons helper 未整備時の挙動

`commons/scripts/sync-consumers.sh` が見つからない、または実行権限が無い場合は **dry-run へフォールバック**し、以下の warning を表示する:

```text
⚠️ commons helper not available; falling back to --dry-run.
  Expected: commons/scripts/sync-consumers.sh (sub-issue #82, commons portion)
  Progress: <pending|in-review|merged>
```

ユーザーは sub-issue #82 (commons repo) の進捗を確認し、helper が利用可能になってから `--dry-run` を外して再実行する。

### 自律実行

Phase 0 から Phase Final-3 までは AskUserQuestion を使わずに進める。`--merge` 指定時の auto-merge polling も完全自律実行とする。

### subagent dispatch (Phase 1)

Phase 1 では `Agent` tool で各 target を並列実行する。drive オーケストレーションモードと同じ制約を**必ず prompt に明記**する:

- **isolation:** `"worktree"` (必須)
- **subagent_type:** `general-purpose`
- **prompt:** subagent から slash command は呼べないため、`.agents/skills/sync-consumers/SKILL.md` を Read させ、自 target について commons helper 呼び出し + 戻り値 JSON の組み立てを実行するよう指示する。`--merge` 指定時は auto-merge セット (+ 可能なら merged まで polling) を含めて完了させる
- **main への checkout 禁止:** 自 worktree branch (consumer clone 内含む) で完結する
- **Edit / Write の `file_path` 制約:** 自 worktree path で始まる absolute path に限定 ([Issue #77](https://github.com/ozzy-labs/skills/issues/77))
- **`--delete-branch` 禁止:** `gh pr merge --auto --squash` までに留める ([Issue #69](https://github.com/ozzy-labs/skills/issues/69))
- **scope 外波及チェック:** 該当しないため省略可 (本 skill の subagent は consumer 側 clone を触るのみで、本リポ側の symbol を追加しない)
- **戻り値:** SKILL.md 記載の JSON 形式で返す。`final_head_state` フィールドを **必ず含めて返させる** ([Issue #89](https://github.com/ozzy-labs/skills/issues/89) 観察強化)

### 観測性

- Phase 0 完了時に wave 構成 (target / 並列度 / dry-run / merge フラグ) を表示する
- `Agent` tool は最終結果のみを返すためストリーム的な中間報告は不可。親は wave 起動時刻 `<T>` を ISO 8601 で記録し、30 秒間隔で `gh pr list --author @me --state open --search "created:>=<T>" --json number,url,headRefName,title` を polling する。既知 PR との差分から新規 PR を検出して URL を即時表示する
- Phase Final-3 で集約レポートを出力する

### 中断時

いずれかのフェーズで中断した場合、AskUserQuestion で次のアクションを確認する:

- **「エラーを修正して再開する」** → 中断した Phase から再開
- **「中断する」** → 終了

target 単位の失敗は Phase Final-3 の集約レポートに含めて続行する (個別 target の failed は全体中断にしない)。

### 完了後

1. **`--merge` 指定時:** Phase Final-3 集約レポートを出力して終了する。auto-merge polling は各 subagent 内で完結している
2. **`--merge` 未指定時:** Phase Final-3 レポート出力後、AskUserQuestion を呼び出す
   - **「全 PR を一括マージする」** → 各 PR に対し順次 `gh pr merge --squash` を実行する (`--delete-branch` は付けない。Phase Final-2 cleanup で扱う)。全 PR が merged になった後、Phase Final-2 cleanup を `merge-ready` だった subagent worktree に対して再度実行する
   - **「個別に対応する」** → 終了する。`merge-ready` の worktree は残置されたまま。ユーザーがマージ後に `/health` 領域 #7 または手動で整理する
