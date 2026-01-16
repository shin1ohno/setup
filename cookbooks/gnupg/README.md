# gnupg cookbook

GnuPG (GPG) のインストールと設定を行うcookbookです。

## What this cookbook does

1. **GnuPGのインストール**
   - macOS: `gnupg` (Homebrew)
   - Ubuntu: `gnupg` (apt)

2. **~/.gnupgディレクトリの作成**
   - パーミッション: `700`

3. **gpg-agent.confの設定** (macOS only)
   - `pinentry-mac`を使用したGUIパスフレーズ入力
   - キャッシュ設定 (default: 600秒, max: 7200秒)
   - `allow-loopback-pinentry`による非TTY環境サポート

4. **pinentry-macのインストール** (macOS only)

5. **シェルプロファイルへのGPG設定追加**
   - `GPG_TTY`環境変数の設定
   - `gpg-connect-agent updatestartuptty`の自動実行

## Git commit signing

GPG署名でgit commitを行うには、以下の設定が必要です：

```bash
# GPGキーの確認
gpg --list-secret-keys --keyid-format=long

# Gitにsigning keyを設定
git config --global user.signingkey <KEY_ID>

# 署名を有効化
git config --global commit.gpgsign true
```

## Troubleshooting

### "gpg failed to sign the data" エラー

非TTY環境（Claude Code、IDE内ターミナル等）でこのエラーが発生する場合：

1. **gpg-agentを再起動**
   ```bash
   gpgconf --kill gpg-agent && gpgconf --launch gpg-agent
   ```

2. **パスフレーズをキャッシュ**
   通常のターミナル（Terminal.app、iTerm）で以下を実行：
   ```bash
   echo "test" | gpg --clearsign
   ```
   pinentry-macのダイアログでパスフレーズを入力すると、キャッシュされます。

3. **キャッシュ時間を延長** (オプション)
   `~/.gnupg/gpg-agent.conf`を編集：
   ```
   default-cache-ttl 86400   # 24 hours
   max-cache-ttl 604800      # 7 days
   ```
   変更後は`gpgconf --kill gpg-agent`で再起動。

### pinentryダイアログが表示されない

```bash
# pinentry-macがインストールされているか確認
which pinentry-mac

# gpg-agent.confの設定を確認
cat ~/.gnupg/gpg-agent.conf
```

### GPG_TTYが設定されていない

シェルを再起動するか、手動で設定：
```bash
export GPG_TTY=$(tty)
```
