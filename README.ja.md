<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmunのアイコン"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>サイドバーと、それを操作できるAIを備えた、軽量なMac用ブラウザ。</b><br>
  SafariのWebKitエンジン、縦型タブ、左側のお気に入りとブックマークフォルダ、そしてページを読み、クリックや入力まで代行するClaudeパネル。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14以降">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MITライセンス"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="ネイティブSwift">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <b>日本語</b> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="サイドバーに縦型タブが並び、ページがカードのように表示されたChangmunのウインドウ">
</p>

*Changmun* (창문) は韓国語で「窓」のことです。無料のオープンソースで、アカウントは要りません。アプリは英語、韓国語、日本語、簡体字中国語、スペイン語、ドイツ語、フランス語に対応しています。

## インストール

```sh
brew install --cask namekun/tap/changmun
```

[アプリを直接ダウンロード](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg)することもできます。

- AppleシリコンのMacと、macOS 14以降が必要です。
- Appleの署名と公証を受けているので、すぐに開けます。
- 自動で更新されます。
- 初回起動時に、ブックマークと履歴を読み込むかどうかを確認します。

## なぜChangmunか

- **軽い。** アプリは21MB、ダウンロードは約7MBです。Macにすでに入っているWebKitエンジンを使います。
- **サイドバー。** 縦型タブ、お気に入り、ブックマークフォルダ、タブグループ、スペースが1列にまとまっています。タブを上に置きたい場合は、設定で切り替えられます。
- **ブラウザを使うAI。** Claudeがページを読み、クリックや入力を代わりに行います。リスクのある操作の前には、先に確認します。
- **プライベート。** アカウントもサーバもアナリティクスもありません。広告とトラッカーは、最初からブロックされます。
- **今までのものも持ってこられる。** SafariとChromium系ブラウザからブックマークと履歴を、Chromium系からはパスワードも読み込めます。
- **自分だけのスタートページ。** スタイルは3種類。セクションは自由に並べ替えられ、背景も好きなものを選べます。

## AI

⌘Eを押して、ふだんの言葉で頼んでみてください。

- 「このページを要約して」
- 「この3つのタブの価格を比べて」
- 「このサイトにサインインして」

すでにお使いの`claude` CLIで動くので、ご自身のClaude Codeのサブスクリプションを使います。Claudeを使わない場合は、パネルを無視して構いません。ブラウザのそのほかの機能は、AIなしでも使えます。

**歯止めになる仕組み**

- 支払い、送信、投稿、削除の前に確認します。
- 見ていないタブを使うときや、見慣れないサイトを開くときも、先に確認します。
- パスワードは見えません。プライベートウインドウは一切見ません。

メッセージ、添付した画像、AIが読んだページは、`claude` CLIを通じてAnthropicに送られます。ほかのツールも、MCPや`changmun`コマンドでChangmunを操作できます。

## ほかのブラウザとの比較

Changmunは、すべての点ですべてのブラウザに勝とうとはしていません。ここでは、違いと、ほかのブラウザのほうが向いている場面をまとめます。

| | アプリの大きさ | エンジン |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21MB** | WebKit (macOSに入っているもの) |
| Safari 27 | 35MB | WebKit (macOSに入っているもの) |
| Google Chrome 156 | 731MB | Chromium (自前のコピー) |
| Arc 1.168 | 862MB | Chromium (自前のコピー) |
| Dia 1.53 | 1.3GB | Chromium (自前のコピー) |

<sub>2026年10月に、Appleシリコン搭載Mac 1台で`du -sh`を使って測りました。</sub>

| 比べる相手 | Changmunでできること | 次の場合は、そのブラウザのままがよいでしょう |
| :-- | :-- | :-- |
| **Safari** | 同じエンジンに、縦型タブのサイドバー、ページを操作できるAI、Chromeウェブストアの機能拡張が加わります | タブ、パスワード、パスキーのiCloud同期が必要 |
| **Chrome** | Googleアカウントも同期サーバもなく、アプリの大きさは約3%です | Chromium専用に作られたサイト、Chromeの同期、Windows・Linux・スマートフォンが必要 |
| **Arc** | サイドバーとスペースという発想は同じで、機能はまだ増えています (Arcは2025年5月からメンテナンスモードです) | BoostsやEaselsが必要 |
| **Dia** | 同じ系統の発想ですが、独自のAIサービスもアカウントもありません。お持ちの`claude` CLIを使います | Diaのホスト型AI機能や、仕事向けのサービス連携が必要 |

これは、各プロジェクトが自ら公表している内容にもとづいています。古くなっている点があれば、[issueを立てて](https://github.com/namekun/Changmun/issues)お知らせください。

### まだ足りないところ

- **同期はありません。** ブックマーク、履歴、パスワードは、作成したMacにだけ残ります。
- **Mac専用です。** iPhone、Windows、Linuxには対応していません。
- **パスキーはまだです。** ブラウザがパスキーを扱うにはAppleのentitlement (権限) が必要です。Changmunは申請して、返事を待っているところです。
- **機能拡張にはmacOS 15.4以降が必要です。** WebKitにない機能に頼るChromeの機能拡張もあります。
- **Chromium専用のサイト**は、Safariと同じようにここでも正しく動かないことがあります。
- **メンテナーは1人です。** 大手のブラウザより目が行き届かない分、粗削りな部分もあります。バグ報告は歓迎します。

## 覚えておきたいキー

| キー | 動作 |
| :-- | :-- |
| ⌘T | 新規タブ |
| ⌘L | アドレスを編集 |
| ⌘E | AIパネル |
| ⌘D | お気に入りに追加または削除 |
| ⌃1–9 | スペースへ移動 |
| ⌥⌘\\ | スプリットビュー |
| リンクを⇧クリック | ページを離れずにプレビュー |
| ⌘⇧T | 閉じたタブを開き直す |

Safari方式かChrome方式かは、設定 (⌘,) で選べます。[すべてのショートカット](GUIDE.ja.md#ショートカット)。

## プライバシー

閲覧内容はMacの中にとどまります。アプリが自分で行う通信は、アップデートの確認や広告フィルタのリストの更新など、わずかです。検索候補は、入力した文字を検索エンジンに送ります。オフにでき、プライベートウインドウからは送信されません。[送信される内容とタイミングのすべて](GUIDE.ja.md#プライバシー)。

## 詳しく知る

[ガイド](GUIDE.ja.md)に、すべてを詳しくまとめています。

- [主な機能](GUIDE.ja.md#主な機能): タブ、スペース、リーダーモード、プライベートウインドウ、ダウンロード
- [AI](GUIDE.ja.md#ai): モデル、承認、ツール、MCPとコマンドライン
- [広告ブロック](GUIDE.ja.md#広告ブロック)、[機能拡張](GUIDE.ja.md#機能拡張)、[ほかのブラウザから読み込む](GUIDE.ja.md#ほかのブラウザから読み込む)
- [パスワードとセキュリティ](GUIDE.ja.md#パスワードとセキュリティ)
- [開発者向け](GUIDE.ja.md#開発者向け)と[ソースからビルド](GUIDE.ja.md#ソースからビルド)

## ライセンス

MIT。[LICENSE](LICENSE)をご覧ください。
