export const meta = {
  name: 'claude-md-audit',
  description: 'Mine recent session transcripts for CLAUDE.md improvements and audit rules files for removal/relocation',
  whenToUse: 'CLAUDE.md / rules の定期監査（四半期目安）。透過 transcript から行動改善シグナルを抽出し、既存ルールの陳腐化を検証する。args: {sinceDays?: number (default 30), extraContext?: string}',
  phases: [
    { title: 'Discover', detail: 'transcripts + rules ファイルの動的発見とバッチ構成' },
    { title: 'Extract', detail: 'transcript バッチ → 行動シグナル抽出' },
    { title: 'Audit', detail: 'ルールファイル監査 + デプロイ機構調査' },
    { title: 'Cluster', detail: '追加候補の重複統合' },
    { title: 'VerifyAdd', detail: '追加候補の2レンズ adversarial 検証' },
    { title: 'VerifyRemove', detail: '削除/移動候補の利用実態検証' },
    { title: 'Critic', detail: '完全性チェック' },
  ],
}

// ---- args guard: harness が args を JSON 文字列で渡すことがある（2026-07-04 実測） ----
const ARGS = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const SINCE_DAYS = ARGS.sinceDays || 30
// setup リポジトリの場所（ホストにより異なる場合は args.setupRepo で上書き）
const SETUP_REPO = ARGS.setupRepo || '~/ManagedProjects/setup'

const CTX = `
## 背景（自己完結コンテキスト）
このマシンの現行ユーザーの Claude Code グローバル設定の定期改善監査タスクの一部です。パス中の ~ はあなた自身のシェルで解決してください（必要なら echo $HOME で確認）。/Users/<name> のようなユーザー名前提のパスは書かないこと。
- 設定の source of truth: ${SETUP_REPO}/cookbooks/claude-code/files/ （CLAUDE.md, rules/, docs/, hooks/, skills/, agents/, settings.json）。~/.claude/ へは mitamae でデプロイされる。デプロイ対象は default.rb 内の明示 %w() リストで管理（files/ に置くだけでは配線されない）。
- ~/.claude/rules/*.md は Claude Code が全ファイル毎セッション自動ロードする（要再確認: バージョンで変わりうる。ls と現セッションのロード状況から確認せよ）。on-demand 置き場は ~/.claude/docs/（@-import した分のみロード）。
- セッション transcripts: ~/.claude/projects/<project-dir>/<uuid>.jsonl（JSONL、1行1メッセージ）。subagents/ サブディレクトリはサブエージェントログなので対象外。
- ユーザーは主に日本語でやりとりする。
${ARGS.extraContext ? '## 追加コンテキスト\n' + ARGS.extraContext : ''}
## 厳守事項
- ファイルの編集・作成・削除は一切禁止。読み取りと分析のみ。結果は StructuredOutput で返す。
- jq フィルタ内で != や ! を使わない（zsh の history expansion で壊れる）。否定は (.x == "y" | not) の形で書く。
- 出力の文章は日本語で書く。
`

const DISCOVER = {
  type: 'object', additionalProperties: false,
  properties: {
    batches: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          name: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
        required: ['name', 'files'],
      },
    },
    auditGroups: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          name: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
        required: ['name', 'files'],
      },
    },
    all_rule_files: { type: 'array', items: { type: 'string' }, description: '重複判定用の全ルールファイル名一覧' },
    notes: { type: 'string' },
  },
  required: ['batches', 'auditGroups', 'all_rule_files'],
}

