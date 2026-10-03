---
name: writing
description: Document creation and proofreading based on Pyramid Principle + marginal utility. Supports both new creation and editing of existing text.
user-invocable: true
---

# Writing Skill

## Argument Parsing

Treat the invocation arguments (the user's request text) as the task content. If omitted, ask the user for input (use a question tool if available, otherwise write numbered options in the body; Claude Code: AskUserQuestion / Codex: request_user_input).

**Template keywords**: if the invocation arguments start with `dvq` or `rfc`, load the corresponding template from `~/.agents/skills/writing/templates/` and use it as structural guidance in Step 1. Strip the keyword from the arguments before passing the remainder as the task content.

- `dvq [topic]` — strategic vision document (DVQ template)
- `rfc [topic]` — technical decision document (RFC template)

## Preparation: Load Personas and Templates

Read the following 2 files (Claude Code: Read tool):

1. `~/.agents/skills/writing/personas/document-writer.md` - Writer persona
2. `~/.agents/skills/writing/personas/marginal-utility-editor.md` - Editor persona

If a template keyword was detected, also read the matching template:
- `~/.agents/skills/writing/templates/dvq.md` for `dvq`
- `~/.agents/skills/writing/templates/rfc.md` for `rfc`

**Japanese language gate**: judge whether the prose you will write or edit is primarily Japanese (auto-detect from the task content / target document — English identifiers or code snippets inside a Japanese document still count as Japanese; skip for English documents). If Japanese, also read the AI-slop references:
- `~/.agents/skills/writing/references/phrases.md` - banned vocabulary
- `~/.agents/skills/writing/references/structures.md` - structural anti-patterns (病理①〜③ are sections 1〜3)
- `~/.agents/skills/writing/references/examples.md` - before/after contrast cases

A Japanese document also gets the machine checks in Step 3b: `scripts/content_diff.py` (numbers and terms added or changed by the rewrite) and `scripts/slop_scan.py` (病理①②③ findings). `content_diff.py` runs for English documents too; `slop_scan.py` is Japanese-only.

## Workflow

Execute 3 steps sequentially, then the Step 3b checks. Each step is delegated to an independent sub-agent if sub-agents are available (Claude Code: Agent tool); otherwise execute the step in this same session, using the step's persona, references and prior-step output as its working context.

Before launching each step (the sub-agent call or the in-session execution), emit one status line to the user (e.g. 「設計中（Step 1/3）…」「執筆中（Step 2/3）…」「編集中（Step 3/3）…」「検査中（Step 3b）…」). When the Step 3 decision sends the work back to Step 1, name the cycle (「Step 3 の判定により Step 1 へ戻ります（cycle 2/3）」). This pipeline is intentionally synchronous, so the progress line is this skill's own responsibility, not the background-agent tracking rule's.

**Proofreading mode — what outranks everything else.** When the task is editing someone else's existing text, two rules come before every other instruction in this skill, the personas and the references: (1) 意味 4 点保持 — the 主張, 比重, 言い切りの強さ and 文の働き of each sentence stay as the source has them; (2) 不増補 — no number, cause, condition, actor, proper noun, example or term the source does not already state. Removing a tell never justifies breaking either. Facts the edit would need go to 「書き手に確かめたい点」 instead of the text. Neither rule protects padding: an unbacked superlative, a template opener or an empty closer carries no 主張, so delete it outright rather than softening it into a milder twin — 不増補 forbids adding, never cutting (editor persona §5, "What the precondition protects").

### Step 1: Plan (Structure Design)

Delegate to a sub-agent if available, otherwise execute in this session (Claude Code: Agent tool, subagent_type: "general-purpose"):

- Persona: include document-writer content in the prompt
- Instructions:
  - Analyze the task and determine mode (new creation or proofreading). In proofreading mode, state the two overriding rules above in the plan so every later step inherits them
  - If a template was loaded, use its structure as the starting point instead of designing from scratch
  - Identify the reader: who they are, what they already know, and what decision or action this document supports
  - Design structure based on Pyramid Principle: conclusion (1 sentence) → arguments (MECE-grouped) → evidence/data
  - Verify each argument answers "why?" or "how?" from the conclusion
  - Keep hierarchy to 3 levels or fewer
  - Decide document format (short / medium / long)

### Step 2: Write (Drafting)

Delegate to a sub-agent if available, otherwise execute in this session (Claude Code: Agent tool):

- Persona: include document-writer content in the prompt
- Pass the structure design from Step 1 as prior context
- Instructions:
  - Write the document following the structure design
  - State the conclusion first
  - Open each paragraph with a topic sentence
  - Use narrative prose (minimize bullet points)
  - Use concrete numbers and facts instead of adjectives and adverbs — only the ones the user supplied; a missing fact becomes a 「書き手に確かめたい点」 line, never an invented figure
  - Output the completed draft only

### Step 3: Edit (Marginal Utility Editing)

Delegate to a sub-agent if available, otherwise execute in this session (Claude Code: Agent tool):

- Persona: include marginal-utility-editor content in the prompt. **If the document is Japanese, ALSO include the full contents of `references/phrases.md`, `references/structures.md`, and `references/examples.md` in the prompt** — sub-agents do not share the orchestrator's Read cache, so these must be re-injected exactly like the persona, not merely read in Preparation.
- Pass the draft from Step 2 (in proofreading mode, also the original text, so the editor can check the 4 points against it)
- Instructions:
  - Verify Pyramid Principle structure (conclusion first, topic sentences, MECE grouping, hierarchy depth)
  - Apply marginal utility test (evaluate each sentence's reason to exist against the intended reader)
  - Check expression (adjectives → numbers only where the number is already in the source or supplied material, passive → active voice where the actor is already named, eliminate "you can"/"there is" padding)
  - **Reader-level adaptation**: if the identified reader is non-technical, flag every technical term that lacks a definition on first use
  - **Scannability**: no paragraph exceeds 5 sentences; headings contain the key conclusion word (not vague labels); parallel grammatical structure in any remaining lists
  - **Japanese AI-Slop Check** (Japanese documents only): apply the editor persona's `### 5. Japanese AI-Slop Check` using the injected references. Hold the 意味 4 点保持 precondition first. Run the 5-axis 採点 (立場/リズム/主体性/具体性/削減, 1–10, report EACH axis sub-score; 具体性 is scored within the source — added numbers earn nothing), then repair in priority order 立場→主体（病理①）→構造（病理②③ ほか）→語彙→記号 (fixing 記号 before 立場/主体 leaves the slop intact). Apply the cluster rule (a single isolated tell is not slop) and the persona's exceptions (含み, 定着した慣用句, 評価を担う「重要なのは」, 意味を担う否定, 文字どおりの用法).
  - Check information volume (body max 6 pages; excess to appendix)
  - Output editing report (the persona's Report fields: 5 軸採点表, 書き手に確かめたい点, 残した AI っぽいところ, 禁止語残存リスト) + edited draft

### Step 3 Decision

If the editor determines "revision needed", return to Step 1 with the editor's feedback included.
For Japanese documents, a 採点 total below 35/50 OR any single axis below 5/10 counts as "revision needed".
Maximum 3 cycles. Upon reaching 3 cycles, take the best draft at that point into Step 3b.

### Step 3b: Content Diff and Slop Scan

Run once on the draft that leaves the Step 3 loop. The orchestrator does this itself (not a sub-agent):

1. Save two files to the session scratchpad (or `$TMPDIR` when there is none) — never inside a repository:
   - `<before>`: the Step 3 input — in proofreading mode the original text, in new creation the Step 2 draft
   - `<after>`: the edited draft
2. Run:

   ```bash
   python3 ~/.agents/skills/writing/scripts/content_diff.py <before> <after> --json
   python3 ~/.agents/skills/writing/scripts/slop_scan.py <after> --json   # Japanese documents only
   ```

   (`~/.claude/skills/writing` is a symlink to `~/.agents/skills/writing`, so either prefix reaches the same scripts.)
3. Read the results:
   - `content_diff.py` exits 1 when `added_numbers` or `changed_numbers` is non-empty — the rewrite introduced or altered a figure. Exit 0 with `added_terms` / `dropped_terms` is advisory: check whether each added term is a fact the source lacked. Numbers are compared as a multiset: a value moved from one subject to another (「A は 3 件、B は 5 件」→「A は 5 件、B は 3 件」) passes with exit 0, so the editor still checks which number belongs to which subject
   - `slop_scan.py` always exits 0. Group its `findings` by `pathology` (`"1"` 病理① — `metaphor_verb`, `slop_vocabulary`, `inanimate_agency`; `"2"` 病理② — `nominal_chain`, `taigen_run`; `"3"` 病理③ — `negative_parallelism`, `excess_bold`, `excess_list`, `emoji_prohibited`; null → phrases.md 3/5/8). If `vendor_ok` is false, the vendor rules did not run; note that and continue with the results of the rules that did
   - **The check did not run** when `content_diff.py` exits 2 (input/output error), when `slop_scan.py` prints nothing to stdout (it could not read the file — it reports to stderr and still exits 0), or when its JSON does not parse. Never read an empty or missing result as "no findings": say in the Final Output which check did not run
4. If content_diff exited 1, or any finding in 病理①②③ is present, re-run Step 3 **once** with the editor persona (and the references, for Japanese) plus one message that lists the content_diff tokens and the slop_scan findings grouped by pathology with line numbers. The editor removes each added or changed number/term or moves it to 「書き手に確かめたい点」, and for each finding either repairs it or records the reason it was kept under 「残した AI っぽいところ」. This re-run is not a Step 3 Decision cycle and does not count toward the 3-cycle limit
5. Re-run both scripts on the new draft. Do not loop a third time — whatever still remains goes into the Final Output disclosure

## Final Output

Present the editor-approved draft (or the best draft upon reaching 3 cycles, after Step 3b) to the user, followed by:

- 「書き手に確かめたい点」 (max 3, omit when empty)
- 「残した AI っぽいところ」 (omit when empty)
- **Machine-check disclosure**: when content_diff still exits 1 after the Step 3b re-run, list the remaining added/changed numbers explicitly and say they are not in the source. When slop_scan findings remain without a recorded reason, list them by pathology. When `vendor_ok` was false, say the vendor rules (病理①の `metaphor_verb`・`slop_vocabulary`, 病理③ all) did not run. When a check did not run at all (content_diff exit 2, slop_scan empty stdout or unparsable JSON), say so by name — 「content_diff は実行できなかった（機械検査なし）」 — instead of the pass line. When everything passed, one line: 「content_diff: 数値の追加・変更なし／slop_scan: 病理①②③ 残存なし」

---

意味 4 点保持・不増補・病理①〜③ の機械検査の考え方は nanaism/yomiyasu（MIT, © 2026 nanaism, @8d5abeeb）— 文言は再著述。
