<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmun-Symbol"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>Ein schlanker Mac-Browser mit Seitenleiste und einer KI, die ihn bedienen kann.</b><br>
  Die WebKit-Engine von Safari, vertikale Tabs, Favoriten und Lesezeichenordner links und eine Claude-Seitenleiste, die Seiten liest, klickt und für dich tippt.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 oder neuer">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MIT-Lizenz"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="Natives Swift">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <b>Deutsch</b> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="Changmun-Fenster mit vertikalen Tabs in der Seitenleiste und einer Seitenkarte">
</p>

*Changmun* (창문) ist Koreanisch für *Fenster*. Der Browser ist kostenlos und Open Source, braucht kein Konto und trackt nichts. Die App spricht Englisch, Koreanisch, Japanisch, vereinfachtes Chinesisch, Spanisch, Deutsch und Französisch.

## Installieren

```sh
brew install --cask namekun/tap/changmun
```

Du brauchst [Homebrew](https://brew.sh), macOS 14 Sonoma oder neuer und einen Mac mit Apple Chip. Homebrew entfernt die Quarantäne-Markierung, sodass sich die App sofort öffnet. Aktualisieren mit `brew update && brew upgrade --cask changmun`.

Beim ersten Start bietet Changmun an, Lesezeichen, Verlauf, Passwörter und Anmeldungen aus deinem bisherigen Browser zu übernehmen.

### Aus dem Quellcode bauen

Du brauchst macOS 14 oder neuer sowie Xcode oder die Command Line Tools.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

Sind nur die Command Line Tools installiert, bauen die Skripte gegen das macOS-26-SDK (das SwiftUI-Makro-Plug-in des macOS-27-SDK gibt es nur mit Xcode). Die Build-Produkte landen in `~/Library/Caches/Changmun/build`, außerhalb der Reichweite der iCloud-Synchronisierung des Schreibtischs.

## Was er kann

- **Seitenleiste.** Favoriten als Kacheln, Lesezeichenordner, vertikale Tabs. Zieh Tabs, um sie umzusortieren, oder auf die Favoriten, um sie anzuheften. Favoriten und Lesezeichen behalten wie bei Dia und Arc jeweils ihren eigenen Tab: Ein Klick springt zu diesem Tab, statt den Tab zu ersetzen, den du gerade liest (⌘-Klick öffnet einen neuen Tab).
- **Adressleiste, wo du willst.** Über der Seite wie bei Dia oder oben in der Seitenleiste neben Zurück und Vor wie bei Arc: Einstellungen › Tabs & Darstellung › Position der Adressleiste.
- **Lesezeichenordner.** Zieh ein Lesezeichen auf einen anderen Ordner oder auf die Favoriten, oder Rechtsklick › Bewegen nach. Zeig auf einen Ordner und klick auf das Raster (oder Rechtsklick › Als Seite anzeigen), um den ganzen Ordner auf der Seite ausgebreitet zu sehen.
- **Tab-Gruppen.** Rechtsklick auf einen Tab › Zu neuer Gruppe hinzufügen, benennen, einklappen. Tabs, die du aus dem Tab einer Gruppe öffnest, gehören zur Gruppe; ein erneut geöffneter Tab (⌘⇧T) kehrt in seine Gruppe zurück.
- **Tabs aufräumen.** Der Zauberstab neben „Neuer Tab“ (Fenster › Tabs aufräumen) gruppiert die losen Tabs. Mit aktivierter Apple Intelligence (macOS 26) gruppiert das Modell auf deinem Mac die Tabs nach Thema und benennt die Gruppen; nichts über deine Tabs verlässt den Mac. Ohne Apple Intelligence kommen Tabs, die auseinander geöffnet wurden, und Tabs derselben Website zusammen. „Widerrufen“ stellt den alten Zustand ein paar Sekunden lang wieder her. Neue Tabs, die du über die Adressleiste öffnest, landen von selbst in einer passenden Gruppe (ausschalten unter Einstellungen › Tabs & Darstellung).
- **Alte Tabs archivieren** (standardmäßig aus). Tabs, die du eine bestimmte Zeit nicht angesehen hast (12 Stunden bis 30 Tage, nur gezählt, solange Changmun läuft), werden geschlossen und landen unter Verlauf › Archivierte Tabs, bereit zum erneuten Öffnen in ihrer Gruppe. Sichtbare Tabs, Tabs mit Wiedergabe, Bild-in-Bild, Kamera/Mikrofon sowie Favoriten und private Tabs werden nie archiviert.
- **Split View** (⌥⌘\\) zeigt zwei Tabs nebeneinander. Der **Fokusmodus** (⌘⇧F) blendet alles außer der Seite aus. **Link-Vorschau**: ⇧-Klick auf einen Link öffnet ihn in einer schwebenden Karte, ⌘↩ behält ihn als Tab.
- **Private Fenster** halten Cookies und Websitedaten nur im Arbeitsspeicher und vergessen sie beim Schließen; nichts landet im Verlauf, in der Sitzung oder bei der KI.
- **Befehlsleiste** (⌘T): Suche, Adressen, Wechsel zu offenen Tabs, Lesezeichen und Verlauf sowie Fragen an die KI.
- **Seiten übersetzen** direkt an Ort und Stelle mit der Übersetzung von macOS auf dem Gerät (⌥⌘T, ab macOS 26). Links und Layout bleiben erhalten; der Text verlässt den Mac nie.
- **Bild-in-Bild** (⌃⌘P) startet von selbst, wenn du einen Tab mit laufendem Video verlässt. ⌃⌘← / ⌃⌘→ springen 5 Sekunden, sogar während du in einer anderen App bist, und „Zurück zum Tab“ holt den Tab wieder nach vorn.
- **Passwörter** werden nach der Anmeldung im Schlüsselbund gesichert (nur https) und über die Schlüssel-Taste in der Adressleiste eingesetzt. Zum Kopieren eines Passworts brauchst du Touch ID oder dein Mac-Passwort.
- **Pop-ups**, die ohne Klick aufgehen, werden blockiert; „Öffnen“ und „Für diese Website immer erlauben“ erscheinen direkt oberhalb der Seite.
- **Downloads** zeigen ihren Fortschritt unten in der Seitenleiste und erhalten das Quarantäne-Flag von Safari, sodass Gatekeeper sie beim ersten Öffnen prüft. Apps, Skripte und Installer werden im Finder angezeigt statt ausgeführt.
- **Tabs im Ruhezustand.** Hintergrund-Tabs, die du 20 Minuten nicht gesehen hast, und bei knappem Speicher alle Hintergrund-Tabs geben ihren Webprozess frei und kommen samt Verlauf zurück, sobald du zu ihnen wechselst.
- Der Seitenzoom wird pro Website gemerkt, und offene Tabs werden alle 15 Sekunden gesichert, sodass ein Absturz fast nichts kostet.

## Tastenkurzbefehle

Wähle in den Einstellungen (⌘,) „Wie in Safari“ oder „Wie in Chrome“. Es ändern sich nur die Tasten, bei denen sich die beiden Browser unterscheiden.

| Tasten | Aktion |
| --- | --- |
| ⌘T / ⌘L | Befehlsleiste / aktuelle Adresse bearbeiten |
| ⌘E / ⌘⇧E | KI-Seitenleiste / neuer KI-Chat |
| ⌘D | Favorit hinzufügen oder entfernen |
| ⌘N / ⌘⇧N / ⌘⇧W | Neues Fenster / neues privates Fenster / Fenster schließen |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | Tab schließen, zu einem Tab in der Reihenfolge der Seitenleiste wechseln |
| ⌃Tab / ⌃⇧Tab | Tabs in der Reihenfolge wechseln, in der du sie zuletzt gesehen hast (⌃ halten, Tab drücken, loslassen; esc bricht ab) |
| ⌥⌘\\ | Split View ein- oder ausschalten |
| ⇧-Klick | Link-Vorschau: esc schließt, ⌘↩ öffnet sie als Tab |
| ⌘⇧T | Geschlossenen Tab erneut öffnen (oder das geschlossene Fenster, wenn kein Tab mehr übrig ist) |
| ⌃⌘M | Tab stummschalten oder Stummschaltung aufheben |
| ⌃⌘P | Bild-in-Bild ein- oder ausschalten |
| ⌃⌘← / ⌃⌘→ | Video 5 Sekunden zurück oder vor |
| ⌥⌘T | Seite übersetzen / Original anzeigen |
| ⌘F, ⌘G, ⌘⇧G | Auf Seite suchen, weitersuchen, vorheriges suchen |
| ⌘Y | Verlauf |
| ⌘O, ⌘P, ⌘⇧C | Datei öffnen, drucken, Adresse kopieren |
| F12 oder ⌥⌘I | Web-Inspektor |
| ⌘⇧F | Fokusmodus |

| Aktion | Wie in Safari | Wie in Chrome |
| --- | --- | --- |
| Seitenleiste | ⌘⇧L | ⌘S |
| Vollständig neu laden | ⌥⌘R | ⌘⇧R |
| Konsole | ⌥⌘C | ⌥⌘J |
| Downloads | ⌥⌘L | ⌘⇧J |
| Vorheriger Tab / Nächster Tab | | ⌥⌘← ⌥⌘→ |

## KI

Die Seitenleiste rechts (⌘E) nutzt das `claude`-CLI, das du schon hast, und läuft damit über dein Claude-Code-Abo. Das Standardmodell ist Sonnet; wechseln kannst du mit `defaults write io.github.namekun.Changmun aiModel opus`.

Die KI bedient den Browser mit diesen Werkzeugen: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. Passwortfelder kann sie weder lesen noch ausfüllen.

Damit in einer Seite versteckte Anweisungen sie nicht dazu bringen, Gelesenes anderswohin zu schicken, fragt Changmun dich zuerst (und lehnt nach 90 Sekunden ohne Antwort ab):

- bevor sie einen Tab verwendet, den du gerade nicht ansiehst, einmal pro Tab und Website;
- bevor sie eine Adresse öffnet, außer es ist eine Suche, eine bereits geöffnete, besuchte oder als Lesezeichen gesicherte Adresse oder die Startseite einer bekannten Website;
- vor jeder Eingabe, sobald der Chat eine andere Website gelesen hat, mit Anzeige dessen, was sie eingeben will. Ein neuer Chat (⌘⇧E) beginnt von vorn.

Andere Agenten wie Claude Code können dieselben Werkzeuge über MCP nutzen, mit denselben Rückfragen:

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` startet Changmun, falls es nicht läuft. Der Steuerungsserver lauscht nur auf 127.0.0.1 und braucht ein Token, das sich bei jedem Start ändert.

## Werbeblocker

Changmun macht aus EasyList (Werbung) und EasyPrivacy (Tracker) Inhaltsblockierregeln für WebKit und aktualisiert sie alle 4 Tage. Unter Einstellungen › Datenschutz kannst du Listen ausschalten oder weitere per Adresse hinzufügen (eine koreanische Werbeliste ist nur einen Klick entfernt). Wenn eine Website nicht richtig funktioniert, schaltet die Schild-Taste in der Adressleiste das Blockieren für diese Website aus. Regeln, die WebKit nicht ausdrücken kann (reguläre Ausdrücke, `$redirect`, Scriptlets, `:has-text` und andere erweiterte Selektoren), werden übersprungen, statt sie zu raten.

## Erweiterungen

Verwaltung unter Einstellungen › Erweiterungen (Web-Erweiterungen brauchen macOS 15.4 oder neuer).

- **Safari-Erweiterungen aus dem App Store** erscheinen nach der Installation und fragen beim Einschalten nach ihren Berechtigungen.
- **Erweiterungen aus dem Chrome Web Store**: Öffne die Store-Seite einer Erweiterung, dann erscheint oberhalb davon „Zu Changmun hinzufügen“ (oder füge ihre Adresse oder ID in den Einstellungen ein). Changmun entpackt sie nach `~/Library/Application Support/Changmun/Extensions` und lädt sie als WebKit-Erweiterung; erneutes Hinzufügen aktualisiert sie.
- **Safari-Inhaltsblocker** (Unicorn, AdGuard und andere): macOS lässt nur Safari einen Blocker nach seinen Regeln fragen, daher liest Changmun die Regeldatei, die der Blocker gesichert hat. macOS fragt einmal, ob Changmun die Daten einer anderen App lesen darf.
- Ein entpackter Erweiterungsordner (mit `manifest.json`) lässt sich ebenfalls laden. Einige Funktionen, etwa die Kommunikation mit einer nativen App, funktionieren möglicherweise nicht.

## Import aus anderen Browsern

Beim ersten Start oder über das Menü importiert Changmun Lesezeichen und Verlauf aus Safari und aus Chromium-Browsern: Chrome, Arc (mit seiner Seitenleiste), Dia, Aside, Whale, Brave, Edge, Vivaldi. Aus Chromium-Browsern übernimmt es auch Passwörter und Cookies, damit du angemeldet bleibst.

- Passwörter und Cookies werden mit dem Schlüsselbund-Eintrag des jeweiligen Browsers (`<Name> Safe Storage`) entschlüsselt, daher fragt macOS nach deiner Erlaubnis. Importierte Passwörter landen mit der Bezeichnung `Changmun` in deinem Anmelde-Schlüsselbund.
- Zum Lesen von Safari ist der Festplattenvollzugriff nötig. Die Passwörter von Safari gibt macOS nicht an andere Apps weiter.

## Datenschutz

- Dein Surfverhalten bleibt auf deinem Mac. Changmun hat kein Konto, keinen Server und keine Analyse.
- Suchvorschläge senden, was du in die Befehlsleiste eingibst, an deine Suchmaschine (in den Einstellungen ausschaltbar; aus privaten Fenstern wird nie etwas gesendet).
- Die KI-Seitenleiste sendet deine Nachrichten und die Seiteninhalte, die die KI liest, über das `claude`-CLI an Anthropic. „Tabs aufräumen“ und die Seitenübersetzung laufen auf deinem Mac.

## Für Entwickler

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Der Text der Oberfläche steht im Code auf Englisch und wird in `Resources/<Sprache>.lproj/Localizable.strings` übersetzt; trage jeden neuen String in alle sechs Tabellen ein.

`scripts/headless.sh` startet ein Changmun ohne Oberfläche für Tests und Agenten: außerhalb des Bildschirms, ohne je den Fokus zu nehmen oder Ton abzuspielen, mit eigenem Profil in `~/Library/Application Support/Changmun Headless`. Es berührt den Schlüsselbund nicht und beantwortet KI-Rückfragen, Website-Berechtigungen und JavaScript-Dialoge selbst (Berechtigungen werden abgelehnt).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## Lizenz

[MIT](LICENSE)
