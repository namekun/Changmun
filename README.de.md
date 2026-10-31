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

*Changmun* (창문) ist Koreanisch für *Fenster*. Er ist kostenlos und Open Source und braucht kein Konto. Die App spricht Englisch, Koreanisch, Japanisch, vereinfachtes Chinesisch, Spanisch, Deutsch und Französisch.

## Installieren

```sh
brew install --cask namekun/tap/changmun
```

Oder [lade die App direkt herunter](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg).

- Braucht macOS 14 oder neuer auf einem Mac mit Apple Chip.
- Von Apple signiert und notarisiert, also öffnet sie sich sofort.
- Aktualisiert sich selbst.
- Beim ersten Start bietet sie an, deine Lesezeichen und deinen Verlauf zu übernehmen.

## Warum Changmun

- **Leicht.** Die App ist 21 MB groß, der Download etwa 7 MB. Sie nutzt die WebKit-Engine, die dein Mac schon hat.
- **Eine Seitenleiste.** Vertikale Tabs, Favoriten, Lesezeichenordner, Tab-Gruppen und Spaces in einer Spalte. Lieber Tabs oben? Das ist eine Einstellung.
- **Eine KI, die den Browser bedient.** Claude liest Seiten, klickt und tippt für dich und fragt nach, bevor etwas riskant wird.
- **Privat.** Kein Konto, kein Server, keine Analyse. Werbung und Tracker werden von Anfang an blockiert.
- **Deine Sachen kommen mit.** Er übernimmt Lesezeichen und Verlauf aus Safari und Chromium-Browsern, Passwörter aus den Chromium-Browsern.
- **Eine eigene Startseite.** Drei Stile, Bereiche, die du frei anordnen kannst, und ein eigener Hintergrund.

## Die KI

Drücke ⌘E und frag in ganz normalen Worten:

- „Fass diese Seite zusammen.“
- „Vergleiche die Preise in diesen drei Tabs.“
- „Melde mich auf dieser Website an.“

Sie läuft über das `claude`-CLI, das du schon hast, und nutzt damit dein eigenes Claude-Code-Abo. Nutzt du Claude nicht, kannst du die Seitenleiste einfach ignorieren: Der Rest des Browsers funktioniert auch ohne sie.

**Was sie im Zaum hält**

- Sie fragt nach, bevor sie bezahlt, sendet, postet oder löscht.
- Sie fragt nach, bevor sie einen Tab nutzt, den du gerade nicht ansiehst, oder eine unbekannte Website öffnet.
- Sie kann keine Passwörter sehen und sieht private Fenster nie.

Deine Nachrichten, angehängte Bilder und die Seiten, die sie liest, gehen über das `claude`-CLI an Anthropic. Auch andere Tools können Changmun steuern, per MCP oder mit dem Befehl `changmun`.

## Modus ohne Oberfläche

Ein zweites Changmun ohne Fenster, für KI-Agenten und Skripte. Es bleibt unsichtbar, nimmt keinen Fokus und macht keine Geräusche.

```sh
changmun headless start
changmun --headless open example.com
changmun --headless read
changmun headless stop
```

So bekommt Claude Code Zugriff:

