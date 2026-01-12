# AltServer Cookbook

このcookbookは、iOSデバイスでJIT対応のUTMを使用するために必要なmacOSアプリケーションをインストールします。

## 背景

2025年12月より、日本でもiOSで代替アプリマーケットプレイスが利用可能になりました。これにより、AltStore PALをインストールし、UTMなどのJIT対応アプリを最高速度で実行できるようになりました。

**注意**: 日本ではiPhoneのみ対応しており、iPadOSでは利用できません。

## インストールされるもの

### AltServer

AltStoreのmacOSコンパニオンアプリケーション。以下の用途に使用します：
- AltJIT機能（Wi-Fi経由でJITを有効化）
- iOSデバイスへのアプリのサイドロード

### jitterbugpair

[Jitterbugプロジェクト](https://github.com/osy/Jitterbug)のコマンドラインツール。StikDebugでJITデバッグを行うために必要なデバイスペアリングファイル（`.mobiledevicepairing`）を生成します。

## 前提条件

- HomebrewがインストールされたmacOS
- iOS 26.2以降のiPhone（日本ではiPadOS非対応）
- 日本のApple ID（日本でAltStore PALにアクセスするため）

## 使用方法

roleにこのcookbookを含める：

```ruby
include_cookbook "altserver"
```

または直接実行：

```bash
./bin/mitamae local darwin.rb
```

## iOSのセットアップ手順

Macでこのcookbookを実行した後、iPhoneで以下の手順を行います：

### ステップ1: AltStore PALのインストール

1. Safariで https://altstore.io/download を開く
2. 「Download」をタップしてマーケットプレイスのインストールを許可
3. 設定アプリでマーケットプレイスを承認
4. 再度「Download」をタップし「Install App Marketplace」を選択

### ステップ2: AltStore Classicのインストール

1. AltStore PALを開く
2. 「Browse」タブに移動
3. 「AltStore Classic」を見つけて「GET」をタップ

### ステップ3: UTMのインストール

1. AltStore Classicで「Sources」タブに移動
2. 「+」をタップして追加: `https://alt.getutm.app`
3. 「Browse」で「UTM」をインストール（UTM SEではなく）

### ステップ4: ペアリングファイルの生成（Mac側）

1. iOSデバイスをUSBでMacに接続
2. デバイスのロックを解除し、必要に応じてMacを信頼
3. ターミナルで実行：
   ```bash
   jitterbugpair
   ```
4. `YOUR-UDID.mobiledevicepairing`というファイルが作成される
5. このファイルをAirDropでiOSデバイスに転送

### ステップ5: JITの有効化

#### 方法A: StikDebug（推奨 - どこでも動作）

1. AltStore PALの推奨ソースから「StikDebug」をインストール
2. StikDebugを開き、転送したペアリングファイルを選択
3. VPN構成の許可を求められたら許可
4. AltStore Classicで「My Apps」に移動
5. UTMを長押しして「Enable JIT」をタップ

#### 方法B: AltJIT（Macと同じWi-Fiが必要）

1. MacでAltServerを起動
2. MacとiOSデバイスを同じWi-Fiネットワークに接続
3. iOSデバイスでUTMを開く
4. Macでメニューバーのアイコンをクリック
5. 「Enable JIT」> [デバイス名] > UTM を選択

## トラブルシューティング

| 問題 | 解決策 |
|------|--------|
| 「No valid license provided」エラー | AltStore Classicを更新、UTMリポジトリを再追加 |
| 「Device Not Mounted」エラー | StikDebugを強制終了して再起動 |
| AltStore PALがインストールできない | Safariのみ使用、iOS 18.0以上が必要 |
| jitterbugpairが見つからない | `./bin/mitamae local darwin.rb`を再実行 |

## 注意事項

- UTMを再起動するたびにJITを再度有効化する必要がある
- StikDebug方式は初回のペアリング設定後、Macなしで動作する
- UTM SE（App Store版）はJITをサポートしていない

## 参考リンク

- [AltStore](https://altstore.io/)
- [UTM](https://getutm.app/)
- [Jitterbug/jitterbugpair](https://github.com/osy/Jitterbug)
- [AltStore JIT FAQ](https://faq.altstore.io/altstore-classic/enabling-jit)
