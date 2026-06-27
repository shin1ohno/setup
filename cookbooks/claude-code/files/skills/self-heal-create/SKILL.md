---
name: self-heal-create
description: |
  self-heal observability ループの Layer 2-A（issue 作成）。CT111 observer が ES の
  self-heal-state インデックスに書く open/resolved 状態を、shin1ohno/setup の GitHub issue と
  同期する。ES で open かつ未 issue のものを issue 化、ES で消えたものを close + comment、
  needs-human は close しない。同期ロジックは決定的な集合演算なので純シェル `self-heal-create.sh`
  が実装の真実源。この skill はそれを実行して結果を要約するだけ（LLM 判断なし・読み取り専用）。
  「self-heal create」「self-heal issue を立てる」「fleet alert を issue 化」「self-heal 同期」でトリガー。
  対は self-heal-resolve（issue を解決する loop）。
user-invocable: true
---

# self-heal-create — fleet alert → GitHub issue 同期（純シェルの薄い wrapper）

ES `self-heal-state`（observer が書く真実源）と `shin1ohno/setup` の open self-heal issue を、
`sha1(dedup_key)` marker による集合 diff で同期するだけの loop。**検知はしない**（observer の責務）。
**修正もしない**（self-heal-resolve の責務）。

**同期ロジックは決定的な集合演算であり LLM の判断を要しない**。実装は純シェル
`cookbooks/self-heal-loops/files/self-heal-create.sh`（fleet では `/usr/local/bin/self-heal-create.sh`）が
単一の真実源。この skill はそのスクリプトを実行し、出力された 1 行サマリを報告するだけ。

設計: `docs/self-heal-github-issues-plan.md`、`~/self-heal-observability-loop-design.md`（Layer 2）。

## 不変の安全境界（スクリプトが強制・人間向けに再掲）

1. **read-only**: ES `self-heal-state` は GET のみ（書くのは observer）。
2. 対象は **`shin1ohno/setup` の `self-heal` ラベル issue のみ**。
3. **コードを触らない・PR を作らない・merge しない**。issue の open/close と comment だけ。
4. **marker 無し issue に触れない**（body に `<!-- self-heal-key:... -->` が無い issue は対象外）。
5. **`self-heal-needs-human` の open issue は close しない**（人間が見るべき状態）。
6. ES 到達不可・elastic pw 取得不可なら **何もせず STOP**（誤って全 issue を close しない。
   「空≠unreachable」: ES 到達かつ open 0 件は正常な空＝全 resolved として RESOLVED 同期へ進む）。

## 手順

このスクリプトを実行し、stdout のサマリ 1 行をそのまま報告する:

```bash
/usr/local/bin/self-heal-create.sh
```

副作用なしで diff を確認したいとき（手動運用・調査時）は dry-run:

```bash
SELF_HEAL_DRY_RUN=1 /usr/local/bin/self-heal-create.sh
```

スクリプト未配置の環境（cookbook 未適用）では、リポジトリ内の
`cookbooks/self-heal-loops/files/self-heal-create.sh` を直接実行してよい。

サマリ形式: `created=N reopened=R closed=M continuing=K`（+ `skipped_close`/`skipped_null`/`failures`）。
差分ゼロなら `in sync — no changes`。STOP した場合はその理由（elastic pw / ES unreachable）を報告する。

## 設定（env で上書き可、既定値はスクリプトが所有）

`SELF_HEAL_REPO` / `SELF_HEAL_LABEL` / `SELF_HEAL_NEEDS_HUMAN_LABEL` / `SELF_HEAL_ES_HOSTS` /
`SELF_HEAL_ES_CA` / `SELF_HEAL_ELASTIC_PW_SSM` / `SELF_HEAL_AWS_PROFILE` / `SELF_HEAL_AWS_REGION` /
`SELF_HEAL_STATE_INDEX` / `SELF_HEAL_DRY_RUN`。既定値は `self-heal-create.sh` 冒頭の config 節を参照。

## 自動運転

fleet では `cookbooks/self-heal-loops` の cron.d が `self-heal-create-run.sh`（flock/timeout/
kill-switch 付き wrapper）経由で 2 分毎に `self-heal-create.sh` を直接実行する（claude 起動なし）。
この skill は手動・対話実行用の入口。