```sh
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

- **Von dir getrennt.** Es hat ein eigenes, leeres Profil: Deine Cookies, dein Verlauf, deine Passwörter und dein Schlüsselbund sind nicht darin.
- **Keine Rückfragen.** Die üblichen Freigaben sind aus, damit ein Agent ohne Unterbrechung arbeiten kann.
- **Es stoppt bei allem, was sich nicht rückgängig machen lässt.** Was nach Bezahlen, Bestellen, Senden, Posten, Löschen oder Zugriff erteilen aussieht, endet mit dem Fehler „braucht einen Menschen“.

[Mehr zum Modus ohne Oberfläche](GUIDE.de.md#changmun-ohne-oberfläche-für-agenten)

## Im Vergleich zu anderen Browsern

Changmun will nicht jeden Browser in jeder Hinsicht schlagen. Hier steht, wo er sich unterscheidet und wann du woanders besser aufgehoben bist.

| | App-Größe | Engine |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21 MB** | WebKit, das von macOS |
| Safari 27 | 35 MB | WebKit, das von macOS |
| Google Chrome 156 | 731 MB | Chromium, eigene Kopie |
| Arc 1.168 | 862 MB | Chromium, eigene Kopie |
| Dia 1.53 | 1,3 GB | Chromium, eigene Kopie |

<sub>Gemessen mit `du -sh` auf einem Mac mit Apple Chip im Oktober 2026.</sub>

| Verglichen mit | Was Changmun dir bietet | Bleib dort, wenn du brauchst |
| :-- | :-- | :-- |
| **Safari** | Dieselbe Engine, dazu eine Seitenleiste mit vertikalen Tabs, eine KI, die eine Seite bedienen kann, und Erweiterungen aus dem Chrome Web Store | iCloud-Synchronisierung von Tabs, Passwörtern und Passkeys |
| **Chrome** | Kein Google-Konto und kein Sync-Server, und eine App mit etwa 3 % der Größe | Seiten, die nur für Chromium gebaut sind, die Chrome-Synchronisierung oder Windows, Linux und Handys |
| **Arc** | Dieselbe Idee aus Seitenleiste und Spaces, und es bekommt weiter neue Funktionen (Arc ist seit Mai 2025 im Wartungsmodus) | Boosts oder Easels |
| **Dia** | Dieselbe Ideenfamilie, ohne eigenen KI-Dienst und ohne Konto: Es nutzt dein `claude`-CLI | Seine gehosteten KI-Funktionen und die Integrationen für die Arbeit |

Das stammt aus dem, was jedes Projekt über sich selbst sagt. Ist etwas veraltet, [eröffne bitte ein Issue](https://github.com/namekun/Changmun/issues).

### Was noch fehlt

- **Keine Synchronisierung.** Lesezeichen, Verlauf und Passwörter bleiben auf dem Mac, auf dem sie entstanden sind.
- **Nur Mac.** Kein iPhone, kein Windows, kein Linux.
- **Noch keine Passkeys.** Browser brauchen dafür eine Berechtigung (Entitlement) von Apple; Changmun hat sie beantragt und wartet.
- **Erweiterungen brauchen macOS 15.4 oder neuer,** und manche Chrome-Erweiterungen verlassen sich auf Dinge, die WebKit nicht hat.
- **Seiten, die nur für Chromium gebaut sind,** können hier Probleme machen, genau wie in Safari.
- **Ein Maintainer.** Weniger Augen als bei den großen Browsern und entsprechend Ecken und Kanten. Fehlerberichte sind willkommen.

## Tastenkürzel, die du kennen solltest

| Tasten | Was sie tun |
| :-- | :-- |
| ⌘T | Neuer Tab |
| ⌘L | Adresse bearbeiten |
| ⌘E | KI-Seitenleiste |
| ⌘D | Favorit hinzufügen oder entfernen |
| ⌃1–9 | Zu einem Space wechseln |
| ⌥⌘\\ | Split View |
| ⇧-Klick auf einen Link | Vorschau, ohne die Seite zu verlassen |
| ⌘⇧T | Geschlossenen Tab erneut öffnen |

Tasten wie in Safari oder wie in Chrome? Wähle in den Einstellungen (⌘,). [Alle Tastenkurzbefehle](GUIDE.de.md#tastenkurzbefehle).

## Datenschutz

Was du im Web tust, bleibt auf deinem Mac. Die App stellt von sich aus nur wenige Anfragen, etwa die Update-Prüfung und das Aktualisieren der Werbefilterlisten. Suchvorschläge senden, was du tippst, an deine Suchmaschine; du kannst sie ausschalten, und private Fenster senden sie nie. [Alles, was gesendet wird, und wann](GUIDE.de.md#datenschutz).

## Mehr erfahren

Das [Handbuch](GUIDE.de.md) erklärt alles im Detail:

- [Funktionen](GUIDE.de.md#was-er-kann): Tabs, Spaces, Lesemodus, private Fenster, Downloads
- [KI](GUIDE.de.md#ki): Modelle, Freigaben, Werkzeuge, MCP und die Befehlszeile
- [Werbeblocker](GUIDE.de.md#werbeblocker), [Erweiterungen](GUIDE.de.md#erweiterungen) und [Import aus anderen Browsern](GUIDE.de.md#import-aus-anderen-browsern)
- [Passwörter und Sicherheit](GUIDE.de.md#passwörter-und-sicherheit)
- [Für Entwickler](GUIDE.de.md#für-entwickler) und [aus dem Quellcode bauen](GUIDE.de.md#aus-dem-quellcode-bauen)

## Lizenz

MIT. Siehe [LICENSE](LICENSE).
