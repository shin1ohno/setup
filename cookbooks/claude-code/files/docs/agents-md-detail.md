Load when a `~/.agents/AGENTS.md` rule points here for its origin, worked example, probe list or full rationale.

# AGENTS.md — detail and origins

Tool-agnostic companion of `~/.agents/AGENTS.md` (read by Claude Code and Codex alike). The summary keeps each rule's trigger, action and exceptions; this file keeps the incidents, examples and longer explanations.

## japanese-output-origins

hedge 規則（根拠か条件を示すときに限り「〜と考えられます」「〜かもしれません」を許し、校正では原文の推量の強さを保つ）の Origin: 2026-10-03 yomiyasu 比較・ユーザー決定。

専門外領域での「反証の入口」規則の理由: 断定を避けるだけでは、受け取った側が検算できない。Origin: 2026-09-10 —「私は経済の専門家ではないので間違ってる可能性を織り込んで評価して欲しいです」。

## codebase-investigation-local-clone

Remote code-search MCPs (Sourcegraph) silently truncate keyword result sets. Origin: 2026-08-18 reward-swap review — Sourcegraph missed 8/16 `SpecifyStageRate` call sites; user instruction.

## no-terminal-speculation

外部の自律ループ（launchd/cron/CI スケジューラ）への pickup 委任の liveness probe 例: kill-switch sentinel の有無・`launchctl list`・ログ最終行 timestamp。スケジュール実行ループに載る変更の手動起動手段の例: runner script・`--once`・`gh workflow run`・skill 直叩き。「次回 run で確認すること」「明朝の run で反映されます」は後送り禁止の対象。

Origin: 2026-09-12 — 明朝 run への委譲を 3 回書き、ユーザーが「今、collect run出来ますか」「今runして確認したらいいのでは」「今走らせてみて？」と 3 回押し戻した。2026-06-27 64f6c5ef — kill-switch ON + LaunchAgent 未ロードのまま pickup を約束。

## verify-functional-state

`systemctl is-active` is a deployment artifact; the functional check is the next-elapse from `systemctl status <name>.timer` / `list-timers`. `show --property=Trigger` is NOT a valid check — it prints empty for armed and dead timers alike (see `~/ManagedProjects/setup/.claude/rules/infrastructure.md`). Layer-specific examples: `~/ManagedProjects/setup/.claude/rules/infrastructure.md`, `~/.claude/docs/docker-compose.md`, `~/.claude/docs/tailscale.md`.

Origin: PR #253 → #257 → #259 — 3 iterations from artifact-shaped verification.

## step-by-step-verification

The user can stop at any step if assumptions diverge; running e2e from the first probe loses that off-ramp. Origin: 2026-05-11 — an e2e-first apply missed an IAM scope mismatch that probe 2 would have surfaced.

## domain-term-verification

Secondary summaries include meeting notes, a review deck, an AI-written digest page, a sibling document and a teammate's relay. Primaries for the same fact include the post analysis, the source PDF, the experiment dashboard and the document body. Procedure and verification commands: `~/.claude/docs/data-collection.md`.

Origin: 2026-05-19 — a Slack agent's wrong ATPU/ARPU definition was propagated into a dashboard. 2026-09-10〜12 — a review deck's "main metrics flat" was significantly negative in the post analysis (the conclusion inverted), and a sibling document's "0 for 3" was 0 for 5 and reached a chapter's central claim unchecked.

## event-mechanism-check

Origin: 2026-05-19 — S3→S5 was framed as user conversion, but the S5 reward is auto-granted.

## selection-bias-survey

Origin: 2026-05-19 — three rounds of Control proxy redesign came from post-hoc bias discovery.

## denominator-claim-source

並置の Origin: 2026-09-10 — 3 本 対 487 本を非対称注記つきで出荷、実測は 36% 対 41%。

