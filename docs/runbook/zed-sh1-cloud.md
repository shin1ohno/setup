# Zed リモート開発手順（air → sh1-cloud）

`air` と `sh1-cloud` に private overlay wrapper を適用し、SSH と 7 個の tool の
PATH を確認してから、登録済みの 3 repository のいずれかを Zed で開く。
tailnet に依存する操作の前に SSH を確認し、到達できなければ private infrastructure が
管理する IAP 経路から復旧する。

## 1. 接続設定の管理範囲と project root

`air` を local UI host、`sh1-cloud` を remote host とする。private
`zp-SHIN/projects/mercari-setup` は SSH transport、OpenSSH、GCE OS Login、SSH stanza を
管理し、public `setup` は Zed client/server settings を管理する。Zed relay は使わない。

public `dot-config-zed` は `air` に次の project path を登録する。

```text
~/ManagedProjects/zp-SHIN
~/ManagedProjects/kouzoh-p-terraform
~/ManagedProjects/setup
```

`sh1-cloud` の HOME 全体を project root にしない。Zed 公式は 100,000 files を超える
root に警告している。現在の `sh1-cloud` HOME には 339,659 files、53,689 directories が
あり、過去に HOME を開いた remote workspace で数千件の inotify/watcher error が発生した。

`file_scan_exclusions` は Zed default 9 件を残し、`.cache`、`.local`、`.zed_server` を
追加する。この設定だけに頼らず、repository 単位で開く。

`sh1-cloud` cookbook は server settings、Solargraph、gopls、worktree task を配置する。
Linux GUI はインストールしない。接続時、Zed が client と一致する headless server を
`~/.zed_server` へダウンロードする。

## 2. SSH preflight と両 host への private overlay 適用

まず `air` で SSH config の解決と非対話接続を確認する。

```sh
ssh -G sh1-cloud | awk '$1 == "hostname" || $1 == "user" { print }'
ssh -o BatchMode=yes sh1-cloud 'hostname -s'
```

失敗した場合は tailnet 経由で再認証せず、先に「tailnet node key の確認と再認証」の
IAP 手順で復旧する。

private overlay wrapper は public platform entry recipe、overlay の順に実行する。まず
`air` の shell で次の command を実行し、完了後に `ssh sh1-cloud` で remote shell に
入って同じ command を実行する。

```sh
cd ~/ManagedProjects/zp-SHIN/projects/mercari-setup && ./bin/apply
```

## 3. PATH と Zed 接続の確認

適用後の project login shell で 7 個の tool を確認する。

```sh
ssh sh1-cloud 'bash -lc "command -v ruby go node npm cargo rustc codex"'
```

7 個すべての path が出力されればよい。public zsh cookbook は `sh1-cloud` の NSS account
に限り、noninteractive login bash へ mise、rbenv、pyenv、go、cargo、local shims を
公開する。Zed integrated terminal は `/usr/bin/zsh` を明示して起動する。

登録済み repository を開く前に、過去の remote HOME window/session を閉じる。project を
追加しても、すでに開いている window の root は移行されない。

Zed では `Ctrl-Cmd-Shift-O` を押し、`sh1-cloud`、対象 repository の順に選ぶ。CLI から
開く場合は次のいずれかを使う。

```sh
zed 'ssh://sh1-cloud:~/ManagedProjects/zp-SHIN'
zed 'ssh://sh1-cloud:~/ManagedProjects/kouzoh-p-terraform'
zed 'ssh://sh1-cloud:~/ManagedProjects/setup'
```

接続後、command palette から `zed: open log` を開く。新しい `notify::inotify` と
lost-sync warning が繰り返されていないことを確認する。

## 4. tailnet node key の確認と再認証

node key の作成日時と期限は固定値を文書化せず、実機から確認する。

```sh
ssh sh1-cloud 'tailscale status --json | jq -r ".Self | {Created, KeyExpiry}"'
```

Setup は Running node の認証を自動更新しない。期限が近い場合や SSH preflight が失敗した
場合は、operator が IAP 経由で VM に入り再認証する。`--force-reauth` によって現在の
tailnet 経路が切れる可能性があるため、`ssh sh1-cloud` 上では実行しない。

`sh1-cloud` alias は IAP へ fallback しない。instance、project、zone は private
infrastructure の値を使い、public repository には固定しない。

```sh
ZED_REMOTE_INSTANCE=replace-with-private-instance
ZED_REMOTE_PROJECT=replace-with-private-project
ZED_REMOTE_ZONE=replace-with-private-zone
gcloud compute ssh "$ZED_REMOTE_INSTANCE" \
  --project="$ZED_REMOTE_PROJECT" \
  --zone="$ZED_REMOTE_ZONE" \
  --tunnel-through-iap
```

VM shell で再認証する。

```sh
sudo tailscale up --force-reauth --hostname=sh1-cloud --accept-routes=false
```

表示された browser URL を開いて認証し、VM から退出する。`air` で SSH preflight の
2 command を再実行する。

## 5. 症状別の復旧

そのほかの症状は次の順で切り分ける。

- SSH stanza がなければ、`air` で private overlay のみを再適用する。

  ```sh
  ~/ManagedProjects/zp-SHIN/projects/mercari-setup/bin/apply --overlay-only
  ```

- Headless server を取得できなければ、`sh1-cloud` の `~/.zed_server` が書き込み可能で
  あることと、`curl` または `wget` から `https://zed.dev` に到達できることを確認する。
  外向き通信を使えない場合は `upload_binary_over_ssh` を有効にする。

- Tool が見つからなければ PATH check を再実行し、local は command palette の
  `zed: open log`、remote は `~/.local/share/zed/logs/` を確認する。

- `notify::inotify` または lost-sync warning が続くなら、remote HOME window/session を
  閉じ、3 repository のいずれかを新しい window で開く。

Zed remote development の公式仕様：<https://zed.dev/docs/remote-development>