const EXTRACT = {
  type: 'object', additionalProperties: false,
  properties: {
    findings: {
      type: 'array', maxItems: 12,
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          theme: { type: 'string', description: '1行のテーマ名' },
          category: { type: 'string', enum: ['correction', 'repeated-instruction', 'friction', 'preference', 'rule-violation', 'new-gotcha'] },
          evidence: { type: 'array', minItems: 1, items: { type: 'object', additionalProperties: false, properties: { session: { type: 'string' }, quote: { type: 'string', maxLength: 300 } }, required: ['session', 'quote'] } },
          proposed_rule: { type: 'string', description: 'CLAUDE.md/rules に足すべきルールの具体的文面案' },
          target: { type: 'string', description: '追加先: CLAUDE.md | rules/<file>.md | docs/<file>.md | new:<name>.md | hook | skill' },
          already_covered_by: { type: 'string', description: '既存ルールで部分的にカバーされている場合その場所' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['theme', 'category', 'evidence', 'proposed_rule', 'target', 'confidence'],
      },
    },
    sessions_analyzed: { type: 'array', items: { type: 'object', additionalProperties: false, properties: { file: { type: 'string' }, topic: { type: 'string', maxLength: 120 } }, required: ['file', 'topic'] } },
  },
  required: ['findings', 'sessions_analyzed'],
}

const AUDIT = {
  type: 'object', additionalProperties: false,
  properties: {
    file_findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          file: { type: 'string' },
          verdict: { type: 'string', enum: ['keep-always', 'move-on-demand', 'compress', 'merge', 'delete'] },
          merge_into: { type: 'string' },
          size_bytes: { type: 'integer' },
          compressed_estimate_bytes: { type: 'integer', description: 'compress 判定時の圧縮後推定サイズ' },
          reasons: { type: 'string' },
          stale_refs: { type: 'array', items: { type: 'string' }, description: '実在しないファイル/コマンド/リポジトリへの参照' },
          last_topic_activity: { type: 'string', description: 'このトピックの直近の活動時期と根拠' },
        },
        required: ['file', 'verdict', 'size_bytes', 'reasons'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['file_findings'],
}

const INVEST = {
  type: 'object', additionalProperties: false,
  properties: {
    deploy_mechanism: { type: 'string' },
    drift_direction: { type: 'string', description: 'ローカル ~/.claude/ と cookbook の差分方向と要約' },
    undeployed_files: { type: 'string', description: 'cookbook のみに存在しローカル未デプロイのファイルと理由' },
    broken_pointers: { type: 'array', items: { type: 'string' } },
    docs_dir_inventory: { type: 'string' },
    hooks_skills_agents_summary: { type: 'string', description: 'hooks/skills/agents と CLAUDE.md ルールの重複（hook で機械強制できるルールの候補）' },
    recommendations: { type: 'string' },
  },
  required: ['deploy_mechanism', 'drift_direction', 'undeployed_files', 'broken_pointers', 'docs_dir_inventory', 'hooks_skills_agents_summary', 'recommendations'],
}

const CLUSTERS = {
  type: 'object', additionalProperties: false,
  properties: {
    clusters: {
      type: 'array', maxItems: 18,
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          category: { type: 'string' },
          target: { type: 'string' },
          proposed_rule: { type: 'string' },
          evidence: { type: 'array', items: { type: 'object', additionalProperties: false, properties: { session: { type: 'string' }, quote: { type: 'string' } }, required: ['session', 'quote'] } },
          support_count: { type: 'integer', description: '独立したセッション数' },
        },
        required: ['id', 'title', 'category', 'target', 'proposed_rule', 'evidence', 'support_count'],
      },
    },
    dropped_count: { type: 'integer' },
    dropped_reasons: { type: 'string' },
  },
  required: ['clusters', 'dropped_count', 'dropped_reasons'],
}

const VERDICT = {
  type: 'object', additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'REJECTED', 'MODIFIED'] },
    reasoning: { type: 'string' },
    modified_proposal: { type: 'string' },
  },
  required: ['verdict', 'reasoning'],
}

const CRITIC = {
  type: 'object', additionalProperties: false,
  properties: {
    gaps: { type: 'array', items: { type: 'string' } },
    assessment: { type: 'string' },
  },
  required: ['gaps', 'assessment'],
}

