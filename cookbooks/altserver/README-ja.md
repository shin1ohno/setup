# AltServer Cookbook

このcookbookは、iOS/iPadOSデバイスでJIT対応のUTMを使用するために必要なmacOSツールをインストールします。

## 背景

UTM（Universal Turing Machine）は、iOS/iPadOSで仮想マシンを実行できるアプリケーションです。しかし、フルスピードで動作させるにはJIT（Just-In-Time）コンパイルが必要で、これを有効化するには特別な手順が必要です。

### 日本での状況

- **iPhone**: 2025年12月より代替アプリマーケットプレイス（AltStore PAL）が利用可能
- **iPad**: AltStore PALは利用不可（EU限定）。代わりにTrollStore、SideStore、AltStore Classicを使用

## 性能比較

| モード | 性能 | 説明 |
|--------|------|------|
| **Hypervisor** | ネイティブの70-90% | iPadOS 16.3以前のM1/M2 iPadのみ |
| **JIT (TCG)** | ネイティブの8-15% | 最も一般的な方法 |
| **UTM SE (JITなし)** | ほぼ使用不可 | DOSや超軽量Linuxのみ |

> **重要**: iPadOS 16.4以降、AppleはHypervisorをカーネルから削除しました。M4 iPad Pro等の新型機種ではJITが最高性能オプションです。

## インストールされるもの

### AltServer

AltStoreのmacOSコンパニオンアプリケーション：
- AltJIT機能（Wi-Fi経由でJITを有効化）
- iOSデバイスへのアプリのサイドロード

### jitterbugpair

