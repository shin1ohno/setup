# fixtures — writing skill 日本語 AI-slop チェックの検証コーパス

**非配備**。`default.rb` の配備リスト（`%w(phrases.md structures.md examples.md)`）には入れない。repo 内のテスト専用資産。

## 構成

- `slop-N.md` … 特定の AI 臭 family を含む日本語下書き
- `human-N.md` … 対応する de-slop 済みの目標。`slop-N.md` にない数値・原因・動作主・固有名詞・例は足さない
- `non-slop-N.md` … 変更されてはいけない正当な日本語（**最重要の誤検出ガード**）
- `feedback.md` … 取りこぼし／誤検出の append-only ログ（candidate 段階導入用）

各 `slop-N.md` 冒頭にコメントで対象 family を記す。

| ファイル | 対象 family | 機械検査で出る規則 |
|---|---|---|
| `slop-1.md` | phrases.md 3（定型評価語・テンプレ冒頭/結論）, phrases.md 1（過剰強調） | slop_scan は 0 件（`検出:` 検索語で見る）。content_diff: human-1 の数値（8 分・1 分）はすべて原文にある |
| `slop-2.md` | structures.md 1（病理①）, phrases.md 2（翻訳調・英語直訳） | slop_scan 病理 1（`inanimate_agency`「課題が浮き彫りに」）。残りは `検出:` 検索語で見る。content_diff: human-2 の数値（8 人・2 画面目・12 個・3 個・5 個）はすべて原文にある |
| `slop-3.md` | structures.md 3（病理③ 太字+コロン）, phrases.md 8（機械アーティファクト） | slop_scan 病理 3（`emoji_prohibited`）。content_diff: human-3 の数値（1.2 秒・0.4 秒・3 倍・2.1%・0.3%・7 回・2 回）はすべて原文にある |
| `slop-4.md` | phrases.md 6（接続詞連打）, structures.md 5（リズム均一）, structures.md 7（主語過剰明示） | slop_scan は 0 件（`検出:` 検索語で見る）。content_diff: human-4 の数値（5 分）は原文にある |
| `slop-5.md` | phrases.md 9（比喩動詞）, phrases.md 12（急増語 4 分類）。数値なし | slop_scan 病理 1（`metaphor_verb`, `slop_vocabulary`） |
| `slop-6.md` | structures.md 2（病理② 名詞連鎖＋体言止めの連続） | slop_scan 病理 2（`nominal_chain`, `taigen_run`） |
| `slop-7.md` | structures.md 3（病理③ 架空の敵を立てる否定対比＋太字の乱発）。意味を担う否定を 1 つ含む | slop_scan 病理 3（`negative_parallelism`, `excess_bold`）＋ `meta_filler` |
| `non-slop-1.md` | 中立な技術リファレンス | — |
| `non-slop-2.md` | 根拠つきの推量（かもしれない） | — |
| `non-slop-3.md` | 孤立した tell 1 個（クラスタ規則） | — |
| `non-slop-4.md` | 定着慣用句（骨が折れる）、根拠つきの推量（と考えられる）、文字どおりの「壊れる」「道具」「既定値」 | slop_scan で病理 1〜3 とも 0 件 |

## 検証手順

スクリプトは `cookbooks/claude-code/files/skills/writing/scripts/`（配備後は `~/.agents/skills/writing/scripts/`。`~/.claude/skills/writing` はその symlink）にある。書き直しの入出力は session の scratchpad か `$TMPDIR` に置き、repo には置かない。

1. writing skill を Edit モードで各 `slop-N.md` に適用する。
2. 合格条件:
   - (a) 対象 family の `検出:` 検索語（phrases.md / structures.md 参照）が出力で **0 hit**
   - (b) 出力が `human-N.md` に意味的に近接
   - (c) 5 軸採点（立場/リズム/主体性/具体性/削減, 1–10）が **合計 ≥ 35/50 かつ各軸 ≥ 5/10**
   - (d) **content_diff**: `python3 content_diff.py slop-N.md <出力> --json` の `added_numbers` と `changed_numbers` がともに空（exit 0）。原文にない数値を作ったら、ほかの条件を満たしていても失敗
   - (e) **slop_scan**: `python3 slop_scan.py <出力> --json` の `by_pathology` で、上の表に挙げた病理の件数が 0。slop-2 と slop-5 は病理 1、slop-6 は病理 2、slop-3 と slop-7 は病理 3 を見る。残った件数があれば、編集レポートの「残した AI っぽいところ」に残した理由が書かれていること
   - (f) slop-7 の「個人情報を含むログは検索対象にしません」が出力に残っていること（意味を担う否定を消していない）
3. **誤検出ガード**: 各 `non-slop-N.md` を Edit モードに通し、**実質無変更**で返ることを確認する。良文を AI 臭と誤判定して書き換えたら失敗。`non-slop-4.md` は入力の時点で slop_scan が病理 1〜3 とも 0 件であること（慣用句・物理的用法・設定項目名を規則が拾っていないこと）も確かめる。
4. **目標文の自己検査**: `python3 content_diff.py slop-N.md human-N.md` が exit 0、`python3 slop_scan.py human-N.md --json` が病理 1〜3 とも 0 件であること。human-N 自体が数値を足していたり病理を含んでいたりすると、(b) の比較先として使えない。slop-N 先頭の HTML コメントに含まれる数値は `dropped_numbers` に出るだけで、判定には影響しない。
5. 取りこぼし／誤検出を見つけたら `feedback.md` に追記し、candidate として検討してから phrases/structures に昇格させる。

閾値 35/50 は本家 stop-ai-slop-jp 準拠の初期値。このコーパスで 1 回校正する。

slop-5〜7・non-slop-4 の family 設計は nanaism/yomiyasu（MIT, © 2026 nanaism, @8d5abeeb）— 文言は再著述。例文は本コーパス向けに新規作成した。
