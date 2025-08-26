# SESSION_PROGRESS.md

## mise 移行プロジェクト

### 目的
プログラミング言語以外のツールを mise で統一管理する

### 現在の状況
- Go と Node.js は既に mise で管理されている
- Python, Ruby, Rust, Java などは他のツールで管理されている
- CLI ツールや開発支援ツールの一部は mise に移行完了
  - bat, fd, ripgrep, tmux は mise 管理に移行済み（2025-08-26）
  - terraform, awscli はプラグインがインストール済みだが未使用

### 移行計画概要

#### Phase 1: 低リスクツール移行
単純なバイナリツールで依存関係が少ないもの
- [x] ripgrep (rg) - 完了
- [x] tmux - 完了
- [x] fd - 完了
- [x] bat - 完了

#### Phase 2: 中リスクツール移行
設定ファイルや環境変数の調整が必要なもの
- [ ] neovim
- [ ] fzf

#### Phase 3: 高リスクツール移行
複雑なインストールプロセスや設定が必要なもの
- [ ] terraform
- [ ] lazygit
- [ ] ansible
- [ ] awscli
- [ ] gcloud-cli

### 利点
1. **統一管理**: 全ツールを mise コマンドで管理
2. **プラットフォーム統一**: Darwin/Linux 間のコード削減
3. **バージョン管理**: 複数バージョンの並行運用が可能
4. **保守性向上**: プラットフォーム固有の分岐を削除
5. **設定簡素化**: shim による自動 PATH 管理

### ロールバック戦略
- 既存 cookbook のバックアップを保持
- ツール単位での段階的ロールバック可能
- Git による完全ロールバック対応

### 実施内容

#### Phase 1 完了 (2025-08-26)
- ripgrep, tmux, fd, bat の4つのツールを mise 管理に移行
- 各 cookbook で brew/apt によるパッケージ管理から mise に変更
- mise プラグインとしてインストール：
  - mise plugin add bat
  - mise plugin add fd
  - mise plugin add ripgrep
  - mise plugin add tmux
- ツールのインストールと設定：
  - mise install bat@latest fd@latest ripgrep@latest tmux@latest
  - mise use --global bat@latest fd@latest ripgrep@latest tmux@latest
- 実際のインストールパス：~/.local/share/mise/shims/

### 技術的な詳細

#### mise 設定ファイル
- グローバル設定: ~/.config/mise/config.toml
- 現在の管理ツール:
  - fd = "latest"
  - go = "1.22.3"
  - node = "lts"
  - usage = "latest"
  - ripgrep = "latest"
  - bat = "latest"
  - tmux = "latest"

#### cookbook の変更パターン
移行前:
```ruby
package "ツール名"  # Darwin
package "ツール名" do  # Ubuntu/Arch
```

移行後:
```ruby
include_cookbook "mise"

execute "mise install ツール名@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ツール名 | grep -q 'ツール名'"
end

execute "mise use --global ツール名@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ツール名 | grep -q '\\* '"
end
```

### 次のステップ
Phase 1 の動作確認後、Phase 2 の中リスクツール（neovim, fzf）の移行を開始する

#### Phase 2 移行時の注意点
- neovim: brew/ソースビルドから mise への移行
- fzf: git clone + install script から mise への移行
- 設定ファイルやプロファイルの調整が必要