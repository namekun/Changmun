<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmun 图标"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>一款轻巧的 Mac 浏览器：带边栏，还有能替你操作它的 AI。</b><br>
  采用 Safari 的 WebKit 引擎，左侧是垂直标签页、个人收藏和书签文件夹，Claude 面板可以读取页面、点按和输入。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 或更高版本">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MIT 许可证"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="原生 Swift">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <b>简体中文</b> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="Changmun 窗口：边栏中是垂直标签页，右侧是页面卡片">
</p>

*Changmun*（창문）在韩语中是“窗户”的意思。作为浏览器的名字，可以说相当实在。它免费、开源，无需账号，也不做任何追踪。App 支持英语、韩语、日语、简体中文、西班牙语、德语和法语。

## 为什么选择 Changmun

- **轻巧。** Chromium 内核的浏览器各自带着一整份 Chromium，Changmun 则借用 macOS 自带的 WebKit 引擎（Safari 用的就是它）。下载只有约 3 MB（0.4.1 的 DMG 为 2.6 MB），更省电，引擎的安全修复会随 macOS 和 Safari 的更新送达。
- **像 Arc 和 Dia 的边栏。** 垂直标签页给标题留足了地方，另有磁贴式个人收藏、书签文件夹、标签页群组和空间。
- **会使用浏览器的 AI。** Claude 面板通过你已有的 `claude` CLI 阅读页面，并替你点按、输入。它肯出手，但不会擅自做主：遇到有风险的操作会先询问。
- **默认私密。** 没有账户、服务器或分析，也就没有什么需要注册的。广告和追踪器拦截已内置。
- **搬家，家当一起带。** 从 Safari 和 Chromium 内核浏览器导入书签和历史记录，Chromium 内核浏览器的密码和登录状态也能一并带来。Safari 的密码 macOS 不肯交给其他 App，只能留在原处。

## 安装

```sh
brew install --cask namekun/tap/changmun
```

