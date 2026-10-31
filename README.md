<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmun icon"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>A light Mac browser with a sidebar and an AI that can use it.</b><br>
  Safari's WebKit engine, vertical tabs, favorites and bookmark folders on the left, and a Claude panel that reads pages, clicks and types for you.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="Native Swift">
</p>

<p align="center">
  <b>English</b> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="Changmun window with vertical tabs in the sidebar and a page card">
</p>

*Changmun* (창문) is Korean for *window*. It's free, open source and needs no account. The app speaks English, Korean, Japanese, Simplified Chinese, Spanish, German and French.

## Install

```sh
brew install --cask namekun/tap/changmun
```

Or [download the app](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg) directly.

- Needs macOS 14 or later on an Apple silicon Mac.
- Signed and notarized by Apple, so it opens right away.
- Updates itself.
- On first launch it offers to bring over your bookmarks and history.

## Why use it

- **Light.** A 21 MB app, about 7 MB to download. It uses the WebKit engine already on your Mac.
- **A sidebar.** Vertical tabs, favorites, bookmark folders, tab groups and spaces in one column. Prefer tabs on top? That's a setting.
- **An AI that uses the browser.** Claude reads pages, clicks and types for you, and asks before anything risky.
- **Private.** No account, no server, no analytics. Ads and trackers are blocked out of the box.
- **Your stuff comes along.** Imports bookmarks and history from Safari and Chromium browsers, and passwords from the Chromium ones.
- **A start page of your own.** Three styles, sections you can arrange, and your own background.

## The AI

Press ⌘E and ask in plain words:

- "Summarize this page."
- "Compare the prices in these three tabs."
- "Sign me in to this site."

It runs on the `claude` CLI you already have, so it uses your own Claude Code subscription. If you don't use Claude, you can ignore the panel: the rest of the browser works without it.

**What keeps it in check**

- It asks before it pays, sends, posts or deletes.
- It asks before it uses a tab you aren't looking at or opens an unfamiliar site.
- It can't see passwords, and it never sees private windows.

Your messages, the images you attach and the pages it reads go to Anthropic through the `claude` CLI. Other tools can drive Changmun too, over MCP or the `changmun` command.

## How it compares

Changmun doesn't try to beat every browser at everything. Here is where it differs, and when you are better off elsewhere.

| | App size | Engine |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21 MB** | WebKit, built into macOS |
| Safari 27 | 35 MB | WebKit, built into macOS |
| Google Chrome 156 | 731 MB | Chromium, its own copy |
| Arc 1.168 | 862 MB | Chromium, its own copy |
| Dia 1.53 | 1.3 GB | Chromium, its own copy |

<sub>Measured with `du -sh` on one Apple silicon Mac in October 2026.</sub>

| Compared with | What Changmun gives you | Stay with it if you need |
| :-- | :-- | :-- |
| **Safari** | The same engine, plus a sidebar with vertical tabs, an AI that can work a page, and Chrome Web Store extensions | iCloud sync of tabs, passwords and passkeys |
| **Chrome** | No Google account or sync server, and an app about 3% of the size | Sites built only for Chromium, Chrome sync, or Windows, Linux and phones |
| **Arc** | The same sidebar-and-spaces idea, still gaining features (Arc has been in maintenance mode since May 2025) | Boosts or Easels |
| **Dia** | The same family of ideas, with no AI service of its own and no account: it uses your `claude` CLI | Its hosted AI features and workplace integrations |

These come from what each project says about itself. If something is out of date, please [open an issue](https://github.com/namekun/Changmun/issues).

### Not there yet

- **No sync.** Bookmarks, history and passwords stay on the Mac they were made on.
- **Mac only.** No iPhone, Windows or Linux.
- **No passkeys yet.** Browsers need an entitlement from Apple; Changmun has asked and is waiting.
- **Extensions need macOS 15.4 or later,** and some Chrome extensions rely on things WebKit doesn't have.
- **Sites built only for Chromium** can misbehave here, as they can in Safari.
- **One maintainer.** Fewer eyes than the big browsers, and rough edges to match. Bug reports are welcome.

## Keys worth knowing

| Keys | What it does |
| :-- | :-- |
| ⌘T | New tab |
| ⌘L | Edit the address |
| ⌘E | AI panel |
| ⌘D | Add or remove a favorite |
| ⌃1–9 | Go to a space |
| ⌥⌘\\ | Split view |
| ⇧-click a link | Preview it without leaving the page |
| ⌘⇧T | Reopen a closed tab |

Safari-style or Chrome-style keys? Pick in Settings (⌘,). [All shortcuts](GUIDE.md#shortcuts).

## Privacy

Your browsing stays on your Mac. The app makes only a few requests of its own, such as checking for updates and refreshing the ad filter lists. Search suggestions send what you type to your search engine; you can turn them off, and private windows never send them. [Everything that is sent, and when](GUIDE.md#privacy).

## Learn more

The [guide](GUIDE.md) covers everything in detail:

- [Features](GUIDE.md#what-it-does): tabs, spaces, reader mode, private windows, downloads
- [AI](GUIDE.md#ai): models, approvals, tools, MCP and the command line
- [Ad blocking](GUIDE.md#ad-blocking), [extensions](GUIDE.md#extensions) and [importing from other browsers](GUIDE.md#importing-from-other-browsers)
- [Passwords and security](GUIDE.md#passwords-and-security)
- [For developers](GUIDE.md#for-developers) and [building from source](GUIDE.md#build-from-source)

## License

MIT. See [LICENSE](LICENSE).
