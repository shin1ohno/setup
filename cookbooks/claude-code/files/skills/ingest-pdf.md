---
name: ingest-pdf
description: "PDF file(s) to Cognee knowledge graph ingestion"
user_invocable: true
---

# PDF → Cognee ナレッジグラフ取り込み

引数: `<PDFパス> [データセット名]`
- PDFパスはファイルまたはディレクトリ（ディレクトリの場合は配下の全PDFを処理）
- データセット名省略時はファイル名から自動生成

## 手順

### Step 1: テキスト抽出の試行

```python
import PyPDF2
reader = PyPDF2.PdfReader(pdf_path)
text = "\n".join(page.extract_text() or '' for page in reader.pages)
```

- 抽出文字数がページ数×100文字未満の場合、画像ベースPDFと判定 → Step 2へ
- 十分なテキストがある場合 → Step 3へ

### Step 2: 画像ベースPDFの処理

1. PyMuPDF (`fitz`) で各ページをPNG画像に変換（DPI=200）
2. Read ツールで各画像を視覚的に読み取り
3. 読み取った内容を構造化テキスト（Markdown形式）にまとめる
   - モデル名、価格、スペック、カテゴリなど読み取れる情報を全て含める
4. テキストファイルとして `/tmp/cognee_ingest/` に保存

### Step 3: Cognee APIへのアップロード

```bash
# 認証トークン取得
TOKEN=$(curl -s -X POST "http://localhost:8001/api/v1/auth/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=default_user@example.com&password=default_password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# ファイルアップロード（ファイル名はユニークにすること）
curl -s -X POST "http://localhost:8001/api/v1/add" \
  -H "Authorization: Bearer $TOKEN" \
  -F "data=@<テキストファイルパス>" \
  -F "datasetName=<データセット名>"
```

**重要:** ファイル名が同じだとdata_idが重複判定される。`<カテゴリ>_<名前>_<シーズン>_catalog_text.txt` のようにユニークにする。

### Step 4: Cognify実行

```bash
curl -s -X POST "http://localhost:8001/api/v1/cognify" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"datasets": ["<データセット名>"]}'
```

タイムアウト上限を長めに設定すること（最大10分）。

### Step 5: 検索で検証

MCP `search` ツール（`search_type=GRAPH_COMPLETION`）でキーワード検索を行い、取り込まれた内容が正しく返ることを確認する。

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| cognify 409 Conflict | 内部text_*.txtファイル消失 | コンテナ再起動後にデータ再アップロード |
| 全ファイルが同じdata_id | ファイル名の重複判定 | ユニークなファイル名に変更して再アップロード |
| PipelineRunAlreadyCompleted | 既にcognify済み | 新しいデータセット名で再アップロード |
| テキスト抽出0文字 | 画像ベースPDF | Step 2の画像→テキスト変換を実施 |
