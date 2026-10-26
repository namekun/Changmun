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

*Changmun* (창문) is Korean for *window*, which is about as honest as a browser name gets. It's free, open source, and has no account or tracking. The app speaks English, Korean, Japanese, Simplified Chinese, Spanish, German and French.

## Why Changmun

- **Light.** Chromium browsers each bundle their own copy of Chromium. Changmun borrows the WebKit engine already on your Mac, the one Safari uses, so the download is about 3 MB (the 0.4.1 DMG is 2.6 MB). It's easy on the battery, and engine security fixes arrive with macOS and Safari updates.
- **A sidebar like Arc and Dia.** Vertical tabs, which give titles room to breathe, plus favorites as tiles, bookmark folders, tab groups and spaces. Prefer a tab strip across the top? That's a setting.
- **An AI that uses the browser.** The Claude panel reads pages and clicks and types for you through your existing `claude` CLI. It gets hands, not a free pass: it asks before anything risky.
- **Private by default.** No account, server or analytics, so there's nothing to sign up for. Ad and tracker blocking is built in.
- **Comes with your stuff.** Imports bookmarks and history from Safari and Chromium browsers, plus passwords and sign-ins from the Chromium ones. Moving in, furniture included, except Safari's passwords, which macOS won't hand over.

## Install

```sh
brew install --cask namekun/tap/changmun
```

Needs [Homebrew](https://brew.sh), macOS 14 Sonoma or later and an Apple silicon Mac. The app is signed with a Developer ID and notarized by Apple, so it opens right away. Updates arrive inside the app (Changmun › Check for Updates…, automatic by default), so Homebrew is only needed to install.

On first launch Changmun offers to bring over bookmarks and history from the browser you use now, plus passwords and sign-ins if it's a Chromium browser.

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

### Sidebar and tabs

- **Sidebar.** Favorites, bookmarks and open tabs share one column on the left: favorites as tiles, bookmark folders, vertical tabs. Drag tabs to reorder them, or onto the favorites to pin them. Favorites and bookmarks each keep their own tab, like Dia and Arc: clicking one goes to its tab instead of replacing the one you're reading (⌘-click opens a new tab). Drag a link from a page onto the sidebar to open it as a tab, make it a favorite or file it in a folder. A tab's menu also reloads, duplicates, moves it to a new window, shares it or opens it in another browser. To give a tab a name of your own, double-click its title or choose Rename Tab… from its menu; the name stays through new pages and restarts, and the AI still sees the page's real title. Bookmarks and bookmark folders rename the same way (double-click, or Rename… from the menu) and favorites from their menu; the name you give stays even if you import from that browser again. Closing a group's tabs or removing a bookmark can be undone for a few seconds, which is usually when the regret arrives.
- **Address bar where you like.** Put it where your hands expect it: at the top of the sidebar below back and forward, as in Arc, or above the page, as in Dia (Settings › Appearance › Address Bar Position). It shows just the site; the shield comes up when the pointer is over it, and so does the star, which stays for a favorite: click it to take the page out of the favorites.
- **Tabs on top.** Prefer a strip to a column? Choose On Top in Settings › Appearance › Tab Layout. A horizontal tab strip sits above the address bar: favorites first as icon-only tiles, then the space's tabs with favicon, title, close × and an audio indicator. A tab group is a coloured chip that folds the group away (the tab you're viewing stays shown). The + button stays visible when the tabs overflow and the strip scrolls sideways. Middle-click closes a tab, drag to reorder, double-click to rename, and the context menus are the sidebar's. The sidebar (bookmarks, spaces, downloads, menu) opens over the page from the button at the left of the address bar. Sidebar is the default and works as described here.
- **Bookmark folders.** Your bookmarks keep the filing system you built, and stay within reach. Imported folders keep their nesting, as in the browser they came from. Pin the ones you use to the sidebar (right-click or … › Pin to Sidebar, or drag the folder up under the favorites) and open them right there. Drag a bookmark onto another folder or onto the favorites, or use Move To in its menu. The rest of your bookmarks are behind the bookmark button at the bottom of the sidebar, with a search field; the … beside it opens History, Archived Tabs, Focus Mode and Settings.
- **Tab groups.** Related tabs stay together and out of the way. Right-click a tab › Add to New Group, name it, fold it; double-click a group's header (or its chip in the tab strip) to rename it. Tabs opened from a group's tab join the group; a reopened tab (⌘⇧T) finds its way back to its group. Drag a group by its header to move it, or up onto the favorites or the pinned folders to keep it, tabs and all, as one bookmark folder.
- **Tidy tabs.** Turns a pile of loose tabs into groups in one click. Wave the wand next to "New Tab" (Window › Tidy Tabs) and the loose tabs get grouped. With Apple Intelligence on (macOS 26), the model on your Mac groups them by topic and names the groups; nothing about your tabs leaves the Mac. Without it, tabs opened from one another and tabs of one site go together. "Undo" puts things back for a few seconds. New tabs you open from the address bar join a matching group on their own (turn it off in Settings › Tabs).
- **Archive old tabs** (off by default). Tabs you've stopped using get put away, not thrown away. Tabs you haven't looked at for a set time (12 hours to 30 days, counted only while Changmun runs) close into History › Archived Tabs, ready to reopen into their group. Visible, playing, picture-in-picture, camera/mic, favorite and private tabs are never archived.
- **Sleeping tabs.** Lets background tabs nap and hands their memory back. Background tabs you haven't seen in 20 minutes, and all background tabs under memory pressure, give back their web process and come back with their history when you return.
- **Command bar** (⌘T). One box, many errands: search, addresses, switching to open tabs, bookmarks and history, and asking the AI.