function discoverPrompt() {
  return CTX + `
## あなたのタスク: 分析対象の動的発見
1. transcripts の列挙: find ~/.claude/projects -name '*.jsonl' -not -path '*/subagents/*' -mtime -${SINCE_DAYS} で直近 ${SINCE_DAYS} 日のトップレベルセッションを列挙し、サイズ・日付・プロジェクトを把握する。
   - このワークフロー自身が動いている現在進行中のセッション（数分以内に更新され続けている巨大ファイルで、内容が「CLAUDE.md 監査」のワークフロー起動そのもの）は head で冒頭を確認して除外してよい。
   - 1KB 未満の空セッション（/clear のみ等）は除外。
2. バッチ構成: プロジェクト×時期でグループ化。1 バッチ = 最大 8 ファイルかつ合計 ~4MB 目安。3MB 超の巨大ファイルは単独バッチ。バッチ名は "<project>-<period>" 形式。
3. ルールファイルの列挙: ~/.claude/CLAUDE.md、~/.claude/rules/*.md、~/.claude/docs/*.md、および cookbook のみに存在するファイル（diff -rq ${SETUP_REPO}/cookbooks/claude-code/files/rules/ ~/.claude/rules/ で検出。cookbook 側は $HOME 展開済みの絶対パスで含める）。
4. 監査グループ構成: 意味的に近いファイルを 3〜6 個ずつのグループに（例: core-behavioral / workflow / infra / containers / devstack / tools-misc）。CLAUDE.md と docs/ の常時ロードファイルは core グループへ。
5. all_rule_files にファイル名（basename）の全一覧を入れる。
出力はスキーマ通り。ファイル編集禁止。`
}

function extractPrompt(b) {
  return CTX + `
## あなたのタスク: セッション transcript のマイニング（バッチ: ${b.name}）
以下の JSONL transcript を分析し、ユーザーのグローバル CLAUDE.md / rules に追加すべき行動改善シグナルを抽出してください。

対象ファイル:
${b.files.map(f => '- ' + f).join('\n')}

## 抽出手順
1. まずユーザーメッセージだけを抽出する（tool_result は type=="text" フィルタで除外される）:
   jq -r 'select(.type=="user") | .message.content | if type=="string" then . elif type=="array" then (.[] | select(.type=="text") | .text) else empty end' FILE 2>/dev/null | head -c 60000
   巨大ファイルは絶対に Read で全読みしない。上の jq 抽出＋必要なら grep で範囲を絞る。
   '<local-command' '<command-' 'Caveat:' '<system-reminder' で始まる行はハーネス注入なので無視。
2. ユーザー発言を時系列で読み、次を探す:
   a. correction: Claude の行動への修正・叱責（「違う」「そうじゃなく」「やめて」「なんで〜」「前も言った」「必ず〜して」「二度と」等。日本語が主）
   b. repeated-instruction: 同じ種類の指示が2回以上（デフォルト化候補）
   c. friction: ユーザーが情報を再説明させられている、Claude が probe すべき値を訊いている
   d. preference: スタイル・進め方の好みの表明
   e. rule-violation: 既存ルール（~/.claude/CLAUDE.md, ~/.claude/rules/*.md — 読んで確認してよい）に反する行動が実際に起き、ユーザーが指摘した形跡
   f. new-gotcha: 長時間のデバッグの末に判明した技術的知見で、既存 rules に未記載のもの（既存 rules の 'Origin:' 付きルールと同じ性質のもの）
3. correction を見つけたら、直前の assistant の行動も確認して文脈を把握する:
   jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' FILE | grep -B2 -A2 'キーワード'
4. タスクの内容そのもの（何を作ったか）は対象外。「Claude にどう働いてほしいか」のシグナルだけを report する。
5. 各 finding には transcript からの実引用（quote, 300字以内）とセッションファイル名を必ず付ける。引用のないものは report しない。
6. 既存ルールでカバー済みかを ~/.claude/CLAUDE.md と ~/.claude/rules/ を grep して確認し、already_covered_by に記入（新規性が無ければ finding 自体を落としてよいが、「ルールがあるのに違反が起きた」は rule-violation として価値があるので残す）。
最大12件、確度の高い順。何も無ければ findings は空配列でよい（無理に作らない）。`
}

