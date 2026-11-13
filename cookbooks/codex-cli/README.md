# codex-cli cookbook

Codex CLI を mise で入れ、`~/.codex/config.toml` と `~/.codex/AGENTS.md` を配置します（`default.rb`）。この README は、そのうち remote control（`remote_control.rb`）の運用手順です。

## Remote control（ChatGPT アプリからの操作）

### 何をするか

ChatGPT の iOS アプリの Codex から、このホストの `~/.codex` のセッションを見たり、新しいセッションを始めたりできるようにします。Codex CLI の実験的な機能 `codex remote-control` を使います。

Codex 標準のデーモン管理は pid ファイル方式で、systemd のユニットを作りません。そのため、ホストを再起動すると誰もデーモンを起動し直しません。この recipe は、ブートのたびにデーモンを起こす systemd のユーザーユニットを置きます。

- `codex-remote-control.service`: `codex remote-control start` を実行する oneshot ユニットです。デーモンはこのユニットの cgroup の中で動きます。
- `codex-remote-control-watch.timer`: 5 分ごとに `guard.sh watch` を実行します。デーモンが動いていない、応答しない、またはユニットの cgroup の外で動いている場合に、ユニットを再起動します。自動更新のプロセスがあれば、再起動せずにそれを止めます。
- `~/.codex/app-server-daemon/settings.json`: `"updater": {"autoUpdateEnabled": false}` を書きます。ほかのキーは残します。
- `~/.local/share/codex-remote-control/guard.sh`: ユニットとタイマーが呼ぶ補助スクリプトです。

有効にするのは、ノード属性 `codex_cli: { remote_control: true }` を持つホストだけです。現在は `pve/lxc-pro-dev.rb`（pro-dev）だけが持っています。

### 実験的な機能であること

- `codex remote-control` は `[experimental]` と表示されます（`codex remote-control --help`）。
- OpenAI が文書にしているホストは、macOS / Windows のデスクトップアプリだけです。Linux の CLI からペアリングする経路は文書にありません。
- 版が上がると、コマンドや設定の名前が変わる可能性があります。デーモンの更新後は、下の「確認」を実行します。

### セキュリティ上の前提

- 電話から始めたセッションも、手元と同じ full access（`approval_policy = "never"`、`sandbox_mode = "danger-full-access"`）で動きます。`~/.ssh`、`~/.aws` など、ホストのファイルにはすべて届きます。
- ホストは、つないでくる個々のクライアントを認証しません。信頼の根拠は ChatGPT のアカウントと中継サーバーです。ChatGPT のアカウントには MFA かパスキーを設定してください。
- デーモンの環境は絞っています。ユニットは `SSH_AUTH_SOCK` と `GPG_AGENT_INFO` を外し、`guard.sh run` が `GITHUB_TOKEN`、`CLAUDE_CODE_*`、`HERDR_*`、名前に `TOKEN` / `SECRET` を含む変数を外してから起動します。`~/.codex/config.toml` は変えません。

### ペアリング

1. **自分の端末で**次を実行し、表示されたコードを iPhone の ChatGPT アプリ（設定 → Connections）に入力します。コードは、使われるまでは鍵と同じ扱いです。チャットやログに貼らないでください。

   ```
   codex remote-control pair
   ```

2. アプリのクライアント一覧に、**自分の電話 1 台だけ**があることを確かめます。知らないクライアントがあれば、下の「失効」を実行します。

ユニットの再起動やホストの再起動のあとも、ペアリングし直す必要はありません。

### 確認

```
systemctl --user status codex-remote-control.service      # active (exited)
systemctl --user list-timers codex-remote-control-watch.timer   # NEXT に時刻があること
codex app-server daemon version                            # 動いている app-server の版
pgrep -af 'app-server daemon pid-update-loop'              # 何も出ないこと（自動更新は止めている）
for p in $(pgrep -f 'app-server .*--listen unix://'); do cat /proc/$p/cgroup; done
                                                           # codex-remote-control.service で終わること
```

### 失効（無効化）の手順

**最初に目印ファイルを置きます。** 置かずに止めると、5 分ごとの見張りと次の setup の apply が、もう一度起動します。

1. 目印ファイルを置きます。ユニットは起動しなくなり、見張りは何もしなくなります。apply は、ユニットが有効か動いていれば、有効にする代わりに無効にして止めます。また、`settings.json` の `remoteControlEnabled` を false にします（ほかのキーは残します）。

   ```
   touch ~/.config/codex-remote-control.disabled
   ```

2. remote control の設定を切ります。次の apply も同じことをしますが、それまでの間に手元の対話的な `codex` が、止まっているデーモンを remote control 付きで起動し直すことがあります（下の「手元の codex との関係」）。すぐに切るために実行します。

   ```
   codex app-server daemon disable-remote-control
   ```