### Spaces and profiles

- **Spaces.** Separate sets of tabs, tab groups and favorites for different kinds of browsing, so work stays out of your weekend. The row at the bottom of the sidebar switches between spaces: click a dot, press ⌃1–⌃9, or swipe sideways with two fingers over the sidebar (Window › Next Space, Previous Space, New Space…). Each space has its own tabs, tab groups, favorites and pinned folders, and tints the sidebar with its colour. The bookmark library, history and saved passwords are shared. Turn on "Keep logins and cookies separate (profile)" when you make a space to give it its own cookies and site data too, so one site can have two accounts signed in side by side; that can't be changed afterwards, and deleting a profile erases its cookies and site data. Your first space is made from what you already had. Private windows have no spaces. The AI sees the tabs of ordinary spaces (with the space's name), but those of a profile space only while you're in it.

### Reading and watching

- **Reader mode.** Strips an article down to clean, readable text. ⇧⌘R (or ⌥⌘R with Chrome-style shortcuts) shows it over the page. A button appears in the address bar when the page looks like an article. Esc, the ×, or the same key brings the page back as it was. A small script on the page does it: the article's images load from the same places the page loads them from, and nothing else is downloaded or sent.
- **Translate pages.** Read a page in another language without leaving it. It's translated in place with macOS's on-device translation (⌥⌘T, macOS 26+). Links and layout stay; the text never leaves the Mac.
- **Split view** (⌥⌘\\). Two tabs side by side, for the times one page isn't enough.
- **Focus mode** (⌘⇧F). Hides everything but the page. Staying focused on it is up to you.
- **Link preview.** Peek at a link without leaving the page you're on. ⇧-click a link to open it in a floating card, ⌘↩ to keep it as a tab.
- **Picture in picture** (⌃⌘P). Keeps a video in view after you leave its tab. It turns on by itself when you leave a tab with a playing video. ⌃⌘← / ⌃⌘→ skip 5 seconds even while you're in another app, and "Back to tab" brings the tab forward.

### Privacy and safety

- **Private windows.** Browse without leaving anything behind. Private windows keep their cookies and site data in memory and forget them when closed; nothing goes to history, the session or the AI.
- **Site settings.** What Changmun remembers about a site, shown and changed in one place. Click the lock icon at the left of the address bar for a small panel with what Changmun keeps for that site: ad blocking, zoom, pop-ups, camera and microphone, and whether its tabs may sleep. Click anywhere else on the address bar, the site name included, to edit the address, as before.
- **Passwords.** Remembering them is the Keychain's job. Passwords are saved to the Keychain after you sign in (https only) and filled from the key in the address bar. Copying or filling one asks for Touch ID or your Mac password (filling can be switched off in Settings › Privacy).
- **Pop-ups.** Pages don't get to open windows on you unasked. Pop-ups opened without a click are blocked, with "Open" and "Always Allow for This Site" right above the page.