function auditPrompt(g, allFiles) {
  return CTX + `
## あなたのタスク: ルールファイル監査（グループ: ${g.name}）
以下のファイルを監査し、「毎セッション自動ロードされるコスト」に見合うかを判定してください。

対象ファイル（絶対パス）:
${g.files.map(f => '- ' + f).join('\n')}

全ルールファイル一覧（重複判定の参考。担当外は読まなくてよいが grep で概要確認は可）:
${allFiles.join(', ')}

## 監査手順（ファイルごと）
1. ファイルを全部読む。サイズを wc -c で記録。
2. 参照実在性チェック: 文中で言及されるファイルパス（~/.claude/..., ~/ManagedProjects/...）、リポジトリ、コマンド、スキル名が実在するか ls/grep で確認。実在しないものは stale_refs に列挙。
3. トピックの活性度チェック:
   - 関連リポジトリの直近活動: git -C ~/ManagedProjects/<repo> log --oneline -5 --since='${SINCE_DAYS} days ago'（存在すれば）
   - transcripts での言及頻度: grep -l を ~/.claude/projects/*/[a-f0-9-]*.jsonl（トップレベルのみ、subagents 除外）にトピックキーワードで実行し、ヒットしたセッション数を数える
4. verdict を判定:
   - keep-always: ほぼ全セッションに関係する行動規範（例: git commit 作法、AskUserQuestion 運用）
   - move-on-demand: 価値はあるが特定タスク時のみ関係する playbook。常時ロードから外し ~/.claude/docs/ へ移して Read でロードする形に
   - compress: 常時ロード維持だが、Origin story・長いコード例・重複説明を detail ファイル（docs/ 置き）に追い出して大幅圧縮できる
   - merge: 他ファイルと統合すべき（merge_into に統合先）
   - delete: 対象システムが廃止済み・完全陳腐化
5. 判定理由には具体的根拠（活動時期、ヒットセッション数、サイズ）を書く。「たぶん使わない」ではなく計測結果で。
迷ったら keep 寄りではなく、「このルールが常時ロードされていなかったら直近${SINCE_DAYS}日のどのセッションで実害が出たか?」で判定する。実害ゼロなら move-on-demand。`
}

function investigatorPrompt() {
  return CTX + `
## あなたのタスク: デプロイ機構と drift の調査
1. ${SETUP_REPO}/cookbooks/claude-code/default.rb を読み、rules/docs/hooks/skills/agents/workflows がどうやってデプロイされるか特定する（明示リストか Dir.glob か）。
2. diff -rq で cookbook files/ とローカル ~/.claude/ の drift を検出し、方向（どちらが新しいか）を git log と stat で判定。settings.json の差分も確認。
3. 壊れたポインタの列挙: ~/.claude/rules/*.md・~/.claude/docs/*.md・~/.claude/CLAUDE.md の中で、ローカルに存在しないファイルを Read しろと指示している箇所を grep で洗い出して実在確認。
4. ~/.claude/docs/ の中身を ls し、CLAUDE.md からの @-import 状況を確認。
5. cookbook の hooks/, skills/, agents/ の一覧を ls し、CLAUDE.md のルールと機能が重複するもの（ルールで縛っている行動を hook で機械的に強制できるもの）を列挙。
ファイル編集禁止。分析のみ。`
}

function clusterPrompt(findingsJson) {
  return CTX + `
## あなたのタスク: 追加候補のクラスタリング
抽出エージェントが transcript から見つけた findings（JSON）を統合してください。
1. 同一・類似テーマをクラスタにまとめる（support_count = 独立セッション数）
2. 落とすもの: タスク内容そのものの知見（リポジトリの CLAUDE.md や memory MCP に属するもの）、引用が弱い一回きりの低確度もの、既存ルールで完全カバー済みのもの（already_covered_by 参照。ただし「ルール違反が繰り返されている」クラスタは残す — ルール強化候補として）
3. 最大18クラスタ、support_count × 確度 の高い順
4. 各クラスタの proposed_rule は最良の文面案に統合（1-5行、既存 CLAUDE.md の文体に合わせ簡潔に）
5. dropped_count と代表的な drop 理由を報告

## findings JSON
${findingsJson}`
}