3. ユニットとタイマーを止め、無効にします。

   ```
   systemctl --user disable --now codex-remote-control-watch.timer codex-remote-control.service
   ```

4. デーモンを止めます（手順 2 がシェルからデーモンを起動し直している場合があるためです）。

   ```
   codex app-server daemon stop
   ```

5. 残っている自動更新のプロセスを止めます。

   ```
   pkill -f 'app-server daemon pid-update-loop'
   ```

6. 何も残っていないことを確かめます。

   ```
   pgrep -af 'app-server .*--listen unix://|app-server daemon pid-update-loop'   # 何も出ないこと
   cat ~/.codex/app-server-daemon/settings.json                                    # "remoteControlEnabled": false
   ```

7. ChatGPT アプリの設定 → Connections で、ペアリングしたデバイスとこのホストを削除します（アプリの画面の名前は二次情報に基づきます）。

再び有効にするときは、目印ファイルを消してから setup を apply します（または `systemctl --user enable --now codex-remote-control.service codex-remote-control-watch.timer`）。起動時に `codex remote-control start` が remote control を有効に戻します。

### 乗っ取りが疑われる場合

上の失効の手順 1〜7 を終えてから、次を行います。

- ChatGPT のすべてのセッションからサインアウトし、パスワードかパスキーを再設定します。`codex logout` も実行します。
- このホストから届く認証情報をすべてローテーションします: AWS のキー、`~/.ssh` のすべての鍵、session-search のクライアントシークレットと HMAC 鍵、`GITHUB_TOKEN`。`tailscale logout` も実行します。
- 改変がないか確かめます: crontab、`~/.ssh/authorized_keys`、`~/.config/systemd/user`、シェルの rc ファイル、`~/.codex/config.toml` の `mcp_servers`。
- そのあと setup を apply し直して、管理しているファイルを元に戻します。

### デーモンの更新（手動）

自動更新は止めています。自動更新は 1 時間ごとに `https://chatgpt.com/codex/install.sh` を取得して、署名の確認なしに `/bin/sh` で実行するためです。更新は手で行います。

```
sh ~/.local/share/codex-remote-control/guard.sh run codex app-server daemon update
systemctl --user restart codex-remote-control.service
```

`daemon update` は、呼び出したシェルからデーモンを起動し直します。2 行目でユニットの中に戻します（戻さなくても、見張りが 5 分以内に戻します）。1 行目を `guard.sh run` 経由にするのは、その間に動くデーモンにもシェルの認証情報を渡さないためです。

### 電話で実行中の作業が切れる操作

次の操作は、電話のセッションで実行中のターンを終わらせます。

- ユニットの再起動（setup の apply で、ユニットのファイル、`guard.sh`、自動更新の設定のどれかが変わったときを含みます。1 回の apply での再起動は 1 回です）
- デーモンの更新
- 見張りによる再起動（デーモンがユニットの外で動いていた場合など）

### 手元の codex との関係

Codex 0.162.1 のソースで確認しました（0.167 / 0.169 のソースは未確認です）。

- 手元の対話的な `codex` は、機能 `daemon_auto_start`（既定で有効）があると共有のデーモンにつなぎます。デーモンが動いていればそれにつなぐので、そこで始めたセッションのコマンドはユニットの環境で動きます。
- デーモンが動いていないと、`codex` は自分のシェルの環境とセッションの cgroup でデーモンを起動します。`settings.json` の `remoteControlEnabled` が true なら、remote control 付きになります。見張りがこれを見つけ、5 分以内にユニットの中で起動し直します。
- `--no-daemon` を付けて起動した `codex` は、デーモンを使いません。シェルの環境のまま動きます。
- 見張りと `ExecStartPre` が扱うのは、この `~/.codex` のデーモン（`~/.codex/packages/` の下のバイナリで動くもの）だけです。別の `CODEX_HOME` のデーモンには触れません。
- 見張りは、自動更新のプロセスを見つけるとそれを止めてログに残します。ユニットは再起動しません。

#### 手元のセッションへの影響

デーモンが動いている間は、手元の `codex`（`--no-daemon` なし）もデーモンにつなぎます。そのため、手元で始めたセッションのコマンドも、シェルではなくユニットの環境で動きます。

- `GITHUB_TOKEN` はありません。`gh` は `~/.config/gh/hosts.yml` の認証で動きます。
- 転送された SSH エージェントはありません。git は pro-dev 自身の鍵（`~/.ssh`）を使います。
- `CLAUDE_CODE_*` と `HERDR_*` もありません。
- シェルの環境が必要なときは、`codex --no-daemon` で起動します。
