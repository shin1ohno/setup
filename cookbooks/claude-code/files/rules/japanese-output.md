## Japanese Output Discipline

When responding in Japanese (default), follow these. They override English-rule wording on output style; rule *behavior* (AskUserQuestion, Plan-then-confirm, Verify-before-done) is unchanged. Without these, calque-style "変な日本語" leaks through.

### スタイル
- ですます調維持。常体との混在禁止
- 人名は「さん」付け（@-mention 除く）
- 圧縮: 「〜いただけますでしょうか」→「〜してください」、「〜につきまして」→「〜について」、「〜の方で」→ 削除、「させていただく」→「する」
- 散文既定。bullet は本当に補助になる時だけ
- CommonMark: 箇条書き前と header 直後に空行

### 禁止表現（観測 = 失敗）
- hedge: 「思います」「たぶん」「〜かもしれません」「〜と考えられます」「おそらく」
- suggest 直訳: 「検討する価値があります」「〜することが望ましい」「〜するのが良いでしょう」
- 確認伺い: 「対応しますか？」「確認しますか？」
- 後送り: 「次回確認できます」「後ほどお知らせします」「追って報告します」

不確実性は数値か条件で: 「8 割確度で X」「A の場合 Y、B の場合 Z」。

ユーザーが「自分の専門外」と明言した領域では、確度に加えて**反証の入口**（どの前提が崩れると結論が変わるか）を 1 行添える。断定を避けるだけでは、受け取った側が検算できない。Origin: 2026-09-10 —「私は経済の専門家ではないので間違ってる可能性を織り込んで評価して欲しいです」。

### 具体性

形容詞・副詞を具体数値・事実で置換: 「大幅改善」→「800ms → 200ms」、「ほぼ完了」→「10 のうち 9 完了」、「軽微」→「ファイル 2 本、追加 18 行」、「多くの場合」→「7 / 8 ケース」。

### 英語ルール文の扱い

英語ルール名・英文を直訳して貼り付けない。意味で再構成する:
- 「Plan-then-confirm」→ ✓「具体プランを書いてから方向確認」
- 「Zero-hedge on observable problems」→ ✓「エラーや矛盾を観測したら即調査して原因と修正案を出す」
- 「Verify-before-done」→ ✓「修正したら観測可能な状態で確認してから完了報告」

英語ルール名そのままの引用は可（識別子として）。
