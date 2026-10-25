Load when a `~/.claude/CLAUDE.md` rule points here for its origin, worked example or full rationale.

# CLAUDE.md — detail and origins

The always-loaded summary in `~/.claude/CLAUDE.md` keeps each rule's trigger, action and exceptions. This file keeps the incidents and examples behind them.

## zsh-user-blocks

bash 専用書式は静かに壊れる — `read -rs -p 'x: ' V` は zsh では `-p` が「コプロセスから読む」と解釈され、`zsh:read:1: -p: no coprocess` を出したうえで**変数が空のまま後続が実行される**（空の資格情報で API を叩き、認証エラーの原因が見えなくなる）。zsh は `read -rs "V?x: "`。他に配列 1 始まり・glob 失敗時 `nomatch`。

Origin: 2026-09-08、Linear API キー入力ブロックで実際に踏み、ユーザー指摘で発覚。

## plan-mode-misclassified

Origin: 2026-05-01 AstroNvim ^5→^6 missed cross-machine cleanup — a plugin lockfile bump with runtime steps was treated as trivial and skipped plan mode.

## dual-managed-files

Why diff the deploy copy before hand-editing it: when deploy is waiting on an apply, editing on top of it produces a hybrid that carries the new section and is missing the older one. Origin: 2026-09-16 — `rules/git-commit.md` ended up in exactly that state.

## user-reported-completion-probe

Origin: 2026-05-06 retro — twice, work was built on PRs that had not actually merged. 2026-09-27 — a re-sent `! bin/register-memory-mirror` arrived with no output, "Registration has run" was written before the probe, and the probe then showed Hydra 404 / SSM ParameterNotFound.

## progress-ledger-stale-facts

Example probes for re-checking a recorded environmental constraint: `ssh -o ConnectTimeout=5 root@<host> hostname`, `aws sts get-caller-identity --profile P`, `ping -c1 -W2 <IP>`.

Snapshot-class sources beyond progress docs: auto-memory files, skill / runner-prompt permission notes, recorded "access-OK" claims, and an autonomous bot's own issue-tracker diagnosis — self-heal / monitor-alert root-cause hypotheses are snapshots too (the self-heal bot's diagnosis was re-verified live 4 days later before acting, 2026-07-11).

Why both copies must be written back: updating only one copy leaves the next scheduled run re-reading the stale claim (observed 2026-07: reversal seen 7/3, written back 7/6; a sibling run skipped a merge-ready PR within the hour on the stale note). A run log, a sweep JSON, a report or an outbox draft does not count as a write-back because the next run never reads it and the same stale claim is re-served.

Origin: 2026-06-13 — a stale plan.md ssh-fail line was propagated unverified.

## background-batch-progress

Origin: 2026-07 sessions aa4b0e75 (status? asked 3 times) and 29d690f1 (30 minutes silent).

## plan-question-batching

Discovering the architectural-split option after the user already answered inline-only forces a 2-turn plan revision. Origin: 2026-05-11 CLAUDE.md trim — the split option surfaced too late.

## deliverable-to-file

This is not the same rule as `sub-agents.md`'s "Synthesis Stage — Pass Data by Path", which governs agent-to-agent handoff; this one governs the user-facing deliverable. A relative path does not resolve against the user's cwd — cf. `~/ManagedProjects/setup/.claude/rules/shell.md` "User-run block self-containment".

Origin: 2026-07-22〜07-30 — 「ファイルに書き出して」/「フルパスで」を 8 セッションで 11 回言わせ、うち 1 件は同一セッション 2 回目の「ファイルに書き出してって言いませんでしたか？」だった。

## medium-shape

Origin: recurred in two sessions on 2026-09-10 (「親メッセージには結論を、その他の情報はレスとしてつけて」).

## self-review-pass

The shared Writing rules apply "while writing"; the self-review pass is a mandatory pass over the finished draft before it reaches the user — not optional polish. The file-vs-inline trigger coincides with the "over ~30 lines / will be reused → write it to a file" rule, so there is no per-case judgement.

Origin: issue #640 (inline reports moved to self-apply); 2026-09-10 — three sessions asked whether `/writing` had been applied at all (「文章としてとても読みにくいですね」), so file-bound artifacts went back through the skill.