[Jitterbugプロジェクト](https://github.com/osy/Jitterbug)のコマンドラインツール。SideStore/StikDebugでJITを有効化するために必要なデバイスペアリングファイル（`.mobiledevicepairing`）を生成します。

## 使用方法

roleにこのcookbookを含める：

```ruby
include_cookbook "altserver"
```

または直接実行：

```bash
./bin/mitamae local darwin.rb
```

---

## iPad向け：JIT有効化方法

日本ではiPadでAltStore PALが使用できないため、以下の方法を使用します。

### iPadOSバージョン別の推奨方法

| iPadOSバージョン | 推奨方法 | PC必要 |
|-----------------|----------|--------|
| 14.0〜16.6.1, 16.7 RC, 17.0 | **TrollStore** | 初回のみ |
| 17.1〜17.3 | SideStore + SideJITServer | 初回のみ |
| 17.4〜18.x | **SideStore + StikDebug** | 初回のみ |
| 常にMacがある環境 | AltStore Classic + AltJIT | 毎回 |

---

### 方法1: TrollStore（最も簡単）

**対象**: iPadOS 14.0〜16.6.1, 16.7 RC, **17.0のみ**

**メリット**:
- 一度インストールすれば永続的に動作
- PCやVPNが不要
- 署名の期限切れなし

**手順**:

1. TrollStore 2をインストール（[インストールガイド](https://ios.cfw.guide/installing-trollstore/)）
2. [UTM.HV.ipa](https://github.com/utmapp/UTM/releases)をダウンロード
3. TrollStoreでUTM.HV.ipaをインストール
4. アプリを長押し→「Open with JIT」

> **注意**: iPadOS 17.1以降にアップデートすると使用不可になります

---

### 方法2: SideStore + StikDebug（PC不要・推奨）

**対象**: iPadOS 17.4〜18.x（18.4 β1を除く）

**メリット**:
- 初回設定後はPC不要
- オンデバイスでJIT有効化

#### 初回セットアップ（Macが必要）

**Step 1: ペアリングファイルの生成**

```bash
# iPadをUSBでMacに接続
# 「このコンピュータを信頼」をタップ

# jitterbugpairを実行
jitterbugpair

# 成功すると ~/YOUR-UDID.mobiledevicepairing が生成される
```

**Step 2: ファイルの転送**

```bash
# zipに圧縮（拡張子が変わるのを防ぐ）
cd ~
zip pairing.zip *.mobiledevicepairing
```

AirDropでiPadに転送します。

**Step 3: SideStoreのインストール**

1. [SideStore](https://sidestore.io/)の公式サイトからインストール
2. 設定 > プライバシーとセキュリティ > デベロッパモード を有効化

**Step 4: StikDebugのインストール**

1. SideStoreを開く
2. 「Sources」タブで StikDebug のソースを追加
3. StikDebugをインストール

**Step 5: ペアリングファイルのインポート**

1. ファイルアプリで `pairing.zip` を解凍
2. `.mobiledevicepairing` ファイルをタップ
3. StikDebugにインポートされる

#### 以降の使用（PC不要）

1. StikDebugを開く（LEDが全て緑になるまで待つ）
2. 「Connect by App」をタップ
3. UTMを選択
4. 「Attached」と表示されたらUTMを起動

> **注意**: 再起動後は毎回StikDebugを開いてJITを有効化する必要があります

---

### 方法3: AltStore Classic + AltJIT

**対象**: iPadOS 14〜18.x

**メリット**:
- 最も安定
- 公式ドキュメントが充実

**デメリット**:
- JIT有効化のたびにMacが同じWi-Fiに必要
- 7日ごとに署名更新が必要（無料Apple ID）

#### セットアップ

**Step 1: AltStoreのインストール**

1. MacでAltServerを起動
2. iPadをUSBで接続
3. メニューバーのAltServerアイコン > Install AltStore > [デバイス名]

**Step 2: UTMのインストール**

1. iPadでAltStoreを開く
2. 「Sources」タブで `+` をタップ
3. `https://alt.getutm.app` を追加
4. 「Browse」でUTMをインストール

**Step 3: ペアリングファイルの生成**

```bash
jitterbugpair
```

生成されたファイルをAirDropでiPadに転送し、AltStoreにインポート。

#### JITの有効化（毎回）

1. MacでAltServerを起動
2. MacとiPadを同じWi-Fiに接続
3. iPadでUTMを開く
4. AltStoreで「My Apps」> UTMを長押し > 「Enable JIT」

または、Macのメニューバーから：
AltServerアイコン > Enable JIT > [デバイス名] > UTM

---

## iPhone向け：AltStore PAL（日本対応）

2025年12月より、日本でもiPhoneで代替アプリマーケットプレイスが利用可能になりました。

### セットアップ

**Step 1: AltStore PALのインストール**

1. Safariで https://altstore.io/download を開く
2. 「Download」をタップしてマーケットプレイスのインストールを許可
3. 設定アプリでマーケットプレイスを承認

**Step 2: AltStore Classicのインストール**

1. AltStore PALを開く
2. 「Browse」タブで「AltStore Classic」を「GET」

**Step 3: UTMのインストール**

1. AltStore Classicで「Sources」> `+` > `https://alt.getutm.app`
2. 「Browse」でUTMをインストール

**Step 4: JITの有効化**

StikDebugまたはAltJIT（上記iPad向けの方法と同じ）を使用。

---

## トラブルシューティング

| 問題 | 解決策 |
|------|--------|
| jitterbugpairで「No device found」 | Apple純正ケーブルを使用、Wi-Fi同期を無効化 |
| ペアリングファイルが見つからない | `~/` (ホームディレクトリ)を確認 |
| ファイルが`.txt`になる | 転送前にzipに圧縮 |
| Gatekeeperがブロック | システム設定 > プライバシーとセキュリティ > 「このまま開く」 |
| StikDebugのLEDが赤い | VPNがONか確認、ペアリングファイルのパスを確認 |
| 「Device Not Mounted」エラー | StikDebugを強制終了して再起動 |
| iPadOS 18.4 β1でJITが動かない | Apple側の問題。アップデートを待つか別バージョンに |

---

## M1/M2 iPadでHypervisorを使用する方法

**対象**: iPadOS 15.0〜16.3のM1/M2 iPad Pro/Air

iPadOS 16.4以降、AppleはHypervisor Frameworkをカーネルから削除しました。16.3以前を維持しているM1/M2 iPadのみがHypervisorモードを使用できます。

**手順**:
1. TrollStoreをインストール
2. UTM.HV.ipaをインストール（Hypervisor対応ビルド）
3. 「Open with JIT」で起動

Hypervisorモードでは、Windows 11 ARMやLinuxがほぼネイティブ速度で動作します。

---

## 参考リンク

- [AltStore](https://altstore.io/)
- [SideStore](https://sidestore.io/)
- [SideStore JITドキュメント](https://docs.sidestore.io/docs/advanced/jit)
- [TrollStore](https://github.com/opa334/TrollStore)
- [UTM](https://getutm.app/)
- [UTM iOSインストールガイド](https://docs.getutm.app/installation/ios/)
- [Jitterbug/jitterbugpair](https://github.com/osy/Jitterbug)
- [AltStore JIT FAQ](https://faq.altstore.io/altstore-classic/enabling-jit)
