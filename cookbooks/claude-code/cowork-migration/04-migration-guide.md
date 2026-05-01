# Cowork 移行手順書

`~/ManagedProjects/setup/cookbooks/claude-code/files/` の Claude Code 資産を、Anthropic Agent Skills best practices に沿って Cowork desktop に持ち込む手順を、所要時間順にまとめた実行リスト。

優先度の判断軸:

- **A 級** — preference 1 ファイル貼り付けで日々の Cowork 体験が一気に変わる（10 分）
- **B 級** — Skill を 3 つだけ先に入れる（writing / interview / research）。文書・要件・調査が即標準化（30 分）
- **C 級** — 残り 6 スキル（retro / research-domains / feature-parity / security-review / verify-cognee / ingest-to-cognee）（60 分）
- **D 級** — Project memory への分散配備。プロジェクト別なので 1 リポジトリずつ（適宜）

---

## ステップ 0: 前提確認（5 分）

1. Cowork desktop アプリが最新版であること
2. Cognee MCP が接続されていること（research / verify-cognee / ingest-to-cognee に必要）
   - 未接続なら `mcp-registry` から接続後に進む
3. 必要に応じて Mem0 MCP も接続（research が user-attribute 検索を行うため。任意）
4. workspace folder で `~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/` を選択しておく（このフォルダから skill を import するため）

---

## ステップ 1: User Preferences の貼り付け（A 級・10 分）

1. Cowork desktop の **Settings → Personalization → User preferences** を開く
2. `02-user-preferences.md` を Cowork 内で開く（`computer://` リンクで直接開ける）
3. 「ここから貼り付け」 から 「ここまで」 までの本文を選択してコピー
4. User preferences 欄に貼り付け
5. 既存の短い preferences（口調・敬体・人名さん付け）と統合 — 重複は削除
6. 保存

**動作確認**: 新規セッションで「テストします」と話しかけ、敬体・さん付け・「考えてみます」と即答せずに AskUserQuestion が出るかを観察。

---

## ステップ 2: Core Skills 3 つの導入（B 級・30 分）

最初に導入する 3 つは `writing` / `interview` / `research`。Cowork で発生する「文書作成・要件定義・調査」3 大ニーズをカバーする。

### 2.1 Skill ファイルの配置

**重要**: Cowork は `~/.claude/skills/` を読まない。スキルは **Customize → Skills** UI から zip ファイルとしてアップロードする方式（claude.ai の Chat タブと同じ）。`~/.claude/skills/` を読むのは Claude Code (CLI) だけ。

手順:

1. 各 skill フォルダを zip 化する（SKILL.md と参照ファイルが入っているフォルダを丸ごと）

   ```bash
   cd ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills
   for skill in writing interview research; do
     (cd "$skill" && zip -r "/tmp/${skill}.zip" .)
   done
   ls -la /tmp/*.zip
   ```

2. Cowork desktop アプリを開く → 左サイドバーの **Customize** → **Skills** タブ → **+** ボタン → **Upload skill**
3. `/tmp/writing.zip` を選択してアップロード。`/tmp/interview.zip`、`/tmp/research.zip` も同様
4. アップロード後、Skills 一覧に表示され既定で有効化されている。トグルで一時無効化可能

**Claude Code 環境にも入れたい場合**（CLI と Cowork を併用するなら推奨）:

```bash
mkdir -p ~/.claude/skills
cp -r ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills/writing ~/.claude/skills/
cp -r ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills/interview ~/.claude/skills/
cp -r ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills/research ~/.claude/skills/
```

ただし既に `files/skills/` 配下に同名 skill が存在し、cookbook (mitamae) 経由で `~/.claude/skills/` にデプロイされている可能性があるので、上書きする前に既存版との diff を確認すること。

### 2.2 動作確認（各スキル 1 回ずつ）

1. **writing**: 「次のテーマで RFC を書いてください: 〜」 → writing skill が起動し personas + RFC template を読み込むことを確認
2. **interview**: 「〜という機能を作りたいです。要件を整理してください」 → AskUserQuestion で 1-2 ずつ要件を掘る挙動を確認
3. **research**: 「〜について調査してください」 → Cognee + Mem0 並列検索 → BLUF レポートを確認

各動作確認の前に Cowork セッションを restart すると確実。

---

## ステップ 3: 残り Skills（C 級・60 分）

残り 6 スキルを順次導入。導入順は依存関係順:

1. `retro` — 単独で動く
2. `research-domains` — `research` に依存
3. `feature-parity` — workspace folder に対象 repo がある時のみ有効
4. `security-review` — git repo がある時のみ有効
5. `verify-cognee` — Cognee MCP 必須
6. `ingest-to-cognee` — Cognee MCP + Cowork 内蔵 `pdf` skill に依存

zip 化してから Customize → Skills でアップロード:

```bash
cd ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills
for skill in retro research-domains feature-parity security-review verify-cognee ingest-to-cognee; do
  (cd "$skill" && zip -r "/tmp/${skill}.zip" .)
done
ls -la /tmp/*.zip
```

それぞれを Cowork の Customize → Skills → `+` → Upload skill でアップロード。

Claude Code にも同期したい場合:

```bash
for skill in retro research-domains feature-parity security-review verify-cognee ingest-to-cognee; do
  cp -r ~/ManagedProjects/setup/cookbooks/claude-code/cowork-migration/03-skills/$skill ~/.claude/skills/
done
```

### 3.1 description フィールドの最終チェック

Anthropic best practices いわく「description が skill 発火の鍵」。各 SKILL.md の `description` がユーザー発話のトリガー語（「retro」「audit」「ingest」「security review」など）を含んでいることを確認。本ドラフトでは含めて書いているが、ユーザーの実際の発話パターンに合わせて追加トリガーを足してよい。

