# feedback.md — 取りこぼし／誤検出ログ（append-only）

writing skill の日本語 AI-slop チェックを実運用・fixture 検証する中で見つけた、(a) 検出すべきだったのに見逃した AI 臭、(b) 正当な文を誤って書き換えた誤検出、を記録する。各エントリを candidate として検討し、妥当なものだけ phrases.md / structures.md に昇格させる（いきなり本体に足すと誤検出が増える）。

## 形式

```
## YYYY-MM-DD <種別: 取りこぼし | 誤検出>
- 観測: <どの入力で何が起きたか>
- 該当パターン: <phrases.md / structures.md のどれ、または新規候補>
- 対応: <昇格 / 例外節追加 / 据え置き>
```

## ログ

（まだ無し。初回校正時から記入する。）