分母なし提示と未検証仮説の Origin: 2026-06/07 zp-SHIN — 露出 2.35M を分母なしで提示（実際は介入群 11.6M の ~20%）、skill prose の未検証仮説「アプリ普及が不完全」が実測 75-92% と矛盾。

仮定係数の後送り注記: 仮定係数（リーチ率・分布・普及率）を表に置いてから「この数値の限界」を注記し実測を次ステップに回すのは違反（注記＋後送りは compliance ではない）。Origin: 2026-07-21 — 均一 18.4% リーチ仮定で SAM/SOM 表を出荷、実測したら年齢帯で最大 18 倍乖離。

増分更新の棚卸し Origin: 2026-07-21 — 裏取りパスで約 80 イベント表が黙って 20 行に縮小。

## state-archaeology

Example probes: `terraform state show`, `aws iam get-user-policy`, `pct config <existing-vmid>`, `cat cookbooks/<existing>/default.rb`. Origin: 2026-05-06 — CT 111 lost ~45 min to 2 blockers visible from a 2-min archaeology.

## verify-before-ask

Origin: 2026-04-28 weave session asked for an iPad UDID that `xcrun devicectl list devices` returned.

## existing-facility-probe

The secrets classifier blocks reading key *material*, not filename greps; the probe uses absolute paths so it works from any cwd. Config-at-source beats a new runtime layer: e.g. tune mac-sudo `timestamp_timeout=N` rather than writing a keepalive.

Origin: 2026-05-18 — GPG import re-implementation proposed while `cookbooks/gpg-backup` existed. 2026-06-15 — a `bin/apply` keepalive was created, then deleted in the next PR in favor of `timestamp_timeout`.

## capability-claims

General probe commands: `mise registry`, `brew info`, `<tool> --help | grep`, `pip index versions` / `npm view` / `cargo search`, `curl -fsI`. Origin: 2026-05-04 — a "yes mise pipx" claim hit 2 blockers, ~30 min pivot.

**Trigger timing.** Before building a wait or poll loop around a scheduler, read its run history (`gh run list --workflow <wf> --event schedule --json createdAt`). Origin: 2026-09-27 agent-pilot-sandbox — a 55-minute loop waited for an hourly cron while a daily cron in the same repo already showed 4h39m–5h01m delays in history readable at once; the hourly crons then ran twice each in about 10 hours.

**Side-effect probe for new CLI commands.** Run once and `find <likely-paths> -newer /tmp/sentinel -type f` (or `strace -e trace=openat,write`). Origin: 2026-05-11 — `aws login --remote` cache location unfindable → PR #339+#340 reverted.

**Structured response fields.** Examples: `guestsCanModify`, `permissions.canEdit`, `editable`, `can_*`. Origin: 2026-06-28 Calendar — asserted "only the organizer can reschedule" twice while `guestsCanModify=true` was already in the fetched event JSON; built an unnecessary hold-workaround + draft detour the user caught and reversed.

**社内サービス・業務システムの対応状況.** 実装は文書より先に動く。Origin: 2026-06 zp-SHIN — 対応状況を文書から断定し、ユーザーがコード読解を明示要求。

**決議状況クレーム.** Origin: 2026-07-06 / 07-22 — CRM 一次判定・割引送料を決定済みと誤提示、crit 指摘で全 Design Doc が Status=DRAFT と判明。

**決議の有効範囲.** Origin: 2026-07-29 — フェーズ限定の非適用決定を将来にわたる決定として分析ドキュメントに書き、ユーザー指摘（「そのフェーズでは適用しないという意思決定の記録を将来にわたる決定と読み違えたのでは」）で訂正。

## no-change-narration

Example of the violation: a heading like `打ち手（North Star を上に、制約対応を下に）`, "per your feedback I moved X above Y", "この節を最上位に移動". Origin: 2026-07 — a proposal restructured per crit feedback embedded the reviewer's reordering instruction verbatim into a section heading.