### 3.2 動作確認

各 skill につき 1 回、トリガー発話を試す:

| Skill | トリガー例 |
|---|---|
| retro | 「振り返りしましょう」 |
| research-domains | 「四半期の best practices リサーチをして」 |
| feature-parity | 「reference repo と比較して何が足りないか教えて」 |
| security-review | 「最近の差分の security review をして」 |
| verify-cognee | 「Cognee に何が入ってるか確認して」 |
| ingest-to-cognee | 「この PDF を Cognee に入れて」 |

---

## ステップ 4: Project Memory の分散配備（D 級・適宜）

プロジェクト固有のルールは、各プロジェクトの memory に置くことで「該当プロジェクトを開いた時だけロード」される（Cowork の workspace folder 切替で自動的に切り替わる）。

| 元ファイル | 配備先プロジェクト | 配備方法 |
|---|---|---|
| `rules/frontend-dev.md` | Next.js / Vite を使う各プロジェクト | プロジェクト root に `CLAUDE.md` または `AGENTS.md` を置き、必要箇所を抜粋 |
| `rules/infrastructure.md`（AWS cosmetic-drift, blast radius） | `home-monitor`, `setup` | 各 repo の `CLAUDE.md` の Infrastructure 節 |
| `rules/ios-build.md` | `edge-agent`, `weave` | iOS-related repo の `ios/CLAUDE.md` |
| `rules/mise-migration.md` | `setup` | `cookbooks/CLAUDE.md` または専用 `MISE.md` |
| `rules/release-plz.md` | `nuimo-rs`, `weave`, `edge-agent`, `roon-rs` | 各 repo の `CLAUDE.md` の Release 節 |
| `rules/ruby.md` | `setup` | `cookbooks/CLAUDE.md` の Ruby 節 |
| `rules/rust.md` | Rust crate を持つ各 repo | 各 repo の `CLAUDE.md` の Rust 節 |
| `rules/weave-protocol.md` | `weave`, `edge-agent` | `crates/weave-contracts/CLAUDE.md` |

Cognee に input したい場合は、`ingest-to-cognee` skill で各 rule ファイルを `cognify` する選択肢もある（横断検索可能になる）。

---

## ステップ 5: Cowork 既存スキルとの重複整理（10 分）

Cowork desktop には組み込みスキルがある。重複登録を避ける:

| Cowork 組み込み | 自作スキル相当 | 判断 |
|---|---|---|
| `pdf` | `ingest-pdf`（旧） | 組み込みは PDF manipulation。Cognee 取り込み専用は別物として `ingest-to-cognee` を維持 |
| `docx` / `pptx` / `xlsx` | — | 組み込みのみで十分 |
| `schedule` | `service-health-monitor` agent | 組み込み `schedule` で代替可能。`service-health-monitor` は持ち込まない |
| `setup-cowork` | — | 組み込みのみ |
| `skill-creator` | — | 自作スキルの改善には組み込み `skill-creator` を使う（best practices どおり） |

---

## ステップ 6: 「持ち込まない」資産のクリーンアップ判断（任意）

cookbook 内 で生き続ける Code-only 資産は、Cowork 移行とは独立。両環境を併用する前提なら何も削らない。Cowork に完全移行するなら以下を順次撤去:

- `files/skills/check-services/` — sysadmin 業務を Cowork に移すなら削除
- `files/skills/load-test/` 等の Docker / Linux 前提 skill — 同上
- `files/agents/mitamae-validator.md` 等の Code-only agents — 同上
- `files/hooks/*.rb` — Cowork 完全移行なら不要

ただし、Claude Code（CLI）と Cowork（desktop）は併用するのが現実的なので、当面は両方を維持し、preference の重複だけ整理することを推奨。

---

## ステップ 7: イテレーション（継続）

Anthropic best practices の「Claude A / Claude B」方式を実践:

1. 各 skill を実タスクで使う
2. うまく発火しなかった / 期待と違う結果になった時の発話を記録
3. 別セッションで `skill-creator` を呼んで、当該 SKILL.md を渡し改善を依頼
4. 改善版を反映 → 再度実タスクで使う

特に description の発火精度は実使用でしか測れない。「research」のつもりで言った発話で writing が発火する、といった衝突が出れば description を tighten する。

---

## デバッグメモ

### Skill が発火しない時

1. Skill が登録されているか確認:
   - **Cowork**: Customize → Skills の一覧に表示され、トグルが ON か
   - **Claude Code**: `ls ~/.claude/skills/`
2. description にユーザーが使った語が含まれているか
3. 別の skill のほうが優先されているか（trigger 衝突）— 衝突回避は description で when-NOT-to-use 節を強化
4. Cowork は zip でアップロードする方式。SKILL.md の YAML frontmatter が壊れていると silently 無視されることがある。アップロード後に Skills 一覧に出ているか確認

### Preferences が効いていない時

1. 新規セッション開始（preferences は session start でロード）
2. 文字数上限超過の可能性 — 不要な箇条書きを統合・圧縮
3. Cowork のシステムプロンプトと矛盾していないか — `02-user-preferences.md` 末尾の「重複しているデフォルト挙動」節を参照

---

## 完了基準

- [ ] User preferences 貼り付け済み・新セッションで反映確認
- [ ] writing / interview / research の 3 skill が発火することを確認
- [ ] 残り 6 skill のうち少なくとも 3 つが発火することを確認
- [ ] Project memory を 1 プロジェクト以上で配備
- [ ] Cowork 組み込みスキルとの重複が無いか確認
