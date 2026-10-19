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

*Changmun* (창문) is Korean for *window*. It's free, open source, and has no account or tracking. The app speaks English, Korean, Japanese, Simplified Chinese, Spanish, German and French.

## Install

```sh
brew install --cask namekun/tap/changmun
```

Needs [Homebrew](https://brew.sh), macOS 14 Sonoma or later and an Apple silicon Mac. Homebrew clears the quarantine flag, so the app opens right away. To update, run `brew update && brew upgrade --cask changmun`.

On first launch Changmun offers to bring over bookmarks, history, passwords and sign-ins from the browser you use now.

### Build from source

You need macOS 14 or later and Xcode or the Command Line Tools.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

With only the Command Line Tools installed, the scripts build against the macOS 26 SDK (the macOS 27 SDK's SwiftUI macro plugin ships only with Xcode). Build products go to `~/Library/Caches/Changmun/build`, out of reach of iCloud Desktop syncing.

## What it does

- **Sidebar.** Favorites as tiles, bookmark folders, vertical tabs. Drag tabs to reorder them, or onto the favorites to pin them. Favorites and bookmarks each keep their own tab, like Dia and Arc: clicking one goes to its tab instead of replacing the one you're reading (⌘-click opens a new tab). Drag a link from a page onto the sidebar to open it as a tab, make it a favorite or file it in a folder. A tab's menu also reloads, duplicates, moves it to a new window, shares it or opens it in another browser. Closing a group's tabs or removing a bookmark can be undone for a few seconds.
- **Address bar where you like.** At the top of the sidebar beside back and forward, as in Arc, or above the page, as in Dia: Settings › Appearance › Address Bar Position. It shows just the site; the shield comes up when the pointer is over it, and so does the star, which stays for a favorite: click it to take the page out of the favorites.
- **Bookmark folders.** Imported folders keep their nesting, as in the browser they came from. Pin the ones you use to the sidebar (right-click or … › Pin to Sidebar, or drag the folder up under the favorites) and open them right there. Drag a bookmark onto another folder or onto the favorites, or use Move To in its menu. The rest of your bookmarks are behind the bookmark button at the bottom of the sidebar, with a search field; the … beside it opens History, Archived Tabs, Focus Mode and Settings.
- **Tab groups.** Right-click a tab › Add to New Group, name it, fold it. Tabs opened from a group's tab join the group; a reopened tab (⌘⇧T) goes back to its group.
- **Tidy tabs.** The wand next to "New Tab" (Window › Tidy Tabs) groups the loose tabs. With Apple Intelligence on (macOS 26), the model on your Mac groups them by topic and names the groups; nothing about your tabs leaves the Mac. Without it, tabs opened from one another and tabs of one site go together. "Undo" puts things back for a few seconds. New tabs you open from the address bar join a matching group on their own (turn it off in Settings › Tabs).
- **Archive old tabs** (off by default). Tabs you haven't looked at for a set time (12 hours to 30 days, counted only while Changmun runs) close into History › Archived Tabs, ready to reopen into their group. Visible, playing, picture-in-picture, camera/mic, favorite and private tabs are never archived.
- **Split view** (⌥⌘\\) shows two tabs side by side. **Focus mode** (⌘⇧F) hides everything but the page. **Link preview**: ⇧-click a link to open it in a floating card, ⌘↩ to keep it as a tab.
- **Private windows** keep their cookies and site data in memory and forget them when closed; nothing goes to history, the session or the AI.
- **Command bar** (⌘T): search, addresses, switching to open tabs, bookmarks and history, and asking the AI.
- **Translate pages** in place with macOS's on-device translation (⌥⌘T, macOS 26+). Links and layout stay; the text never leaves the Mac.
- **Site settings.** Click the lock icon at the left of the address bar for a small panel with what Changmun keeps for that site: ad blocking, zoom, pop-ups, camera and microphone, and whether its tabs may sleep. Click anywhere else on the address bar, the site name included, to edit the address, as before.
- **Reader mode** (⇧⌘R, or ⌥⌘R with Chrome-style shortcuts) shows an article as clean, readable text over the page. A button appears in the address bar when the page looks like an article. Esc, the ×, or the same key brings the page back as it was. A small script on the page does it: the article's images load from the same places the page loads them from, and nothing else is downloaded or sent.
- **Picture in picture** (⌃⌘P) turns on by itself when you leave a tab with a playing video. ⌃⌘← / ⌃⌘→ skip 5 seconds even while you're in another app, and "Back to tab" brings the tab forward.
- **Passwords** are saved to the Keychain after you sign in (https only) and filled from the key in the address bar. Copying one asks for Touch ID or your Mac password.
- **Pop-ups** opened without a click are blocked, with "Open" and "Always Allow for This Site" right above the page.
- **Downloads** show their progress at the bottom of the sidebar and get Safari's quarantine flag, so Gatekeeper checks them on first open. Apps, scripts and installers are shown in Finder instead of run. A download that breaks off picks up from where it stopped with Try Again on its row.
- **Sleeping tabs.** Background tabs you haven't seen in 20 minutes, and all background tabs under memory pressure, give back their web process and come back with their history when you return.
- Page zoom is remembered per site, and open tabs are saved every 15 seconds, so a crash costs almost nothing.
- **Update notice.** Changmun is updated through Homebrew. Once a day it asks GitHub for the latest release, and when there's a newer one a quiet note at the bottom of the sidebar copies `brew upgrade --cask changmun` for you. Turn it off in Settings › Advanced › Check for Updates.

## Shortcuts

Pick Safari-style or Chrome-style in Settings (⌘,). Only the keys the two browsers disagree on change.

| Keys | Action |
| --- | --- |
| ⌘T / ⌘L | Command bar / edit the current address |
| ⌘E / ⌘⇧E | AI panel / new AI chat |
| ⌘D | Add or remove a favorite |
| ⌘N / ⌘⇧N / ⌘⇧W | New window / new private window / close window |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | Close tab, go to a tab in sidebar order |
| ⌃Tab / ⌃⇧Tab | Switch tabs in the order you last saw them (hold ⌃, press Tab, let go; esc cancels) |
| ⌥⌘\\ | Split view on or off |
| ⇧-click | Link preview: esc closes, ⌘↩ opens it as a tab |
| ⌘⇧T | Reopen closed tab (or the closed window when no tab is left) |
| ⌃⌘M | Mute or unmute the tab |
| ⌃⌘P | Picture in picture on or off |
| ⌃⌘← / ⌃⌘→ | Video back or forward 5 seconds |
| ⌥⌘T | Translate the page / show the original |
| ⌘F, ⌘G, ⌘⇧G | Find on page, next, previous |
| ⌘Y | History |
| ⌘O, ⌘P, ⌘⇧C | Open file, print, copy the address |
| F12 or ⌥⌘I | Web Inspector |
| ⌘⇧F | Focus mode |

| Action | Safari-style | Chrome-style |
| --- | --- | --- |
| Sidebar | ⌘⇧L | ⌘S |
| Hard reload | ⌥⌘R | ⌘⇧R |
| Reader mode | ⇧⌘R | ⌥⌘R |
| Console | ⌥⌘C | ⌥⌘J |
| Downloads | ⌥⌘L | ⌘⇧J |
| Previous Tab / Next Tab | | ⌥⌘← ⌥⌘→ |

## AI

The panel on the right (⌘E) uses the `claude` CLI you already have, so it runs on your Claude Code subscription. The default model is Sonnet; switch with `defaults write io.github.namekun.Changmun aiModel opus`.

The AI works the browser through these tools: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. It can't read or fill password fields.

So that instructions hidden in a page can't make it carry what it read somewhere else, Changmun asks you first (and says no after 90 seconds without an answer):

- before it uses a tab you aren't looking at, once per tab and site;
- before it opens an address, unless it's a search, an address already open, visited or bookmarked, or a known site's front page;
- before every bit of typing once the chat has read another site, showing what it will type. A new chat (⌘⇧E) starts over.

Other agents, like Claude Code, can use the same tools through MCP, with the same questions:

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` starts Changmun if it isn't running. The control server listens only on 127.0.0.1 and needs a token that changes every launch.

Or from a shell, for any agent that can run commands (Homebrew puts `changmun` on the PATH):

```sh
changmun tabs
changmun open example.com
changmun read
changmun click 12
changmun type 3 "hello" --submit
```

`changmun help` lists the rest. Each command is one of the same tools, with the same questions, and starts Changmun if needed.

## Ad blocking

Changmun turns EasyList (ads) and EasyPrivacy (trackers) into WebKit content-blocking rules and refreshes them every 4 days. In Settings › Privacy you can turn lists off or add others by address (a Korean ad list is one click away). If a site breaks, the shield in the address bar turns blocking off for that site. Rules WebKit can't express (regular expressions, `$redirect`, scriptlets, `:has-text` and other extended selectors) are skipped rather than guessed.

## Extensions

Managed in Settings › Extensions (web extensions need macOS 15.4 or later).

- **Safari extensions from the App Store** show up once installed and ask for their permissions when you turn them on.
- **Chrome Web Store extensions**: open an extension's store page and "Add to Changmun" appears above it (or paste its address or ID in Settings). Changmun unpacks it into `~/Library/Application Support/Changmun/Extensions` and loads it as a WebKit extension; adding it again updates it.
- **Safari content blockers** (Unicorn, AdGuard and others): macOS only lets Safari ask a blocker for its rules, so Changmun reads the rule file the blocker saved. macOS asks once to let it read another app's data.
- An unpacked extension folder (with `manifest.json`) loads too. Some features, like talking to a native app, may not work.

## Importing from other browsers

On first launch, or from the menu, Changmun imports bookmarks and history from Safari and from Chromium browsers: Chrome, Arc (with its sidebar), Dia, Aside, Whale, Brave, Edge, Vivaldi. From Chromium browsers it also brings passwords and cookies, so you stay signed in.

- Passwords and cookies are decrypted with each browser's Keychain item (`<name> Safe Storage`), so macOS asks you to allow it. Imported passwords go to your login Keychain labeled `Changmun`.
- Reading Safari needs Full Disk Access. macOS doesn't hand Safari's passwords to other apps.

## Privacy

- Your browsing stays on your Mac. Changmun has no account, server or analytics.
- The update check asks GitHub's public releases API for the latest version number once a day and sends nothing else (Settings › Advanced turns it off).
- Search suggestions send what you type in the command bar to your search engine (turn them off in Settings; never sent from private windows).
- The AI panel sends your messages, and the page content the AI reads, to Anthropic through the `claude` CLI. Tidy tabs and page translation run on your Mac.

## For developers

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

UI text is English in the code and translated in `Resources/<language>.lproj/Localizable.strings`; add every new string to all six tables.

`scripts/headless.sh` runs a headless Changmun for tests and agents: off screen, never takes focus or plays sound, with its own profile in `~/Library/Application Support/Changmun Headless`. It doesn't touch the Keychain, and answers AI confirmations, site permissions and JavaScript dialogs by itself (permissions are denied).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## License

[MIT](LICENSE)
