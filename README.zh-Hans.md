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

*Changmun*（창문）在韩语中是“窗户”的意思。它免费、开源，无需账号。App 支持英语、韩语、日语、简体中文、西班牙语、德语和法语。

## 安装

```sh
brew install --cask namekun/tap/changmun
```

或者[直接下载 App](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg)。

- 需要搭载 Apple 芯片的 Mac，系统为 macOS 14 或更高版本。
- 已由 Apple 签名并公证，下载后可直接打开。
- 会自动更新。
- 首次启动时，会询问是否导入你的书签和历史记录。

## 为什么选择 Changmun

- **轻巧。** App 只有 21 MB，下载约 7 MB。它直接使用你的 Mac 上已有的 WebKit 引擎。
- **有边栏。** 垂直标签页、个人收藏、书签文件夹、标签页群组和空间集中在一列。想把标签页放在顶部？在设置里改就行。
- **会使用浏览器的 AI。** Claude 会读取页面，替你点按、输入；遇到有风险的操作，会先询问。
- **注重隐私。** 无需账号，没有服务器，也没有统计分析。广告和追踪器默认就会被拦截。
- **你的东西能带走。** 可以从 Safari 和 Chromium 内核浏览器导入书签和历史记录，并从 Chromium 内核浏览器导入密码。
- **专属的起始页。** 三种样式，板块可以自由排列，背景也由你来选。

## AI

按下 ⌘E，用平常说话的方式提要求就行：

- “总结一下这个页面。”
- “比较这三个标签页里的价格。”
- “帮我登录这个网站。”

它通过你已有的 `claude` CLI 运行，所以用的是你自己的 Claude Code 订阅。如果你不用 Claude，可以不理这个面板，浏览器的其他功能不依赖它。

**有哪些约束**

- 付款、发送、发布或删除之前，它会先询问。
- 要使用你没在看的标签页，或打开陌生网站之前，它会先询问。
- 它看不到密码，也绝不会看到私密浏览窗口。

你的消息、附上的图片和它读取的页面，会通过 `claude` CLI 发送给 Anthropic。其他工具也可以通过 MCP 或 `changmun` 命令来操控 Changmun。

## 与其他浏览器对比

Changmun 并不想在所有方面胜过所有浏览器。下面列出它的不同之处，以及什么时候用别的浏览器更合适。

| | App 大小 | 引擎 |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21 MB** | WebKit，macOS 自带的那一个 |
| Safari 27 | 35 MB | WebKit，macOS 自带的那一个 |
| Google Chrome 156 | 731 MB | Chromium，自带一份 |
| Arc 1.168 | 862 MB | Chromium，自带一份 |
| Dia 1.53 | 1.3 GB | Chromium，自带一份 |

<sub>2026 年 10 月，在一台搭载 Apple 芯片的 Mac 上用 `du -sh` 测得。</sub>

| 对比对象 | Changmun 带给你的 | 如果你需要这些，就留在原来的浏览器 |
| :-- | :-- | :-- |
| **Safari** | 同一个引擎，外加带垂直标签页的边栏、能操作页面的 AI，以及 Chrome 网上应用店的扩展 | 通过 iCloud 同步标签页、密码和通行密钥 |
| **Chrome** | 没有 Google 账号和同步服务器，App 体积约为它的 3% | 仅为 Chromium 开发的网站、Chrome 同步，或者 Windows、Linux 和手机 |
| **Arc** | 同样的边栏加空间的思路，而且仍在增加功能（Arc 自 2025 年 5 月起处于维护模式） | Boosts 或 Easels |
| **Dia** | 同一路思路，但没有自己的 AI 服务，也无需账号：用的是你的 `claude` CLI | 它的托管 AI 功能和面向工作的集成 |

以上内容来自各个项目对自己的说明。如有过时之处，请[提交 issue](https://github.com/namekun/Changmun/issues)。

### 还没有的

- **没有同步。** 书签、历史记录和密码只留在创建它们的那台 Mac 上。
- **仅限 Mac。** 没有 iPhone、Windows 或 Linux 版本。
- **暂无通行密钥。** 浏览器需要 Apple 授予一项权限（entitlement）才能支持，Changmun 已经申请，正在等待。
- **扩展需要 macOS 15.4 或更高版本，** 而且有些 Chrome 扩展依赖 WebKit 没有的功能。
- **仅为 Chromium 开发的网站**在这里可能表现异常，在 Safari 里也一样。
- **只有一位维护者。** 比大型浏览器少了许多双眼睛，粗糙之处自然也多。欢迎提交 bug 报告。

## 值得记住的快捷键

| 按键 | 作用 |
| :-- | :-- |
| ⌘T | 新建标签页 |
| ⌘L | 编辑地址 |
| ⌘E | AI 面板 |
| ⌘D | 添加或移除个人收藏 |
| ⌃1–9 | 前往某个空间 |
| ⌥⌘\\ | 分屏浏览 |
| ⇧ 点按链接 | 不离开当前页面，直接预览 |
| ⌘⇧T | 重新打开已关闭的标签页 |

想用 Safari 风格还是 Chrome 风格的按键？在设置 (⌘,) 里选。[所有快捷键](GUIDE.zh-Hans.md#快捷键)。

## 隐私

你的浏览内容只留在你的 Mac 上。App 自己发出的请求很少，例如检查更新、刷新广告过滤列表。搜索建议会把你输入的内容发给你的搜索引擎；可以关闭，私密浏览窗口也从不发送。[发送了什么、何时发送](GUIDE.zh-Hans.md#隐私)。

## 了解更多

[指南](GUIDE.zh-Hans.md)详细介绍了所有内容：

- [功能](GUIDE.zh-Hans.md#功能一览)：标签页、空间、阅读模式、私密浏览窗口、下载
- [AI](GUIDE.zh-Hans.md#ai)：模型、批准、工具、MCP 和命令行
- [广告拦截](GUIDE.zh-Hans.md#广告拦截)、[扩展](GUIDE.zh-Hans.md#扩展)和[从其他浏览器导入](GUIDE.zh-Hans.md#从其他浏览器导入)
- [密码与安全](GUIDE.zh-Hans.md#密码与安全)
- [面向开发者](GUIDE.zh-Hans.md#面向开发者)和[从源码构建](GUIDE.zh-Hans.md#从源码构建)

## 许可证

MIT。见 [LICENSE](LICENSE)。
