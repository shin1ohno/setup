# fixtures — writing skill 日本語 AI-slop チェックの検証コーパス

**非配備**。`default.rb` の配備リスト（`%w(phrases.md structures.md examples.md)`）には入れない。repo 内のテスト専用資産。

## 構成

- `slop-N.md` … 特定の AI 臭 family を含む日本語下書き
- `human-N.md` … 対応する de-slop 済みの目標
- `non-slop-N.md` … 変更されてはいけない正当な日本語（**最重要の誤検出ガード**）
- `feedback.md` … 取りこぼし／誤検出の append-only ログ（candidate 段階導入用）

各 `slop-N.md` 冒頭にコメントで対象 family を記す。

## 検証手順

1. writing skill を Edit モードで各 `slop-N.md` に適用する。
2. 合格条件:
   - (a) 対象 family の `検出:` 検索語（phrases.md / structures.md 参照）が出力で **0 hit**
   - (b) 出力が `human-N.md` に意味的に近接
   - (c) 5 軸採点（立場/リズム/主体性/具体性/削減, 1–10）が **合計 ≥ 35/50 かつ各軸 ≥ 5/10**
3. **誤検出ガード**: 各 `non-slop-N.md` を Edit モードに通し、**実質無変更**で返ることを確認する。良文を AI 臭と誤判定して書き換えたら失敗。
4. 取りこぼし／誤検出を見つけたら `feedback.md` に追記し、candidate として検討してから phrases/structures に昇格させる。

閾値 35/50 は本家 stop-ai-slop-jp 準拠の初期値。このコーパスで 1 回校正する。
