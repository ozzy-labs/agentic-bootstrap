---
description: Issue または指示から実装・PR 作成・セルフレビュー・修正を自動で回し、merge-ready な PR を出す。単一/複数の Issue/PR と明示依存記法に対応。オプションでマージまで実行可能。
argument-hint: <#N | #N,#N | #N-N | instruction> [--merge] [--concurrency N] [--review=quick|final-deep|deep]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, WebSearch, WebFetch, AskUserQuestion, Agent
---

# drive

`.agents/skills/drive/SKILL.md` を Read し、ワークフロー手順に従う。

**重要:** 各フェーズでは対応するスキルの SKILL.md を Read して**ワークフロー手順のみ**を実行する。読み込んだ SKILL.md 内の「次のアクション提案」セクションおよび「完了報告」セクションは**すべて無視**する。フェーズ間の遷移は本スキルが制御する。

## Claude Code 固有の追加事項

### 入力解析

`$ARGUMENTS` を解析し、target リスト（Issue/PR/指示）と依存記法、オプション（`--merge`, `--concurrency N`, `--review=<mode>`）を特定する。

- target が 1 件かつ依存記法（`->`）なし → 単一モード
- target が 2 件以上、または依存記法あり → オーケストレーションモード

`--review` の取り扱い:

- 既定は `quick`
- 単一モード: `quick` / `final-deep` / `deep` をすべて受け付ける
- オーケストレーションモード: `--review=quick` を強制し、`final-deep` / `deep` 指定時は警告を表示して `quick` にフォールバックする（コスト管理）

### 自律実行

計画承認を含め、マージ処理（またはマージ確認）まで AskUserQuestion を使用しない（完全自律実行）。

### subagent dispatch（オーケストレーションモード）

オーケストレーションモードでは `Agent` tool で各 target を並列実行する:

- **isolation:** `"worktree"`（必須）
- **subagent_type:** `general-purpose`
- **prompt:** subagent から slash command は呼べないため、`.agents/skills/drive/SKILL.md` を Read させ、target #N について単一モードのワークフロー（Phase 1-5）を実行するよう指示する。`--merge` 指定時は Phase 4 まで完了し、自 PR の merged まで polling して終了させる。最終結果は JSON で返させる
- **main への checkout 禁止（必ず prompt に明記）:** subagent は自 worktree branch で完結する。`git checkout main` / `git switch main` / `git checkout HEAD~` 等で HEAD を移動させない。worktree は親側で削除されるため main へ戻す必要はない。これを怠ると共有 git directory 経由で親 worktree の `HEAD` / `index` が汚染される（[Issue #66](https://github.com/ozzy-labs/skills/issues/66) 参照）
- **`--delete-branch` 禁止（必ず prompt に明記）:** subagent が auto-merge をセットする際、`gh pr merge --auto --squash` までに留め、`--delete-branch` は付けない。自 worktree が握る branch を削除しようとして `fatal: '<branch>' is already used by worktree at ...` エラーになる。ローカル branch / worktree の整理は親側 Phase Final で一括処理する（[Issue #69](https://github.com/ozzy-labs/skills/issues/69)）
- **scope 外波及チェック（必ず prompt に明記）:** subagent が enum / field / CLI flag を追加した場合、リポ全体で対応する help 文字列・エラーメッセージ・サンプル/docs を grep し、同期を確認する。同期されていなければ可能なら自 PR に含める。自 scope を明確に超える場合は戻り値 JSON の `cross_cutting_gaps: string[]` フィールドに `<file>:<line> — <symbol> not synced` 形式で記録し、親の Phase Final-3 audit に集約する（[Issue #70](https://github.com/ozzy-labs/skills/issues/70)）
- **依存元 wave がある場合のベースブランチ:**
  - `--merge` 指定 + 依存元が merged → main から作成
  - `--merge` 指定 + 依存元が auto-merge enabled（未マージ）→ main を pull してから作成（取り込まれていれば main ベース、未取り込みなら依存元 headRefName ベース）
  - `--merge` 未指定 → 依存元 PR の headRefName をベースに stacked PR として作成
- **並列起動:** 同一 wave 内の独立 subagent は **1 メッセージ複数 tool call** で並列起動する
- **並列度:** `min(4, wave 内タスク数)`、`--concurrency N` で上書き、8 超は警告のみ
- **wave 内タスク数 > 並列度:** semaphore 方式で空きスロット待ち（先に起動した subagent の完了を待ってから次を起動）

### 観測性

- Phase 0 完了時に wave 構成と target リストを表示する
- `Agent` tool は最終結果のみを返すためストリーム的な中間報告は不可。親は wave 起動時刻 `<T>` を ISO 8601 で記録し、30 秒間隔で `gh pr list --author @me --state open --search "created:>=<T>" --json number,url,headRefName,title` を polling する。既知 PR との差分から新規 PR を検出して URL を即時表示する
- Phase Final で集約レポートを出力する

### 中断時

いずれかのフェーズで中断した場合、AskUserQuestion で次のアクションを確認する:

- **「エラーを修正して再開する」** → 中断したフェーズから再開
- **「中断する」** → 終了

オーケストレーションモードで一部 task のみ失敗の場合は、Phase Final レポート出力後に AskUserQuestion で再開対象を確認する。

### 完了後

#### 単一モード

1. **`--merge` 指定時:** Phase 4 の手順に従いマージを実行し、結果を報告して終了する
2. **`--merge` 未指定時:** AskUserQuestion を呼び出す（`answers` パラメータは設定しない）
   - **「PR をマージする」** → `gh pr merge --squash --delete-branch` でマージを実行し、結果を報告する
   - **「追加の変更を行う」** → 終了する

#### オーケストレーションモード

1. **`--merge` 指定時:** 各 subagent が自 PR のマージまで完了させているため、Phase Final 集約レポートを出力して終了する
2. **`--merge` 未指定時:** Phase Final レポート出力後、AskUserQuestion を呼び出す
   - **「全 PR を一括マージする」** → 各 PR に対し順次 `gh pr merge --squash --delete-branch` を依存順に実行する。すべての PR が merged になった後、Phase Final-2 cleanup を **`merge-ready` だった subagent worktree に対して再度実行する**（マージ完了で cleanup 条件 `merged` を満たすようになるため）。cleanup 結果を追加レポートとして出力する
   - **「個別に対応する」** → 終了する。`merge-ready` の worktree は残置されたまま。ユーザーがマージ後に `/health` 領域 #7 または手動で整理する
