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

*Changmun*（창문）在韩语中是“窗户”的意思。它免费、开源，无需账号，也不做任何追踪。App 支持英语、韩语、日语、简体中文、西班牙语、德语和法语。

## 安装

```sh
brew install --cask namekun/tap/changmun
```

需要 [Homebrew](https://brew.sh)、macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片的 Mac。Homebrew 会清除隔离标记，所以 App 可以直接打开。更新时运行 `brew update && brew upgrade --cask changmun`。

首次启动时，Changmun 会询问是否从你现在使用的浏览器导入书签、历史记录、密码和登录状态。

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

- **边栏。** 个人收藏以磁贴显示，下面是书签文件夹和垂直标签页。拖移标签页可调整顺序，拖到个人收藏上则可固定。和 Dia、Arc 一样，个人收藏和书签各自保留自己的标签页：点按它们会切换到对应的标签页，而不是替换你正在阅读的页面（按住 ⌘ 点按则新建标签页）。 把页面上的链接拖到边栏即可作为标签页打开，拖到个人收藏或文件夹上则会存进去。标签页菜单还能重新载入、复制、移到新窗口、共享或用其他浏览器打开。关闭整个组的标签页或删除书签后，几秒内可以撤销。
- **地址栏位置。** 可以像 Arc 一样放在边栏顶部的后退、前进按钮下方，也可以像 Dia 一样放在页面上方：设置 › 外观 › 地址栏位置。只显示网站名称，指针移上去时才出现盾牌和星标。个人收藏中的页面会一直显示星标，点按即可移出个人收藏。
- **书签文件夹。** 导入的文件夹保留原来浏览器中的层级。常用的文件夹可以固定到边栏（右键点按或 … › 固定到边栏，或把文件夹拖到个人收藏下方），直接在原处展开。把书签拖到其他文件夹或个人收藏上，或用菜单里的移到来移动。 其余书签在边栏底部的书签按钮中，并可搜索；旁边的 … 按钮可打开历史记录、已归档的标签页、专注模式和设置。
- **标签页群组。** 右键点按标签页 › 添加到新群组，起个名字，还能折叠。从群组内的标签页打开的标签页会加入该群组；用 ⌘⇧T 重新打开的标签页会回到原来的群组。
- **整理标签页。** “新建标签页”旁边的魔杖按钮（窗口 › 整理标签页）会把零散的标签页分组。开启 Apple Intelligence（macOS 26）后，由你 Mac 上的模型按主题分组并为群组命名，标签页的任何信息都不会离开这台 Mac。未开启时，互相打开的标签页和同一网站的标签页会分在一起。“撤销”可在几秒内恢复原状。从地址栏打开的新标签页会自动加入匹配的群组（可在设置 › 标签页中关闭）。
- **归档旧标签页**（默认关闭）。超过设定时间（12 小时到 30 天，仅在 Changmun 运行期间计时）没有查看的标签页，会关闭并收进历史记录 › 已归档的标签页，随时可以重新打开并回到原来的群组。正在显示、正在播放、画中画、正在使用摄像头或麦克风、个人收藏以及私密浏览的标签页永远不会被归档。
- **分屏浏览**（⌥⌘\\）并排显示两个标签页。**专注模式**（⌘⇧F）隐藏页面以外的所有内容。**链接预览**：⇧ 点按链接会在浮动卡片中打开，按 ⌘↩ 可保留为标签页。
- **私密浏览窗口**把 Cookie 和网站数据保存在内存中，关闭后即忘；不会写入历史记录、会话，也不会交给 AI。
- **命令栏**（⌘T）：搜索、输入地址、切换到已打开的标签页、查找书签和历史记录，以及向 AI 提问。
- **翻译页面**直接在原页面上使用 macOS 的本地翻译完成（⌥⌘T，需要 macOS 26 或更高版本）。链接和版式保持不变，文本不会离开这台 Mac。
- **网站设置。** 点击地址栏里的锁形图标和网站名称，会弹出一个小面板，汇总 Changmun 为该网站记住的内容：广告拦截、缩放、弹出式窗口、摄像头和麦克风，以及它的标签页能否休眠。点击地址栏的其他位置仍然是编辑地址。
- **阅读模式**（⇧⌘R，Chrome 风格快捷键下为 ⌥⌘R）把文章以干净易读的文字显示在页面上方。页面像文章时，地址栏会出现一个按钮。按 Esc、点 ×，或再按一次同一个快捷键，页面就会原样恢复。这由页面里的一小段脚本完成，不会下载或发送任何内容。
- **画中画**（⌃⌘P）会在你离开正在播放视频的标签页时自动开启。即使在其他 App 里，⌃⌘← / ⌃⌘→ 也能快退或快进 5 秒，点按“返回标签页”则会把该标签页切换到前台。
- **密码**在你登录后保存到钥匙串（仅限 https），并通过地址栏中的钥匙按钮填入。拷贝密码需要触控 ID 或 Mac 密码验证。
- **弹出式窗口**若未经点按就打开会被拦截，页面上方会显示“打开”和“始终允许此网站”。
- **下载**的进度显示在边栏底部，并带有 Safari 的隔离标记，因此首次打开时 Gatekeeper 会进行检查。App、脚本和安装程序只会在 Finder 中显示，不会直接运行。 中断的下载可以在该行点按“重试”，从中断处继续。
- **休眠标签页。** 20 分钟没有查看的后台标签页，以及内存紧张时的所有后台标签页，都会释放其网页进程，当你回来时连同历史记录一起恢复。
- 页面缩放按网站记忆，已打开的标签页每 15 秒保存一次，因此即使崩溃也几乎不会损失什么。
- **更新提醒。** Changmun 通过 Homebrew 更新。每天一次向 GitHub 查询最新版本，有新版本时侧边栏底部会出现一条安静的提示，可以帮你复制 `brew upgrade --cask changmun`。可在设置 › 高级 › 检查更新中关闭。

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

## AI

右侧的面板 (⌘E) 使用你已有的 `claude` CLI，因此直接消耗你的 Claude Code 订阅。默认模型是 Sonnet；可用 `defaults write io.github.namekun.Changmun aiModel opus` 切换。

AI 通过以下工具操作浏览器：`list_tabs`、`open_tab`、`switch_tab`、`close_tab`、`navigate`、`go_back`、`go_forward`、`reload`、`read_page`、`click`、`type_text`、`scroll`、`screenshot`。它无法读取或填写密码栏。

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
changmun click 12
changmun type 3 "hello" --submit
```

其余命令见 `changmun help`。每条命令调用一个相同的工具，经过同样的确认，必要时会启动 Changmun。

## 广告拦截

Changmun 会把 EasyList（广告）和 EasyPrivacy（跟踪器）转换为 WebKit 内容拦截规则，并每 4 天更新一次。在设置 › 隐私中，你可以关闭某些列表，或通过网址添加其他列表（一键即可添加韩国广告列表）。如果某个网站出现异常，可用地址栏中的盾牌按钮仅对该网站关闭拦截。WebKit 无法表达的规则（正则表达式、`$redirect`、scriptlet、`:has-text` 及其他扩展选择器）会被跳过，而不是凭猜测处理。

## 扩展

在设置 › 扩展中管理（网页扩展需要 macOS 15.4 或更高版本）。

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