function coverageLensPrompt(c) {
  return CTX + `
## あなたのタスク: 追加候補の adversarial 検証（カバレッジレンズ）
次の CLAUDE.md 追加候補を「不要である」方向で批判的に検証してください。

候補: ${JSON.stringify(c, null, 2)}

検証項目:
1. 既存カバー: ~/.claude/CLAUDE.md と ~/.claude/rules/*.md を grep/Read し、この候補が既にカバーされているか確認。カバー済みなら REJECTED（どのセクションかを reasoning に）
2. ただし既存ルールがあるのに違反が繰り返されている場合は、「ルールの書き方・配置の問題」として MODIFIED（強化案・hook 化案を modified_proposal に）
3. 実装先の妥当性: CLAUDE.md 本文（常時ロード・簡潔ルール向き）か rules ファイルか、それとも hook（機械的強制が可能なら hook が優る）か skill か。より良い置き場があれば MODIFIED
4. 一般性: このルールは今後のセッションでも繰り返し発火するか。プロジェクト固有なら該当リポジトリの CLAUDE.md に置くべきで、グローバルには REJECTED
確信が持てない場合は REJECTED に倒す。`
}

function evidenceLensPrompt(c) {
  return CTX + `
## あなたのタスク: 追加候補の adversarial 検証（証拠レンズ）
次の CLAUDE.md 追加候補の証拠が実在し、解釈が正しいかを検証してください。

候補: ${JSON.stringify(c, null, 2)}

検証項目:
1. 引用実在性: evidence の各 quote が session ファイルに実在するか grep で確認（quote の特徴的な部分文字列で検索。ファイルは ~/.claude/projects/*/ 配下）。存在しない引用が1つでもあれば REJECTED
2. 文脈の正しさ: 引用の前後を jq/grep で読み、「ユーザーが Claude の行動を正そうとした」という解釈が正しいか確認。タスク指示の言い換えを correction と誤認していないか
3. 再現性: 同種のシグナルが2セッション以上にあるか。1回きりなら、その1回が高コスト（数時間のデバッグ、PR やり直し等）だった場合のみ CONFIRMED、軽微なら REJECTED
検証の結果、ルール文面をより実態に即した形に直せるなら MODIFIED + modified_proposal。`
}

function removalLensPrompt(f) {
  return CTX + `
## あなたのタスク: 削除/移動候補の adversarial 検証（利用実態レンズ）
監査エージェントが次の判定を出しました。この判定を「間違っている（このルールはまだ常時ロードが必要）」方向で反証を試みてください。

判定: ${JSON.stringify(f, null, 2)}

反証手順:
1. 対象ファイルを読む
2. transcripts（~/.claude/projects/*/[a-f0-9-]*.jsonl のトップレベル、直近${SINCE_DAYS}日分）でトピックキーワードを grep -l し、実際に言及されたセッション数を数える
3. 関連リポジトリ（~/ManagedProjects/*）の git log --since='${SINCE_DAYS} days ago' で活動を確認
4. 他の rules ファイル・skills・hooks からの参照（cross-link）を grep で確認 — 参照されているファイルを消すとポインタが壊れる
5. delete 判定の場合: 対象システムが本当に廃止済みか確認（例: LXC が存在するか、リポジトリが存在するか）
判定:
- CONFIRMED: 監査判定は正しい（削除/移動して問題ない）
- REJECTED: 反証成功 — このルールは keep-always にすべき（根拠を reasoning に）
- MODIFIED: 部分的に正しい（例: delete ではなく move-on-demand が妥当、あるいは一部セクションだけ残す）。modified_proposal に修正案
迷ったら安全側（REJECTED = keep）に倒す。ただし「常時ロードコスト」も実害であることを忘れない — 直近${SINCE_DAYS}日で1度も参照されないトピックの keep 主張には具体的根拠を要求する。`
}

// ---- Phase 0: Discover ----
phase('Discover')
const disc = await agent(discoverPrompt(), { label: 'discover', phase: 'Discover', schema: DISCOVER })
log(`Discover: ${disc.batches.length} transcript batches / ${disc.auditGroups.length} audit groups / ${disc.all_rule_files.length} rule files`)

// ---- Phase 1+2: Extract and Audit run concurrently ----
const extractP = parallel(disc.batches.map(b => () =>
  agent(extractPrompt(b), { label: `extract:${b.name}`, phase: 'Extract', schema: EXTRACT })))

