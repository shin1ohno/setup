# mise 移行候補ツール一覧

## CLI開発ツール
- terraform (cookbooks/terraform)
- awscli (cookbooks/awscli) 
- gcloud-cli (cookbooks/gcloud-cli)
- ansible (cookbooks/ansible)

## 開発支援ツール
- bat (cookbooks/bat)
- fd (cookbooks/fd)
- ripgrep (cookbooks/ripgrep)
- fzf (cookbooks/fzf)
- tmux (cookbooks/tmux)
- neovim (cookbooks/neovim)
- lazygit (cookbooks/lazygit)
- direnv (未実装)
- jq (未実装)
- yq (未実装)

## 現在の実装方法
- terraform: apt/brew
- awscli: 公式インストーラー
- gcloud-cli: 公式SDK
- bat: brew
- fd: brew
- ripgrep: brew
- fzf: git clone + install script
- tmux: brew
- neovim: brew/ソースビルド
- lazygit: go install