Ad and tracker blocking is covered under [Ad blocking](#ad-blocking), and what stays on your Mac and what is sent is covered under [Privacy](#privacy).

### Saving and downloads

- **Save a page.** Keep a page for later as a PDF or a picture. Save it as one long PDF (File › Save as PDF…) or as a picture of the whole page, not just what's on screen (File › Capture Full Page…). Both are also in a tab's menu, save to your Downloads folder unless you pick another, and work in private windows too. Pages that scroll inside an inner panel and images that load only on scroll may not be captured in full.
- **Downloads.** See how a download is going, with a safety check on first open. Downloads show their progress at the bottom of the sidebar and get Safari's quarantine flag, so Gatekeeper checks them on first open. Apps, scripts and installers are shown in Finder instead of run. A download that breaks off picks up from where it stopped with Try Again on its row.
- **Page zoom.** Zoom a site once and it stays zoomed: page zoom is remembered per site, so you only squint once.
- **Session saving.** Browsers crash. Open tabs are saved every 15 seconds, so a crash costs almost nothing.

### Updates

- **Automatic updates.** Changmun updates itself with Sparkle. It checks in the background once a day and, when a new version is out, offers to install it; Changmun › Check for Updates… checks right now. Updates are signed, and Changmun installs one only if the signature matches the key built into the app. In Settings › Advanced you can turn the automatic check off, or let it download and install on its own.

## AI

The panel on the right (⌘E) uses the `claude` CLI you already have, so it runs on your Claude Code subscription. The default model is Sonnet. The model menu under the message box (it reads like "Sonnet · High") sets the model and the effort (Auto, Low, Medium, High, Extra High or Max, passed to Claude Code's `--effort`; Auto passes nothing). The model can also be changed in Settings › AI.

The panel's header shows the chat's title, which is its first message. Its menu lists recent chats and Show All Chats, and beside it are a new-chat button and a pop-out button that moves the panel into a window of its own. Closing that window puts the panel back in the browser window. Questions and approval cards work in it too, and the window comes forward when the AI asks. A small ring shows how much of the model's context the chat uses (hover for the percentage). Your message shows cards of the pages that went with it, each with its title and site.

The AI gets these tools: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `read_tabs`, `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover`, `drag`, `wait_for`, `scroll`, `screenshot`, `sign_in`. Passwords, one-time codes and card fields are off limits: it can't read their values, type or press keys in them, and screenshots mask them. A password field is known as one from the moment its page begins, also when the page turns it into a plain text field at once or after a "show password" button; a field is taken for one by its name, its label, its placeholder or when it is drawn as dots. It can't upload files either.

- `read_page` numbers the buttons, links and fields, and the other tools take those numbers. It reads frames too: those of the same site fully, those of other sites when WebKit lets Changmun reach them (the page says when it can't). Elements inside shadow DOM (web components) aren't listed; `click_at` reaches those when the shadow tree is open, and the click is judged by the element it hits.
- Each element line of `read_page` ends with its states in brackets: `[checked]` or `[unchecked]` (also `[mixed]`) for checkboxes, radio buttons and switches, `[selected]`, `[expanded]` or `[collapsed]`, `[disabled]`, `[focused]`, `[pressed]`, `[required]` and `[invalid]`, after the current value of a field (`value="…"`) or list (`selected="…"`), kept to one line. A password, code or card field shows no value, no `[invalid]`, and only the states that say nothing about what it holds.
- After `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover` and `drag`, once the page has settled (at most about a second and a half), the answer ends with what changed since the AI last saw the page: the address and title if they changed, and the interactive elements that are new (`+`, numbered on after the ones already handed out, so they work with the tools at once), changed (`~`: its name, its value, or a state it gained or lost: checked, mixed, selected, expanded, disabled, pressed, required, invalid, focus) or gone (`-`; an element that comes back later, a menu you open again, is new again, with a number of its own). The frames of other sites are asked all at once, each for at most a second and a half, and one that doesn't answer is left alone for a few seconds and said so. It lists at most 40 lines, new elements first, then the changes, then gone ones; a change of the focus alone is told last and takes no line of the 40. It says how many more there are, and when nothing changed it says the page may still be loading and suggests `wait_for`; after a navigation it only says so and suggests `read_page`. It is page content like a read: the site it came from, frames included, is recorded as read, and a tab you aren't looking at tells nothing from a site it wasn't approved for.
- `screenshot` with `labels` reads the page again and draws each interactive element's `read_page` number on the picture, in a box over the element, for what is in view. Nothing is added to the page: the boxes are drawn on the picture afterwards, at the scale `click_at` uses, secret fields masked as in any picture. Where they are comes from the page's layout, which a hostile page can bend, so what `read_page` says is authoritative. `changmun screenshot --labels` does the same.
- `click_at` clicks a point of the visible page, for what `read_page` can't list (a canvas, a map). The point is in CSS pixels from the page's top left, which is what a `screenshot` shows: the picture is as wide as the page is in CSS pixels (up to 1280, a wider page is scaled down and the picture's note says by how much), whatever the page zoom or the screen's pixel density. It says which element was hit.
- `press_key` presses Enter, Escape, Tab, Backspace, Delete, Space, an arrow, Home, End, PageUp or PageDown, optionally with shift, alt, ctrl or meta. No letters or symbols, so it can't type text. The page gets keydown, keypress and keyup; what the page leaves alone is done as the browser would (Enter activates a button or submits a form, Tab moves focus, Escape closes a dialog, arrows move the cursor, change a list or scroll, Backspace and Delete edit a text field). WebKit does some of that itself for a script-made Enter the page leaves alone (it submits or clicks); Changmun sees when it did and doesn't do it twice, emulates the rest, and combinations with alt, ctrl or meta only reach the page's own handlers.
- `select_option` picks an option of a list by its text or value, also in custom listboxes and comboboxes. It finds the option first, judges the one it found (not the words it was asked with), and picks it only if it's still the same. `hover` moves the pointer over an element (the pointer and mouse enter, over and move events) so script-driven menus open; a menu made only with the CSS `:hover` rule doesn't. `drag` drags between two elements or points, as HTML5 drag and drop when the source is draggable and as pointer and mouse events otherwise. `wait_for` waits for text to appear or go away, or for the page to finish loading, for up to 30 seconds (10 by default); a look at the page that gets no answer doesn't count as "gone". It looks in frames of other sites too, also those no `read_page` has named, and says when one can't be reached.

While it works, its target is outlined on the page with a small "AI" label that goes away by itself (without motion when "Reduce motion" is on), and the panel shows "Working for 12 s" with the live steps underneath (expandable). Each step says what it's up to in the words Changmun makes up ("Clicking “Sign in”", "Waiting for “Results”"), followed by the short title the AI gave the step (every tool takes an optional `title`, like "Comparing prices"): "Clicking “Buy” · Comparing prices". The title never replaces those words, and for `sign_in` and anything that asks every time only Changmun's words are shown. A title is the model's text, so it is shown as one line of at most 60 characters with invisible and look-alike characters made visible, and it takes no part in any question or decision. If the page changes between the AI's look and its action, even while you're deciding, the action is dropped: what it was called, where it goes, the form it belongs to and what the form posts to are all compared. Stop ends a wait at once, takes the outline off, withdraws a question you haven't answered and cancels an action that is only outlined, so a late "Allow" can't run anything. A call that its caller has given up on (about two minutes) does nothing either, however late the answer comes. Tabs the AI is using aren't put to sleep or archived while its run lasts (for other agents, for 90 seconds after each use), and the three used last (not counting the page you're looking at) stay in the window behind it, invisible and muted, so their timers go on but nothing plays.

While the AI works, the field still takes messages. Return queues one as a small chip above the field (the × removes it), and each queued message goes out by itself, in order, when the run before it ends well; it goes with the tab that was in front and the tabs attached when you wrote it (ones that have since closed or been removed are left out, and one that has gone to another site since is named but its title and address are not given; tools that name no tab then work on the tab you wrote it for while it is still on that site, else the AI has to say which). Up to 8 messages wait; a ninth is not taken and a line says so. If the run failed or was cut short, or a run could not begin (no `claude`), the chips stay and a "Send Queued" button waits for you, and what you write meanwhile joins the queue behind them. ⌘Return steers instead: it stops the run as Stop does (questions withdrawn, tools in flight cancelled), waits for the old `claude` to exit, and carries on in the same conversation with the new message (a second ⌘Return while it waits is added to the first, and nothing starts before the old process has exited; a process that ignores the request to end is killed after 3 seconds, also by Stop and New Chat). If the conversation can't be resumed after the interruption, the message goes again as a new conversation with a line about what it was, and the panel says so. With nothing to continue yet, a steer is queued and a line says so. Each run's tool calls carry a token of their own, so nothing the old run still sends is accepted. Stop and New Chat empty the queue. While you compose text with an input method (Korean, Japanese, Chinese), Return belongs to it and sends nothing. A line under the field says what Return and ⌘Return do while a run is on.

`sign_in` fills your saved login for the site into its sign-in form without the AI seeing it. The page's exact host must be the saved login's host (`www.example.com` is not `example.com`), on https and the standard port; for a form in a frame, the frame's host; never in a private window, never for a frame with no site of its own, and not for a form that sends to another site. Every time, whatever else you allowed and in every approvals mode, a sheet asks "Let the AI sign in to example.com as you@example.com?" (Allow Once or Don't Allow), and then Touch ID or your Mac password confirms, as copying a saved password does; only then is the password read. The AI is told only that the login was filled in, never the password or the account name ("the user chose the account"), and the two fields become secrets for it: it can't read or type in them, and pictures and what-changed reports don't show them. With several accounts saved, you pick the account in the sheet (the most recently used is chosen to begin with); the AI is never asked which and has no parameter for it. If the sign-in isn't done for any reason that has to do with your logins or your answer (none saved for the site, you said no or didn't answer, you didn't confirm), the AI is told only "The sign-in wasn't done", so it can't find out which accounts you have. With no login saved you see a sheet too, which says so and can only be closed, and the AI waits for it just as long. After you declined a site, asking again in the same chat shows no sheet but a line in the panel, and the answer comes after a fixed four seconds. A form whose action, or any submit button's formaction (wherever the button is), goes to another site is refused, the form is checked again just before filling, and the fields get focus, input, keyup, change and blur events so a page's Sign in button can enable. A login saved with no username shows as "(No username)". The AI may still see the account name if the page shows it itself (a greeting, a field it reads). It fills in, with input and change events, and presses nothing: the AI clicks Sign in afterwards, and that click is judged like any other.

To work across several tabs, add them from the + menu in the message box with Add Tab… (one by one, a tab group, or all open tabs): they show as chips you can remove, the AI reads them together with `read_tabs`, and you aren't asked before it reads them. With two or more attached, the panel suggests comparing them or boiling each down to its key points.

The tab the AI is looking at shows as a chip in the row under the chat, and typing @ in the box attaches another one. ⌘E puts the cursor in the box (from the box, it closes the panel), Esc stops a run (so does the Stop button in the message box), ↑ brings back your last message, and the panel's left edge drags to resize it. Suggestions fit the page you're on, and "Ask AI About Selection" in a page's context menu quotes the selected text in the box.

Answers draw code blocks, lists and tables, with a copy button on the code. A link also names the site it really goes to, and once the chat has read other sites, opening a link from an answer asks first. A long run folds into "N steps" with a line saying how many tabs it opened and closed, and Reopen brings back the ones it closed. If Claude Code isn't signed in, its usage limit is used up, or the network or Anthropic's servers fail, the panel says which in plain words, with Try Again.

In the + menu, Attach Screenshot attaches a picture of the page you're on (secrets on the page left out) and Add Image… adds one from your Mac. You can also drop or paste images into the panel: up to 4 per message, cut down to 1568 pixels on the long side and saved again without the place and time the file carried. A picture counts as something the AI read (a screenshot as its page, any other as "an image you added"), so what it does next is asked about, as after reading another site. The mic button starts macOS dictation.

Finished chats are kept on this Mac only, to read again from the chat menu in the panel's header (Show All Chats). They are read-only (a chat is never resumed: the AI would still remember the pages it read, but Changmun would no longer know which sites they were, and the question after reading other sites would be skipped), and private windows are never recorded. Typed or chosen text is saved as its length only, and addresses lose everything from ? or #. Turn it off in Settings › AI › Keep chat history; delete one chat or all of them from the panel.

A web page can hide instructions meant for an AI. So that such instructions can't make it carry what it read somewhere else, Changmun asks you first. How much it asks is a three-way choice in the approvals menu under the message box, or in Settings › AI (it replaces the old on/off switch, and your existing setting carries over):

- **Ask after reading other sites** (the default). The questions listed below.
- **Ask before every action.** Also asks before typing, choosing or clicking on a page when the chat has read nothing else. You can allow a site until the chat is cleared.
- **Ask only for actions that can't be undone.** Skips the questions listed below; the two kinds of action after them still ask.

No answer after 90 seconds counts as no. In the default mode Changmun asks:

- before it uses a tab you aren't looking at, once per tab and site;
- before it opens an address, unless it's a search, an address already open, visited or bookmarked, or a known site's front page;
- before every click, key press, hover, drag, typed text or chosen option once the chat has read another site (what a frame of another site showed counts as read from that site, and a frame with no site of its own is a site of its own), showing what it's about to do. The title and address of the tab in front, which go to the AI with every message, count as read too. You can allow it once, or allow it on that site until the chat is cleared. The allowance lasts for as long as the chat reads nothing new: reading another site takes it back, and then each site you use asks again (so it isn't one question per site for good, but one per site after each new site read). A frame counts as a site read as soon as anything of it (its text, its address or name, a point of it, or a picture that shows it) reaches the AI, whoever's lists it is on; only a frame that sent nothing doesn't. A new chat (⌘⇧E) starts over. Never asked this way: scrolling (it moves what's in view, and all a page can learn from it is which of four directions the AI chose), looking at the page in front (`read_page`, `read_tabs`, `screenshot`, `wait_for`, `list_tabs`), going back, forward or reloading it, showing a tab, and opening an address that is a search, already open, visited before or a known site's front page. A page visited since the chat began, or on a site the chat has read, is not "visited before". Closing a tab you aren't looking at, and using a tab the AI didn't open itself, ask like the other uses of a tab; a tab the AI opened itself is its own to use on the site it opened.

The site is the one the page itself says it is, from inside the frame, at the moment of the action, so a frame that moves to another site after the AI looked is asked about as that other site. A site is the exact host, so `www.example.com` and `shop.example.com` are two sites (as are two people's sites on one hosting service), another port is another site, and a page with no host (a local file, a `data:` page) counts as a site of its own: reading it, then using a website, asks. Anything a frame sends the AI, even a word, counts as read from that frame's site, and a frame that showed nothing sends nothing. `list_tabs` tells the title and address only of the tab in front and of tabs you've allowed it to use (and those count as read); any other tab is named by its site alone, which counts as nothing. A tab you aren't looking at that moves to another site by itself gives the AI neither title nor address until you've allowed that site.

What it types or chooses is shown as it is, with line breaks and every invisible or look-alike character (zero-width and direction marks, variation selectors, tag characters, blank fillers) made visible as a box and more than three combining marks on a letter cut. Past 500 characters (counted as Unicode scalars) the question says how many more aren't shown. A text with anything made visible, cut or left out can't be allowed for the chat and is asked again every time; the same goes for a long address it's about to open.

Whatever you've allowed, and in every mode, two kinds of action are asked about on top of that, and the question says which one it is.

What looks like it pays, orders, sends, posts, deletes, cancels or gives something away is asked about every time, with Allow Once or Don't Allow only. That is money (buy, pay, purchase, checkout, order, transfer, withdraw, deposit, wire, donate, sell, bid, invest, trade), content and data going out (send, post, publish, tweet, repost, reply, comment, share, upload, submit, subscribe, invite, book, reserve), access being given (allow, accept, agree outside a cookie banner, grant, authorize, connect, link an account, "Allow access") and losses (delete, erase, trash, empty the trash, remove permanently, unsubscribe, cancel a subscription, close an account, deactivate, terminate, revoke, confirm, approve), in English, Korean, Japanese, Chinese, Spanish, German and French (구매, 결제, 주문, 삭제, 탈퇴, 해지, 공유, 댓글, 등록 and so on). So are Enter in a message box (typed there or pressed), a submit button of a form that asks for card details or posts to a checkout, delete, transfer, send or cancel, a form that sends what is typed in it to another site than the page's (the question names that site), and a key the page takes as a command: Delete or Backspace outside a text field, and any key with ctrl or meta there.

Only a cookie banner's consent and plain settings are asked about once per site: Accept, Allow or Agree where the button's own name speaks of cookies or it sits in the banner of a known consent manager (OneTrust, Cookiebot, Didomi, Quantcast, TrustArc, Osano, CookieYes, Iubenda, Usercentrics, Sourcepoint), and save, clear, reset, remove, block, enable, disable, install, complete and finish (저장, 설치, 초기화, 차단, 완료 and so on). The question says it looks like a cookie banner or a setting, not like paying, sending or granting access. A button that only the page's markup puts in a consent manager's banner (its own name says nothing of cookies) is asked about every time, without the choice to allow the site for the chat and without those words, since a page can give anything such an id. In the chat panel you can allow it once or on that site until the chat is cleared, and an MCP client can do the same for its connection, which lasts until that Claude Code session (its MCP server) ends (`/clear` doesn't reset it); then those actions there aren't asked again (the questions about using a page after reading other sites still are). The command line is asked each time. The words around a button count for nothing here, so a page's own text about cookies next to an "Accept invitation" doesn't make it one. A "Save 20%" is a promotion, not a save.

Both go by every name the control has, whole however long it is for a button (what it says, its accessible name, a picture's alt text, its title, a list option's value, and the markup of an icon with no words, or of what something is dropped on), and by where it goes, whatever it's called (the address of a button or a form, a button's name and value: a "Continue" in a form posting to `/account/delete`). Icons with no words are told by their picture (a sprite symbol, an image file, a background image) and class names. A link is a navigation: its text counts only when it is short (up to 40 characters; a headline or a card of text never asks), and where it goes counts only by a whole segment of its path that is a word like `checkout`, `pay` or `delete`, never by the words of a hyphenated address. A field and a checkbox are judged by what they do and not by what they're called. A list is chosen from with `select_option` only: `type_text` and the arrow keys refuse it, so every option is judged by its names and value, and a list in a form that asks for card details or posts to a checkout is taken to submit the form. What asks every time is compared with its digits when the page changes between the look and the action (an amount or a quantity that changed stops it), and text typed with Enter into a form isn't sent if the form changed once the text was typed (a disabled Post button that became enabled). The question shows the site on a line of its own first (an international name in its ASCII form, so a look-alike shows as what it is) and the button's name with its quotation marks made plain. Going back, forward or reloading a page that came from a submitted form isn't done for the AI, since that would send the form again. This is a guess, made to err on the side of asking: a page can name a button anything, so a button that looks harmless isn't proof, and one that merely contains a word like "post" is asked about too.

Inside the panel, the AI's questions come as a card above the box instead of a window over the page. Return or Esc is Don't Allow, ⌘Return is Allow Once, and ⌥⌘Return allows that site for this chat. The keys that say yes work only while the cursor is in the panel and half a second after the card appears, so a keystroke meant for something else can't answer. Questions about paying, deleting or signing in, and about a button that only a page's markup calls a cookie banner, still come as a window, where no key says yes. The panel's head tells what the chat has read ("Read 3 sites · Allowed on 1") and lists the sites you allowed, each with Revoke.

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
changmun read-tabs 3 5
changmun click 12
changmun type 3 "hello" --submit
changmun press Enter
changmun wait "Results"
```

`changmun help` lists the rest. Each command is one of the same tools, with the same questions, and starts Changmun if needed.

### Headless, for agents

An agent asking you the same questions in the browser you're using gets old fast. For agents there is a second Changmun with no window: it stays invisible, takes no focus and makes no sound, and keeps a profile of its own, so none of your cookies, history, passwords or Keychain are in it.

```sh
changmun headless start     # copies the app you ran this from into ~/Library/Application Support/Changmun Agent and starts it
changmun headless status    # running or not, pid, version, profile folder
changmun --headless open example.com
changmun --headless read
changmun headless stop
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

Put `--headless` on any command to send it there instead of to your browser; `--mcp --headless` is the MCP form. Both start it if it isn't running. In it the AI is not asked before it uses other tabs, opens new addresses or acts after reading other sites: those questions, which guard against instructions hidden in pages, are off. That is why it is a separate copy with an empty profile, and why it refuses what can't be undone: anything that looks like paying, ordering, sending, posting, deleting or granting access, and anything in what a page only calls a cookie banner, gets a "needs a person" error, because nobody is watching and a site you sign in to inside it would be the AI's to use. Everything else is allowed. Site permissions (camera, location…) are denied. The copy is made from the app that runs the command and made again when that is another release (`changmun headless status` tells you); it never updates itself.

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
| ⌃1–9 | Go to a space (9 is the last); gives way to macOS's "Switch to Desktop N" if you've turned that on |
| ⌃⌥← / ⌃⌥→ | Previous / next space |
| ⌃⌘N | New space |
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

## Ad blocking

Changmun turns EasyList (ads) and EasyPrivacy (trackers) into WebKit content-blocking rules and refreshes them every 4 days. In Settings › Privacy you can turn lists off or add others by address (a Korean ad list is one click away). If a site breaks, the shield in the address bar turns blocking off for that site. Rules WebKit can't express (regular expressions, `$redirect`, scriptlets, `:has-text` and other extended selectors) are skipped rather than guessed: a missed ad beats a broken page.

## Extensions

Managed in Settings › Extensions (web extensions need macOS 15.4 or later).

In the tabs of a profile space, extensions run, but their cookie APIs see only the default data store, not the profile's.

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
- The update check fetches a small list of releases (`appcast.xml`) from GitHub Pages. GitHub sees the request like any web server does, including Changmun's name and version; Sparkle's system profile, which would add details about your Mac, is off and stays off (Settings › Advanced turns the check off).
- Search suggestions send what you type in the command bar to your search engine (turn them off in Settings; never sent from private windows).
- The AI panel sends your messages, the images you attach and the page content the AI reads, to Anthropic through the `claude` CLI. Tidy tabs and page translation run on your Mac.

## Passwords and security

People ask password-syncing browsers a fair question: is an encrypted copy of my passwords on your server, and could you decrypt it, log in as me, or sell it if the company goes under? For Changmun the answers are short, and each was checked against the code.

- **Where they live.** In your Mac's login Keychain, as internet passwords labeled `Changmun` (search for it in Keychain Access). Changmun doesn't mark them as synchronizable, so iCloud Keychain doesn't carry them anywhere either. Delete one in Settings › Privacy › Saved Passwords › Manage… and it's gone from the Keychain.
- **No copy anywhere else.** Changmun has no account and no server, so there's no encrypted copy to decrypt, sell, leak or inherit. Besides the requests listed under Privacy, the only things the app fetches by itself are the ad filter lists, a Chrome Web Store extension you asked for, and each site's own icon from that site. None of them carries a password.
- **Who can decrypt them.** Only this Mac, once you've unlocked it. Touch ID or your Mac password is asked before Changmun copies a password, before it fills one into a page (Settings › Privacy › Require Touch ID to fill passwords, on by default; after you confirm, fills in the next minute don't ask again) and before the AI signs in for you. Cancel and nothing is filled.
- **The AI never receives them.** For `sign_in`, Changmun fills the form itself and tells the AI only that it did, not the password or the account name. The AI can't read password fields, type into them or press keys in them, and screenshots mask them. If it then reads the signed-in page, that page's text is page content like any other.
- **What goes to Anthropic.** Your messages, the images you attach and the pages the AI reads, through your own `claude` CLI, and nothing else. Changmun holds no Anthropic key and makes no requests to Anthropic itself.
- **Chat history.** Finished chats stay in one file on this Mac (Settings › AI turns it off), without typed text or the part of an address from ? or #, and never from a private window.
- **Imported passwords.** Decrypted on your Mac with each browser's `Safe Storage` Keychain key (macOS asks first) and saved to your login Keychain. Nothing is uploaded on the way.
- **If the project stops.** There's nothing to sell and nothing to shut off: no server, no account, no database of anyone. Your passwords stay in your Keychain and the app keeps running as long as macOS does. It's open source under MIT, so anyone can check all of this, starting with `Sources/Changmun/Tabs/Logins.swift`.

## For developers

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Releases are signed for Sparkle with an EdDSA key. Put the path of its private key file in `~/.config/changmun/sparkle.env` as `SPARKLE_KEY_FILE=...`; `release.sh` refuses to run without it, or with a key that isn't the `SUPublicEDKey` in `Resources/Info.plist`. Keep a backup of that file offline. If it's lost, installed copies can never be updated again, and if it leaks, anyone can sign an update they'd accept.

UI text is English in the code and translated in `Resources/<language>.lproj/Localizable.strings`; add every new string to all six tables.

`scripts/headless.sh` runs the test copy, `Changmun Headless.app` (it never shares a profile with the `changmun headless` of the AI section, which is the one for agents), a headless Changmun for tests and agents: off screen, never takes focus or plays sound, with its own profile in `~/Library/Application Support/Changmun Headless`. It doesn't touch the Keychain, and answers AI confirmations, site permissions and JavaScript dialogs by itself (permissions are denied).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## License

[MIT](LICENSE)