const auditP = parallel(disc.auditGroups.map(g => () =>
  agent(auditPrompt(g, disc.all_rule_files), { label: `audit:${g.name}`, phase: 'Audit', schema: AUDIT })))

const investP = agent(investigatorPrompt(), { label: 'audit:deploy-investigator', phase: 'Audit', schema: INVEST })

const extractResults = (await extractP).filter(Boolean)
const auditResults = (await auditP).filter(Boolean)
const investigator = await investP

const allFindings = extractResults.flatMap(r => r.findings)
const sessionsAnalyzed = extractResults.flatMap(r => r.sessions_analyzed)
log(`Extract 完了: ${allFindings.length} findings / ${sessionsAnalyzed.length} sessions。Audit 完了: ${auditResults.flatMap(r => r.file_findings).length} file verdicts`)

// ---- Phase 3: Cluster (barrier justified: dedup needs ALL findings) ----
const clusterRes = await agent(clusterPrompt(JSON.stringify(allFindings)), { label: 'cluster-additions', phase: 'Cluster', schema: CLUSTERS })
log(`Cluster: ${clusterRes.clusters.length} clusters (dropped ${clusterRes.dropped_count})`)

// ---- Phase 4: Verify additions (2 lenses each) ----
const verifiedAdds = await parallel(clusterRes.clusters.map(c => () =>
  parallel([
    () => agent(coverageLensPrompt(c), { label: `verify-add-cov:${c.id}`, phase: 'VerifyAdd', schema: VERDICT }),
    () => agent(evidenceLensPrompt(c), { label: `verify-add-ev:${c.id}`, phase: 'VerifyAdd', schema: VERDICT }),
  ]).then(vs => ({ cluster: c, coverage: vs[0], evidence: vs[1] }))
))

// ---- Phase 5: Verify removals/moves ----
const removalCandidates = auditResults.flatMap(r => r.file_findings)
  .filter(f => f.verdict === 'delete' || f.verdict === 'move-on-demand' || f.verdict === 'merge')
log(`Removal 検証対象: ${removalCandidates.length} 件（compress/keep 判定は検証スキップ — 低リスク）`)

const verifiedRemovals = await parallel(removalCandidates.map(f => () =>
  agent(removalLensPrompt(f), { label: `verify-rm:${f.file.split('/').pop()}`, phase: 'VerifyRemove', schema: VERDICT })
    .then(v => ({ candidate: f, verdict: v }))
))

// ---- Phase 6: Completeness critic ----
const summary = {
  sessions_analyzed: sessionsAnalyzed.length,
  addition_clusters: clusterRes.clusters.map(c => c.title),
  removal_candidates: removalCandidates.map(f => `${f.file}: ${f.verdict}`),
  compress_keep: auditResults.flatMap(r => r.file_findings).filter(f => f.verdict === 'compress' || f.verdict === 'keep-always').map(f => `${f.file}: ${f.verdict}`),
  investigator_recommendations: investigator ? investigator.recommendations : 'N/A',
}
const critic = await agent(CTX + `
## あなたのタスク: 監査の完全性チェック
CLAUDE.md 改善監査が完了しました。以下がカバー範囲の要約です。見落としを指摘してください:
- 分析していない情報源はないか（例: hookify ルール, ~/.claude/settings.json の permissions, memory ディレクトリ, TODO.md）— 実在するか ls で確認し、監査価値があるものを挙げる
- 追加候補クラスタと削除候補の一覧を見て、明らかに欠けている観点はないか
- 検証されていない主張はないか

## 要約
${JSON.stringify(summary, null, 2)}`, { label: 'completeness-critic', phase: 'Critic', schema: CRITIC })

return {
  stats: { sessions: sessionsAnalyzed.length, raw_findings: allFindings.length, clusters: clusterRes.clusters.length, dropped: clusterRes.dropped_count },
  session_topics: sessionsAnalyzed,
  additions: verifiedAdds.filter(Boolean),
  removals: verifiedRemovals.filter(Boolean),
  all_file_verdicts: auditResults.flatMap(r => r.file_findings),
  audit_notes: auditResults.map(r => r.notes).filter(Boolean),
  investigator,
  critic,
}