需要 [Homebrew](https://brew.sh)、macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片的 Mac。App 使用 Developer ID 签名并经过 Apple 公证，所以可以直接打开。更新时运行 `brew update && brew upgrade --cask changmun`。

首次启动时，Changmun 会询问是否从你现在使用的浏览器导入书签和历史记录（Chromium 内核浏览器还包括密码和登录状态）。

### 从源码构建

你需要 macOS 14 或更高版本，以及 Xcode 或命令行工具。

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

如果只安装了命令行工具，脚本会使用 macOS 26 SDK 进行构建（macOS 27 SDK 的 SwiftUI 宏插件只随 Xcode 提供）。构建产物会放在 `~/Library/Caches/Changmun/build`，避开 iCloud 桌面同步。

## 功能一览

### 边栏与标签页

- **边栏。** 把个人收藏、书签和已打开的标签页收在左边一列：个人收藏以磁贴显示，下面是书签文件夹和垂直标签页。拖移标签页可调整顺序，拖到个人收藏上则可固定。和 Dia、Arc 一样，个人收藏和书签各自保留自己的标签页：点按它们会切换到对应的标签页，而不是替换你正在阅读的页面（按住 ⌘ 点按则新建标签页）。把页面上的链接拖到边栏即可作为标签页打开，拖到个人收藏或文件夹上则会存进去。标签页菜单还能重新载入、复制、移到新窗口、共享或用其他浏览器打开。关闭整个组的标签页或删除书签后，几秒内可以撤销。世上没有后悔药，但这几秒钟里有。
- **地址栏想放哪就放哪。** 放在手最习惯的位置：可以像 Arc 一样放在边栏顶部的后退、前进按钮下方，也可以像 Dia 一样放在页面上方（设置 › 外观 › 地址栏位置）。只显示网站名称，指针移上去时才出现盾牌和星标。个人收藏中的页面会一直显示星标，点按即可移出个人收藏。
- **书签文件夹。** 让书签保持你整理好的样子，又随手可及。导入的文件夹保留原来浏览器中的层级。常用的文件夹可以固定到边栏（右键点按或 … › 固定到边栏，或把文件夹拖到个人收藏下方），直接在原处展开。把书签拖到其他文件夹或个人收藏上，或用菜单里的移到来移动。其余书签在边栏底部的书签按钮中，并可搜索；旁边的 … 按钮可打开历史记录、已归档的标签页、专注模式和设置。
- **标签页群组。** 把相关的标签页放在一起，免得它们碍事。右键点按标签页 › 添加到新群组，起个名字，还能折叠。从群组内的标签页打开的标签页会加入该群组；用 ⌘⇧T 重新打开的标签页会回到原来的群组。拖动群组的标题即可移动它，拖到个人收藏或固定的文件夹上，则会连同标签页一起收进一个书签文件夹。
- **整理标签页。** 一键把零散的标签页分好组。“新建标签页”旁边的魔杖（窗口 › 整理标签页）挥一下，零散的标签页就会分组。开启 Apple Intelligence（macOS 26）后，由你 Mac 上的模型按主题分组并为群组命名，标签页的任何信息都不会离开这台 Mac。未开启时，互相打开的标签页和同一网站的标签页会分在一起。“撤销”可在几秒内恢复原状。从地址栏打开的新标签页会自动加入匹配的群组（可在设置 › 标签页中关闭）。
- **归档旧标签页**（默认关闭）。把一阵子没看的标签页收起来，而不是扔掉。超过设定时间（12 小时到 30 天，仅在 Changmun 运行期间计时）没有查看的标签页，会关闭并收进历史记录 › 已归档的标签页，随时可以重新打开并回到原来的群组。正在显示、正在播放、画中画、正在使用摄像头或麦克风、个人收藏以及私密浏览的标签页永远不会被归档。
- **休眠标签页。** 让后台标签页打个盹，把内存还给你。20 分钟没有查看的后台标签页，以及内存紧张时的所有后台标签页，都会释放其网页进程，当你回来时连同历史记录一起恢复。
- **命令栏**（⌘T）。一个输入框，包办搜索、输入地址、切换到已打开的标签页、查找书签和历史记录，以及向 AI 提问。

### 空间与配置文件

- **空间。** 为不同的上网场景分别准备各自的标签页、标签页群组和个人收藏，上班用的标签页不会跟着你过周末。边栏最下面一行用来切换空间：点按圆点、按 ⌃1–⌃9，或在边栏上用两指横向轻扫（窗口 › 下一个空间、上一个空间、新建空间…）。每个空间都有各自的标签页、标签页群组、个人收藏和固定的文件夹，并为边栏轻轻染上自己的颜色。书签资料库、历史记录和已存储的密码是共用的。创建空间时打开“单独保存登录和 Cookie（配置文件）”，它的 Cookie 和网站数据也会单独保存，这样同一个网站可以同时登录两个账户；之后无法更改，删除配置文件时也会清除它的 Cookie 和网站数据。第一个空间由你原有的数据创建。私密浏览窗口没有空间。AI 可以看到普通空间的标签页（并标明空间名称），但配置文件空间的标签页只有在你身处该空间时才看得到。

### 阅读与观看

- **阅读模式。** 把文章当作干净易读的文字来读。⇧⌘R（Chrome 风格快捷键下为 ⌥⌘R）会把它显示在页面上方。页面像文章时，地址栏会出现一个按钮。按 Esc、点 ×，或再按一次同一个快捷键，页面就会原样恢复。这由页面里的一小段脚本完成：文章里的图片仍从页面原本加载它们的地方加载，除此之外不会下载或发送任何内容。
- **翻译页面。** 不离开页面，就能读另一种语言的内容。直接在原页面上使用 macOS 的本地翻译完成（⌥⌘T，需要 macOS 26 或更高版本）。链接和版式保持不变，文本不会离开这台 Mac。
- **分屏浏览**（⌥⌘\\）。一个页面不够用时，把两个标签页并排显示。
- **专注模式**（⌘⇧F）。隐藏页面以外的所有内容。能不能专注，还得看你自己。
- **链接预览。** 不离开当前页面，先看一眼链接。⇧ 点按链接会在浮动卡片中打开，按 ⌘↩ 可保留为标签页。
- **画中画**（⌃⌘P）。离开标签页后仍能继续看视频。你离开正在播放视频的标签页时会自动开启。即使在其他 App 里，⌃⌘← / ⌃⌘→ 也能快退或快进 5 秒，点按“返回标签页”则会把该标签页切换到前台。

### 隐私与安全

- **私密浏览窗口。** 浏览完不留痕迹：Cookie 和网站数据只保存在内存中，关闭后即忘；不会写入历史记录、会话，也不会交给 AI。
- **网站设置。** 在一个地方查看和调整 Changmun 为每个网站记住的内容。点击地址栏左侧的锁形图标，会弹出一个小面板，汇总 Changmun 为该网站记住的内容：广告拦截、缩放、弹出式窗口、摄像头和麦克风，以及它的标签页能否休眠。点击地址栏的其他位置（包括网站名称）仍然是编辑地址。
- **密码。** 记密码是钥匙串的活儿，你不用操心。密码在你登录后保存到钥匙串（仅限 https），并通过地址栏中的钥匙按钮填入。拷贝密码需要触控 ID 或 Mac 密码验证。
- **弹出式窗口。** 页面别想不请自来地弹出窗口。未经点按就打开的弹出式窗口会被拦截，页面上方会显示“打开”和“始终允许此网站”。

广告和追踪器拦截见下面的[广告拦截](#广告拦截)，哪些内容留在你的 Mac 上、哪些会发送出去，见[隐私](#隐私)。

### 存储与下载

- **存储页面。** 把页面存成 PDF 或图片，留作日后查看。文件 › 存储为 PDF… 会把页面存成一页很长的 PDF，文件 › 捕获整个页面… 会把整个页面（而不只是屏幕上看到的部分）存成一张图片。两者也都在标签页的菜单中；除非另选位置，否则存储到“下载”文件夹，在私密浏览窗口中同样可用。在内部容器中滚动的页面和滚动时才加载的图片，可能无法完整捕获。
- **下载。** 随时看到下载进度，首次打开时还有安全检查。进度显示在边栏底部；下载的文件会带上 Safari 的隔离标记，因此首次打开时 Gatekeeper 会进行检查。App、脚本和安装程序只会在 Finder 中显示，不会直接运行。中断的下载可以在该行点按“重试”，从中断处继续。
- **页面缩放。** 调整一次，该网站就一直保持这个缩放。页面缩放按网站记忆，所以只需眯一次眼。
- **会话保存。** 浏览器也有崩溃的时候。已打开的标签页每 15 秒保存一次，所以崩溃几乎不会损失什么。

### 更新

- **更新提醒。** 有新版本时提醒你。Changmun 通过 Homebrew 更新。每天一次向 GitHub 查询最新版本，有新版本时边栏底部会出现一条安静的提示，可以帮你复制 `brew upgrade --cask changmun`。可在设置 › 高级 › 检查更新中关闭。

## AI

右侧的面板 (⌘E) 使用你已有的 `claude` CLI，因此直接消耗你的 Claude Code 订阅。默认模型是 Sonnet；可用 `defaults write io.github.namekun.Changmun aiModel opus` 切换。

AI 通过以下工具操作浏览器：`list_tabs`、`open_tab`、`switch_tab`、`close_tab`、`navigate`、`go_back`、`go_forward`、`reload`、`read_page`、`read_tabs`、`click`、`type_text`、`scroll`、`screenshot`。它无法读取或填写密码栏。

要跨多个标签页完成任务，可在聊天下方用“添加标签页”添加它们（逐个添加、整个标签页群组，或所有已打开的标签页）。添加的标签页显示为可移除的小标签，AI 会用 `read_tabs` 一并读取，读取前不再询问。添加两个或更多时，面板会建议比较它们，或分别总结每个标签页的要点。

为了避免页面里暗藏的指令让它把读到的内容带到别处，Changmun 会先征求你的同意（90 秒内没有回应则视为拒绝）：

- 使用你没在看的标签页之前，每个标签页和网站只问一次；
- 打开某个地址之前，除非是搜索、已经打开过、访问过或已加入书签的地址，或是知名网站的首页；
- 在对话已读取过其他网站之后，每一次输入之前都会询问，并显示它将要输入的内容。新建对话 (⌘⇧E) 会重新开始。

其他智能体（例如 Claude Code）也可以通过 MCP 使用同样的工具，同样会有这些询问：

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

如果 Changmun 没有运行，`--mcp` 会将其启动。控制服务器只监听 127.0.0.1，并需要一个每次启动都会变化的令牌。

任何能运行命令的代理也可以在 shell 中使用（Homebrew 会把 `changmun` 放到 PATH 中）：

```sh
changmun tabs
changmun open example.com
changmun read
changmun read-tabs 3 5
changmun click 12
changmun type 3 "hello" --submit
```

其余命令见 `changmun help`。每条命令调用一个相同的工具，经过同样的确认，必要时会启动 Changmun。

## 快捷键

可在设置 (⌘,) 中选择 Safari 风格或 Chrome 风格。只有两款浏览器不一致的按键会随之改变。

| 按键 | 操作 |
| --- | --- |
| ⌘T / ⌘L | 命令栏 / 编辑当前地址 |
| ⌘E / ⌘⇧E | AI 面板 / 新建 AI 对话 |
| ⌘D | 添加或移除个人收藏 |
| ⌘N / ⌘⇧N / ⌘⇧W | 新建窗口 / 新建私密浏览窗口 / 关闭窗口 |
| ⌘W、⌘1–9、⌘⇧[ ⌘⇧] | 关闭标签页，按边栏顺序切换到某个标签页 |
| ⌃Tab / ⌃⇧Tab | 按最近查看的顺序切换标签页（按住 ⌃，按下 Tab 后松开；esc 取消） |
| ⌃1–9 | 前往某个空间（9 为最后一个）。若你开启了 macOS 的“切换到桌面 N”，则以系统为准 |
| ⌃⌥← / ⌃⌥→ | 上一个 / 下一个空间 |
| ⌃⌘N | 新建空间 |
| ⌥⌘\\ | 开启或关闭分屏浏览 |
| ⇧ 点按 | 链接预览：esc 关闭，⌘↩ 在标签页中打开 |
| ⌘⇧T | 重新打开已关闭的标签页（没有标签页时则重新打开已关闭的窗口） |
| ⌃⌘M | 将标签页静音或取消静音 |
| ⌃⌘P | 开启或关闭画中画 |
| ⌃⌘← / ⌃⌘→ | 视频快退或快进 5 秒 |
| ⌥⌘T | 翻译页面 / 显示原文 |
| ⌘F、⌘G、⌘⇧G | 在页面中查找、下一个、上一个 |
| ⌘Y | 历史记录 |
| ⌘O、⌘P、⌘⇧C | 打开文件、打印、拷贝地址 |
| F12 或 ⌥⌘I | 网页检查器 |
| ⌘⇧F | 专注模式 |

| 操作 | Safari 风格 | Chrome 风格 |
| --- | --- | --- |
| 边栏 | ⌘⇧L | ⌘S |
| 强制重新载入 | ⌥⌘R | ⌘⇧R |
| 阅读模式 | ⇧⌘R | ⌥⌘R |
| 控制台 | ⌥⌘C | ⌥⌘J |
| 下载 | ⌥⌘L | ⌘⇧J |
| 上一个标签页 / 下一个标签页 | | ⌥⌘← ⌥⌘→ |

## 广告拦截

Changmun 会把 EasyList（广告）和 EasyPrivacy（跟踪器）转换为 WebKit 内容拦截规则，并每 4 天更新一次。在设置 › 隐私中，你可以关闭某些列表，或通过网址添加其他列表（一键即可添加韩国广告列表）。如果某个网站出现异常，可用地址栏中的盾牌按钮仅对该网站关闭拦截。WebKit 无法表达的规则（正则表达式、`$redirect`、scriptlet、`:has-text` 及其他扩展选择器）会被跳过，而不是凭猜测处理。漏掉一条广告，总好过把页面弄坏。

## 扩展

在设置 › 扩展中管理（网页扩展需要 macOS 15.4 或更高版本）。

在配置文件空间的标签页中，扩展可以运行，但扩展的 Cookie API 只能看到默认数据存储，看不到配置文件的。

- **来自 App Store 的 Safari 扩展**安装后会自动显示，开启时会请求所需权限。
- **Chrome 网上应用店的扩展**：打开扩展的商店页面，页面上方会出现“添加到 Changmun”（也可以在设置中粘贴其网址或 ID）。Changmun 会将其解包到 `~/Library/Application Support/Changmun/Extensions`，并作为 WebKit 扩展载入；再次添加即可更新。
- **Safari 内容拦截器**（Unicorn、AdGuard 等）：macOS 只允许 Safari 向拦截器索取规则，因此 Changmun 会读取拦截器保存的规则文件。macOS 会询问一次是否允许其读取其他 App 的数据。
- 未打包的扩展文件夹（含 `manifest.json`）同样可以载入。与原生 App 通信等部分功能可能无法使用。

## 从其他浏览器导入

首次启动时，或通过菜单，Changmun 可以从 Safari 和 Chromium 内核浏览器导入书签和历史记录：Chrome、Arc（含其边栏）、Dia、Aside、Whale、Brave、Edge、Vivaldi。对于 Chromium 内核浏览器，还会一并带入密码和 Cookie，让你保持登录。

- 密码和 Cookie 通过各浏览器的钥匙串项目（`<name> Safe Storage`）解密，因此 macOS 会请求你的许可。导入的密码会存入登录钥匙串，标签为 `Changmun`。
- 读取 Safari 需要完全磁盘访问权限。macOS 不会把 Safari 的密码交给其他 App。

## 隐私

- 你的浏览数据只保留在你的 Mac 上。Changmun 没有账号、服务器或统计分析。
- 检查更新每天一次向 GitHub 的公开发布 API 查询最新版本号，不会发送其他任何内容（可在设置 › 高级中关闭）。
- 搜索建议会把你在命令栏中输入的内容发送给你的搜索引擎（可在设置中关闭；私密浏览窗口中从不发送）。
- AI 面板会通过 `claude` CLI 把你的消息和 AI 读取的页面内容发送给 Anthropic。整理标签页和页面翻译都在你的 Mac 上运行。

## 面向开发者

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

界面文本在代码中是英文，翻译放在 `Resources/<language>.lproj/Localizable.strings` 中；新增的每条字符串都要加进全部六个表。

`scripts/headless.sh` 为测试和智能体运行无界面的 Changmun：不在屏幕上显示，从不抢占焦点或发出声音，使用 `~/Library/Application Support/Changmun Headless` 中独立的配置。它不会触碰钥匙串，并会自行应答 AI 确认、网站权限和 JavaScript 对话框（权限一律拒绝）。

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## 许可证

[MIT](LICENSE)
