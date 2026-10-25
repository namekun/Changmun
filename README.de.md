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

*Changmun* (창문) ist Koreanisch für *Fenster*. Ehrlicher kann man einen Browser kaum nennen. Er ist kostenlos und Open Source, braucht kein Konto und trackt nichts. Die App spricht Englisch, Koreanisch, Japanisch, vereinfachtes Chinesisch, Spanisch, Deutsch und Französisch.

## Warum Changmun

- **Leicht.** Chromium-Browser bringen jeweils ihr eigenes Chromium mit. Changmun leiht sich stattdessen die WebKit-Engine, die ohnehin auf deinem Mac liegt und die auch Safari verwendet. Der Download ist etwa 3 MB groß (das DMG von 0.4.1 hat 2,6 MB). Das schont den Akku, und Sicherheitskorrekturen der Engine kommen mit den Updates von macOS und Safari.
- **Eine Seitenleiste wie bei Arc und Dia.** Vertikale Tabs, deren Titel genug Platz haben, dazu Favoriten als Kacheln, Lesezeichenordner, Tab-Gruppen und Spaces.
- **Eine KI, die den Browser bedient.** Das Claude-Panel liest Seiten und klickt und tippt für dich, über deine vorhandene `claude`-CLI. Es bekommt Hände, aber keinen Freifahrtschein: Bevor etwas riskant wird, fragt es nach.
- **Standardmäßig privat.** Kein Konto, kein Server, keine Analyse, also nichts, wofür du dich anmelden müsstest. Werbe- und Tracker-Blocker sind eingebaut.
- **Zieht mit Sack und Pack um.** Importiert Lesezeichen und Verlauf aus Safari und Chromium-Browsern, aus Chromium-Browsern auch Passwörter und Anmeldungen. Die Passwörter von Safari bleiben zurück: macOS gibt sie an keine andere App heraus.

## Installieren

```sh
brew install --cask namekun/tap/changmun
```

Du brauchst [Homebrew](https://brew.sh), macOS 14 Sonoma oder neuer und einen Mac mit Apple Chip. Die App ist mit einer Developer ID signiert und von Apple notarisiert, sodass sie sich sofort öffnet. Updates kommen direkt in der App an (Changmun › Nach Updates suchen…, standardmäßig automatisch); Homebrew brauchst du nur zum Installieren.

Beim ersten Start bietet Changmun an, Lesezeichen und Verlauf aus deinem bisherigen Browser zu übernehmen, aus Chromium-Browsern auch Passwörter und Anmeldungen.

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

### Seitenleiste und Tabs

- **Seitenleiste.** Hält Favoriten, Lesezeichen und offene Tabs in einer Spalte links beisammen: Favoriten als Kacheln, Lesezeichenordner, vertikale Tabs. Zieh Tabs, um sie umzusortieren, oder auf die Favoriten, um sie anzuheften. Favoriten und Lesezeichen behalten wie bei Dia und Arc jeweils ihren eigenen Tab: Ein Klick springt zu diesem Tab, statt den Tab zu ersetzen, den du gerade liest (⌘-Klick öffnet einen neuen Tab). Zieh einen Link von einer Seite in die Seitenleiste, um ihn als Tab zu öffnen, als Favorit zu behalten oder in einem Ordner abzulegen. Im Menü eines Tabs kannst du ihn außerdem neu laden, duplizieren, in ein neues Fenster bewegen, teilen oder in einem anderen Browser öffnen. Einem Tab gibst du einen eigenen Namen per Doppelklick auf den Titel oder mit Tab umbenennen… im Menü; der Name bleibt über neue Seiten und Neustarts hinweg, und die KI sieht trotzdem den echten Seitentitel. Das Schließen aller Tabs einer Gruppe oder das Löschen eines Lesezeichens lässt sich ein paar Sekunden lang widerrufen, erfahrungsgemäß genau die Zeitspanne, in der die Reue kommt.
- **Adressleiste, wo du willst.** Du setzt sie dorthin, wo deine Hand sie sucht: oben in der Seitenleiste unter Zurück und Vor wie bei Arc oder über der Seite wie bei Dia (Einstellungen › Darstellung › Position der Adressleiste). Sie zeigt nur die Website; Schild und Stern erscheinen, wenn der Zeiger darüber ist. Bei einem Favoriten bleibt der Stern stehen: Klick darauf nimmt die Seite aus den Favoriten.
- **Lesezeichenordner.** Deine Lesezeichen behalten die Ordnung, die du ihnen gegeben hast, und bleiben griffbereit. Importierte Ordner bleiben verschachtelt wie im Browser, aus dem sie kommen. Fixier die, die du brauchst, in der Seitenleiste (Rechtsklick oder … › In der Seitenleiste fixieren, oder den Ordner unter die Favoriten ziehen) und öffne sie direkt dort. Zieh ein Lesezeichen auf einen anderen Ordner oder auf die Favoriten, oder nimm Bewegen nach in seinem Menü. Alle übrigen Lesezeichen liegen hinter der Lesezeichen-Taste unten in der Seitenleiste, mit Suchfeld; das … daneben öffnet Verlauf, archivierte Tabs, Fokusmodus und Einstellungen.
- **Tab-Gruppen.** Hält zusammengehörige Tabs beisammen und aus dem Weg. Rechtsklick auf einen Tab › Zu neuer Gruppe hinzufügen, benennen, einklappen. Tabs, die du aus dem Tab einer Gruppe öffnest, gehören zur Gruppe; ein erneut geöffneter Tab (⌘⇧T) kehrt in seine Gruppe zurück. Zieh eine Gruppe an ihrer Kopfzeile, um sie zu verschieben, oder nach oben auf die Favoriten oder die angehefteten Ordner, um sie samt Tabs als einen Lesezeichen-Ordner zu behalten.
- **Tabs aufräumen.** Macht aus einem Haufen loser Tabs mit einem Klick Gruppen. Ein Schwung mit dem Zauberstab neben „Neuer Tab“ (Fenster › Tabs aufräumen), und die losen Tabs sind gruppiert. Mit aktivierter Apple Intelligence (macOS 26) gruppiert das Modell auf deinem Mac die Tabs nach Thema und benennt die Gruppen; nichts über deine Tabs verlässt den Mac. Ohne Apple Intelligence kommen Tabs, die auseinander geöffnet wurden, und Tabs derselben Website zusammen. „Widerrufen“ stellt den alten Zustand ein paar Sekunden lang wieder her. Neue Tabs, die du über die Adressleiste öffnest, landen von selbst in einer passenden Gruppe (ausschalten unter Einstellungen › Tabs).
- **Alte Tabs archivieren** (standardmäßig aus). Räumt Tabs weg, die du nicht mehr ansiehst, statt sie wegzuwerfen. Tabs, die du eine bestimmte Zeit nicht angesehen hast (12 Stunden bis 30 Tage, nur gezählt, solange Changmun läuft), werden geschlossen und landen unter Verlauf › Archivierte Tabs, bereit zum erneuten Öffnen in ihrer Gruppe. Sichtbare Tabs, Tabs mit Wiedergabe, Bild-in-Bild, Kamera/Mikrofon sowie Favoriten und private Tabs werden nie archiviert.
- **Tabs im Ruhezustand.** Lässt Hintergrund-Tabs ein Nickerchen machen und gibt dafür Speicher frei. Hintergrund-Tabs, die du 20 Minuten nicht gesehen hast, und bei knappem Speicher alle Hintergrund-Tabs geben ihren Webprozess frei und kommen samt Verlauf zurück, sobald du zu ihnen wechselst.
- **Befehlsleiste** (⌘T). Ein Feld für alles: Suche, Adressen, den Wechsel zu offenen Tabs, Lesezeichen und Verlauf sowie Fragen an die KI.

### Spaces und Profile

- **Spaces.** Trennt Tabs, Tab-Gruppen und Favoriten nach Art des Surfens, damit die Arbeit am Wochenende draußen bleibt. Die Zeile ganz unten in der Seitenleiste wechselt zwischen Spaces: auf einen Punkt klicken, ⌃1–⌃9 drücken oder mit zwei Fingern seitlich über die Seitenleiste wischen (Fenster › Nächster Space, Vorheriger Space, Neuer Space …). Jeder Space hat eigene Tabs, Tab-Gruppen, Favoriten und angeheftete Ordner und färbt die Seitenleiste leicht in seiner Farbe ein. Die Lesezeichen-Bibliothek, der Verlauf und gesicherte Passwörter werden geteilt. Schalte beim Erstellen „Anmeldungen und Cookies trennen (Profil)“ ein, damit ein Space auch eigene Cookies und Websitedaten bekommt – so kannst du bei einer Website mit zwei Konten gleichzeitig angemeldet sein. Das lässt sich danach nicht mehr ändern, und beim Löschen eines Profils werden seine Cookies und Websitedaten gelöscht. Dein erster Space entsteht aus dem, was du schon hattest. Private Fenster haben keine Spaces. Die KI sieht die Tabs normaler Spaces (mit dem Namen des Spaces), die eines Profil-Spaces aber nur, solange du darin bist.

### Lesen und Ansehen

- **Lesemodus.** Lies einen Artikel als aufgeräumten, gut lesbaren Text. ⇧⌘R (mit Chrome-Tastenkürzeln ⌥⌘R) zeigt ihn über der Seite. Wirkt die Seite wie ein Artikel, erscheint in der Adressleiste ein Knopf. Esc, das × oder dasselbe Kürzel bringt die Seite unverändert zurück. Das erledigt ein kleines Skript auf der Seite: Die Bilder des Artikels werden von denselben Stellen geladen wie auf der Seite selbst, sonst wird nichts geladen oder gesendet.
- **Seiten übersetzen.** Lies eine Seite in einer anderen Sprache, ohne sie zu verlassen. Die Übersetzung geschieht direkt an Ort und Stelle mit der Übersetzung von macOS auf dem Gerät (⌥⌘T, ab macOS 26). Links und Layout bleiben erhalten; der Text verlässt den Mac nie.
- **Split View** (⌥⌘\\). Für die Fälle, in denen eine Seite nicht reicht: zwei Tabs nebeneinander.
- **Fokusmodus** (⌘⇧F). Blendet alles außer der Seite aus. Konzentrieren musst du dich selbst.
- **Link-Vorschau.** Wirf einen Blick auf einen Link, ohne die aktuelle Seite zu verlassen. ⇧-Klick auf einen Link öffnet ihn in einer schwebenden Karte, ⌘↩ behält ihn als Tab.
- **Bild-in-Bild** (⌃⌘P). Hält ein Video im Blick, auch wenn du seinen Tab verlässt. Es startet von selbst, wenn du einen Tab mit laufendem Video verlässt. ⌃⌘← / ⌃⌘→ springen 5 Sekunden, sogar während du in einer anderen App bist, und „Zurück zum Tab“ holt den Tab wieder nach vorn.

### Datenschutz und Sicherheit

- **Private Fenster.** Surfen, ohne Spuren zu hinterlassen. Private Fenster halten Cookies und Websitedaten nur im Arbeitsspeicher und vergessen sie beim Schließen; nichts landet im Verlauf, in der Sitzung oder bei der KI.
- **Website-Einstellungen.** Zeigt und ändert an einer Stelle, was Changmun sich für eine Website merkt. Ein Klick auf das Schloss links in der Adressleiste öffnet ein kleines Fenster mit allem, was Changmun für diese Website merkt: Werbeblocker, Zoom, Pop-ups, Kamera und Mikrofon und ob ihre Tabs in den Ruhezustand dürfen. Ein Klick auf eine andere Stelle der Adressleiste, auch auf den Namen der Website, bearbeitet wie bisher die Adresse.
- **Passwörter.** Das Merken übernimmt der Schlüsselbund. Passwörter werden nach der Anmeldung im Schlüsselbund gesichert (nur https) und über die Schlüssel-Taste in der Adressleiste eingesetzt. Zum Kopieren oder Einsetzen eines Passworts brauchst du Touch ID oder dein Mac-Passwort (beim Einsetzen lässt sich das unter Einstellungen › Datenschutz abschalten).
- **Pop-ups.** Seiten dürfen nicht ungefragt Fenster aufreißen. Pop-ups, die ohne Klick aufgehen, werden blockiert; „Öffnen“ und „Für diese Website immer erlauben“ erscheinen direkt oberhalb der Seite.

Werbe- und Tracker-Blocker werden unter [Werbeblocker](#werbeblocker) beschrieben, was auf deinem Mac bleibt und was gesendet wird, unter [Datenschutz](#datenschutz).

### Sichern und Downloads

- **Seite sichern.** Heb eine Seite als PDF oder als Bild auf. Du kannst sie als ein langes PDF sichern (Ablage › Als PDF sichern …) oder als Bild der ganzen Seite, nicht nur des sichtbaren Ausschnitts (Ablage › Ganze Seite aufnehmen …). Beides gibt es auch im Menü eines Tabs; es landet im Downloads-Ordner, sofern du keinen anderen wählst, und funktioniert auch in privaten Fenstern. Seiten, die in einem inneren Bereich scrollen, und Bilder, die erst beim Scrollen laden, werden womöglich nicht vollständig erfasst.
- **Downloads.** Du siehst, wie ein Download vorankommt, und er wird beim ersten Öffnen geprüft. Der Fortschritt steht unten in der Seitenleiste, und Downloads erhalten das Quarantäne-Flag von Safari, sodass Gatekeeper sie beim ersten Öffnen prüft. Apps, Skripte und Installer werden im Finder angezeigt statt ausgeführt. Ein abgebrochener Download macht mit „Erneut versuchen“ in seiner Zeile dort weiter, wo er aufgehört hat.
- **Seitenzoom.** Stell eine Website einmal ein, und der Zoom bleibt. Der Seitenzoom wird pro Website gemerkt, du musst also nur einmal die Augen zusammenkneifen.
- **Sitzung sichern.** Auch Browser stürzen ab. Offene Tabs werden alle 15 Sekunden gesichert, ein Absturz kostet also fast nichts.

### Updates

- **Automatische Updates.** Changmun aktualisiert sich selbst mit Sparkle. Es prüft einmal am Tag im Hintergrund und bietet die Installation an, sobald eine neue Version erscheint; Changmun › Nach Updates suchen… prüft sofort. Updates sind signiert, und Changmun installiert eines nur, wenn die Signatur zum Schlüssel in der App passt. Unter Einstellungen › Erweitert kannst du die automatische Prüfung abschalten oder Updates von selbst laden und installieren lassen.

## KI

Die Seitenleiste rechts (⌘E) nutzt das `claude`-CLI, das du schon hast, und läuft damit über dein Claude-Code-Abo. Das Standardmodell ist Sonnet; wechseln kannst du über den Modell-Chip unter dem Nachrichtenfeld oder unter Einstellungen › KI.

Die KI bedient den Browser mit diesen Werkzeugen: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `read_tabs`, `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover`, `drag`, `wait_for`, `scroll`, `screenshot`, `sign_in`. Passwörter, Einmalcodes und Kartenfelder kann sie weder lesen noch ausfüllen noch Tasten darin drücken; Screenshots verdecken sie. Dateien hochladen kann sie auch nicht.

- `read_page` hängt jedem Element seine Zustände in Klammern an: `[checked]`/`[unchecked]`, `[selected]`, `[expanded]`/`[collapsed]`, `[disabled]`, `[focused]`, `[pressed]`, `[required]`, `[invalid]`. Auch der aktuelle Wert von Feldern und Listen steht in einer Zeile, bei Passwort-, Code- und Kartenfeldern aber nie.
- Nach `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover` und `drag` meldet die Antwort, sobald die Seite zur Ruhe gekommen ist (höchstens etwa 1,5 Sekunden), was sich seit dem letzten Blick der KI geändert hat: Adresse und Titel, neue Elemente (`+`, mit fortlaufender Nummer sofort nutzbar), geänderte (`~`) und verschwundene (`-`). Höchstens 40 Zeilen; nach einer Navigation steht nur das und der Rat zu `read_page`. Es wird wie ein Lesen verbucht. Eine reine Fokusänderung steht zuletzt und zählt nicht zu den 40 Zeilen; eine Frame-Anfrage, die nicht antwortet, wird übergangen und gemeldet; ein Element, das wiederkommt (ein erneut geöffnetes Menü), ist wieder neu.
- `screenshot` mit `labels` liest die Seite neu und zeichnet die `read_page`-Nummer jedes sichtbaren Elements als Kasten ins Bild. Der Seite wird nichts hinzugefügt, gezeichnet wird nur im Bild. Wo die Kästen sitzen, folgt dem Layout der Seite; für Elemente gilt, was `read_page` sagt. Auch `changmun screenshot --labels` geht.
- Jedes Werkzeug nimmt einen optionalen `title` an („Preise vergleichen“), der in der Fortschrittszeile des Bereichs erscheint; sonst steht dort Changmuns eigener Text. Er ist Modelltext und wird auf eine Zeile mit höchstens 60 Zeichen gebracht; in Fragen und Entscheidungen spielt er keine Rolle. Der Titel steht hinter Changmuns eigenem Text („Klicke „Kaufen“ · Preise vergleichen“) und ersetzt ihn nie; bei `sign_in` und allem, was jedes Mal fragt, steht nur Changmuns Text.
- Während die KI arbeitet, nimmt das Feld weiter Nachrichten an. Return reiht eine als Chip ein, und sie geht der Reihe nach hinaus, wenn der Lauf davor gut endet (mit den Tabs von dem Moment, als du sie geschrieben hast). Scheitert ein Lauf oder wird er abgebrochen, wartet ein Knopf „Wartende senden“ auf dich. ⌘Return hält den Lauf an wie Stopp und macht im selben Gespräch sofort mit der neuen Nachricht weiter. Stopp und neuer Chat leeren die Warteschlange. Höchstens 8 Nachrichten warten (eine Zeile sagt es, wenn es mehr sind); ein zweites ⌘Return beim Warten wird dem ersten hinzugefügt; lässt sich die Unterhaltung nach der Unterbrechung nicht fortsetzen, geht die Nachricht als neue Unterhaltung noch einmal und das Panel sagt es. Bei Eingabemethoden (Koreanisch, Japanisch, Chinesisch) gehört Return der Eingabemethode, solange Text komponiert wird.
- `sign_in` trägt deine gespeicherte Anmeldung in das Formular ein, ohne dass die KI sie sieht. Der genaue Host der Seite muss der der gespeicherten Anmeldung sein (nur https), in privaten Fenstern geht es nicht. Jedes Mal fragt ein Fenster „Die KI bei … als … anmelden lassen?“, und Touch ID oder dein Mac-Passwort bestätigt es (bei mehreren Konten wählst du eines im Fenster). Ist keine Anmeldung gespeichert, lehnst du ab, antwortest nicht oder bestätigst nicht, hört die KI immer nur „Die Anmeldung wurde nicht durchgeführt“ und kann so nicht herausfinden, welche Konten du hast. Die KI erfährt weder Passwort noch Kontonamen. Es drückt nichts: Den Klick danach macht die KI, und er wird wie jeder andere geprüft. Auch ohne gespeicherte Anmeldung erscheint ein Fenster (nur zum Schließen), auf das die KI genauso lange wartet; nach einer Ablehnung gibt es für diese Website im selben Chat kein Fenster mehr, aber eine feste Wartezeit von vier Sekunden und eine Zeile im Panel. Formulare, deren Aktion oder deren Absende-Schaltfläche (egal wo) zu einer anderen Website führt, werden abgelehnt.

Für Aufgaben über mehrere Tabs fügst du sie unter dem Chat mit „Tab hinzufügen“ hinzu (einzeln, als Tab-Gruppe oder alle geöffneten): Sie erscheinen als Chips, die sich entfernen lassen, die KI liest sie gemeinsam mit `read_tabs`, und vor dem Lesen wird nicht nachgefragt. Sind zwei oder mehr angehängt, schlägt das Panel vor, sie zu vergleichen oder das Wichtigste jedes Tabs zusammenzufassen.

Der Tab, den die KI sieht, erscheint als Chip in der Zeile unter dem Chat, und mit @ im Feld hängst du einen weiteren an. ⌘E setzt den Cursor ins Feld (aus dem Feld heraus schließt es das Panel), Esc stoppt einen Lauf, ↑ holt deine letzte Nachricht zurück, und am linken Rand lässt sich das Panel in der Breite ziehen. Die Vorschläge passen zur Seite, auf der du bist, und „KI zur Auswahl fragen“ im Kontextmenü einer Seite zitiert den markierten Text im Feld.

Antworten zeigen Codeblöcke, Listen und Tabellen, am Code mit Kopieren-Knopf. Ein Link nennt auch die Website, zu der er wirklich führt, und hat der Chat andere Websites gelesen, fragt das Öffnen eines Links aus einer Antwort vorher nach. Ein langer Lauf klappt zu „12 Schritte“ zusammen, mit einer Zeile, wie viele Tabs er geöffnet und geschlossen hat; „Erneut öffnen“ holt die geschlossenen zurück. Ist Claude Code nicht angemeldet, das Nutzungslimit aufgebraucht oder fallen Netz oder die Server von Anthropic aus, sagt das Panel es in klaren Worten und bietet „Erneut versuchen“ an.

Unter dem Chat hängt „Screenshot“ ein Bild der aktuellen Seite an (Geheimes auf der Seite bleibt draußen), und Bilder lassen sich auch ins Panel ziehen oder einfügen: bis zu 4 pro Nachricht, auf 1568 Pixel an der langen Seite verkleinert und ohne Aufnahmeort und -zeit der Datei neu gespeichert. Ein Bild zählt als von der KI gelesen (ein Screenshot als seine Seite, jedes andere als von dir hinzugefügtes Bild), also wird danach gefragt wie nach dem Lesen einer anderen Website.

Beendete Chats bleiben nur auf diesem Mac und lassen sich über den Uhr-Knopf im Panel nachlesen. Sie sind schreibgeschützt (ein Chat wird nie fortgesetzt: Die KI würde sich noch an die gelesenen Seiten erinnern, Changmun wüsste aber nicht mehr, von welchen Websites sie stammen, und die Rückfrage nach dem Lesen anderer Websites entfiele), und private Fenster werden nie aufgezeichnet. Getippter oder gewählter Text wird nur als Länge gespeichert, Adressen verlieren alles ab ? oder #. Ausschalten unter Einstellungen › KI › Chatverlauf speichern; einzelne Chats oder alle löschst du im Panel.

Damit in einer Seite versteckte Anweisungen sie nicht dazu bringen, Gelesenes anderswohin zu schicken, fragt Changmun dich zuerst (und lehnt nach 90 Sekunden ohne Antwort ab):

- bevor sie einen Tab verwendet, den du gerade nicht ansiehst, einmal pro Tab und Website;
- bevor sie eine Adresse öffnet, außer es ist eine Suche, eine bereits geöffnete, besuchte oder als Lesezeichen gesicherte Adresse oder die Startseite einer bekannten Website;
- vor jedem Klick, Tastendruck, Darüberfahren, Ziehen, eingegebenen Text und jeder gewählten Option, sobald der Chat eine andere Website gelesen hat, mit Anzeige dessen, was sie tun will. Du kannst es einmal erlauben oder für diese Website, bis der Chat endet. Nicht gefragt wird beim Scrollen, beim Ansehen der vorderen Seite (Lesen, Screenshot, Warten, Tab-Liste) und bei Zurück, Vor und Neu laden. Ein neuer Chat (⌘⇧E) beginnt von vorn.
- vor allem, was nach Bezahlen, Bestellen, Senden, Veröffentlichen, Kommentieren, Teilen, Hochladen, Zugriff gewähren (Erlauben, Verbinden, Autorisieren), Löschen, Stornieren oder Kündigen aussieht, jedes Mal, was auch immer du erlaubt hast (nur „Einmal erlauben“ oder „Nicht erlauben“). Ebenso Eingabe in einem Nachrichtenfeld, ein Formular, das an eine andere Website sendet, und Entf oder Rücktaste außerhalb eines Textfelds.
- vor allem, was nach Akzeptieren oder Erlauben in einem Cookie-Banner oder nach einer Einstellung (Speichern, Löschen, Zurücksetzen, Blockieren) aussieht, einmal pro Website. Im KI-Bereich kannst du es für diese Website bis zum Ende des Chats erlauben, einem MCP-Agenten für die Dauer seiner Verbindung (bis diese Claude-Code-Sitzung, also ihr MCP-Server, endet); die Kommandozeile wird jedes Mal gefragt.

Im Panel erscheinen die Fragen der KI als Karte über dem Nachrichtenfeld statt als Fenster über der Seite. Return oder Esc ist „Nicht erlauben“, ⌘Return „Einmal erlauben“, ⌥⌘Return erlaubt die Website für diesen Chat. Die Tasten für Ja wirken nur, wenn der Cursor im Panel steht und die Karte eine halbe Sekunde da ist, damit ein Tastendruck für etwas anderes nicht antwortet. Fragen zu Bezahlen, Löschen und Anmelden sowie zu einem Knopf, den nur das Markup der Seite Cookie-Banner nennt, kommen weiter als Fenster, in dem keine Taste Ja sagt. Der Kopf des Panels zeigt, was der Chat gelesen hat („3 Websites gelesen · Erlaubt auf 1“), und listet die erlaubten Websites, jede mit „Widerrufen“.

Andere Agenten wie Claude Code können dieselben Werkzeuge über MCP nutzen, mit denselben Rückfragen:

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` startet Changmun, falls es nicht läuft. Der Steuerungsserver lauscht nur auf 127.0.0.1 und braucht ein Token, das sich bei jedem Start ändert.

Oder aus einer Shell, für jeden Agenten, der Befehle ausführen kann (Homebrew legt `changmun` in den PATH):

```sh
changmun tabs
changmun open example.com
changmun read
changmun read-tabs 3 5
changmun click 12
changmun type 3 "hello" --submit
```

`changmun help` zeigt den Rest. Jeder Befehl ist eines derselben Werkzeuge, mit denselben Rückfragen, und startet Changmun bei Bedarf.

### Changmun ohne Oberfläche, für Agenten

Wenn ein Agent im Browser, den du gerade benutzt, immer wieder dieselben Fragen stellt, nervt das schnell. Für Agenten gibt es ein zweites Changmun ohne Fenster: unsichtbar, ohne Fokus und ohne Ton, mit eigenem Profil, also ohne deine Cookies, deinen Verlauf, deine Passwörter und den Schlüsselbund.

```sh
changmun headless start     # kopiert die App, aus der du es startest, nach ~/Library/Application Support/Changmun Agent und startet sie
changmun headless status    # läuft oder nicht, pid, Version, Profilordner
changmun --headless open example.com
changmun --headless read
changmun headless stop
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

Mit `--headless` bei einem beliebigen Befehl geht er dorthin statt an deinen Browser; `--mcp --headless` ist die MCP-Form. Beide starten es, falls es nicht läuft. Darin wird die KI nicht gefragt, bevor sie andere Tabs nutzt, neue Adressen öffnet oder nach dem Lesen anderer Seiten handelt: Diese Rückfragen, die vor in Seiten versteckten Anweisungen schützen, sind aus. Darum ist es eine eigene Kopie mit leerem Profil, und darum lehnt es ab, was sich nicht rückgängig machen lässt: Was nach Bezahlen, Bestellen, Senden, Posten, Löschen oder Zugriff-Gewähren aussieht, und alles in einem Bereich, den eine Seite nur Cookie-Banner nennt, bekommt den Fehler „braucht einen Menschen“, denn niemand schaut zu, und eine Seite, bei der du dich darin anmeldest, stünde der KI offen. Alles andere ist erlaubt. Website-Berechtigungen (Kamera, Standort …) werden verweigert. Die Kopie entsteht aus der App, die den Befehl ausführt, und wird neu gemacht, wenn diese eine andere Version ist (`changmun headless status` sagt es dir); sie aktualisiert sich nie selbst.

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
| ⌃1–9 | Zu einem Space wechseln (9 ist der letzte); weicht dem macOS-Kurzbefehl „Zu Schreibtisch N wechseln“, falls aktiviert |
| ⌃⌥← / ⌃⌥→ | Vorheriger / nächster Space |
| ⌃⌘N | Neuer Space |
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
| Lesemodus | ⇧⌘R | ⌥⌘R |
| Konsole | ⌥⌘C | ⌥⌘J |
| Downloads | ⌥⌘L | ⌘⇧J |
| Vorheriger Tab / Nächster Tab | | ⌥⌘← ⌥⌘→ |

## Werbeblocker

Changmun macht aus EasyList (Werbung) und EasyPrivacy (Tracker) Inhaltsblockierregeln für WebKit und aktualisiert sie alle 4 Tage. Unter Einstellungen › Datenschutz kannst du Listen ausschalten oder weitere per Adresse hinzufügen (eine koreanische Werbeliste ist nur einen Klick entfernt). Wenn eine Website nicht richtig funktioniert, schaltet die Schild-Taste in der Adressleiste das Blockieren für diese Website aus. Regeln, die WebKit nicht ausdrücken kann (reguläre Ausdrücke, `$redirect`, Scriptlets, `:has-text` und andere erweiterte Selektoren), werden übersprungen, statt sie zu raten: Eine übersehene Anzeige ist besser als eine kaputte Seite.

## Erweiterungen

Verwaltung unter Einstellungen › Erweiterungen (Web-Erweiterungen brauchen macOS 15.4 oder neuer).

In den Tabs eines Profil-Spaces laufen Erweiterungen, aber ihre Cookie-APIs sehen nur den Standard-Datenspeicher, nicht den des Profils.

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
- Die Update-Prüfung lädt eine kleine Liste der Versionen (`appcast.xml`) von GitHub Pages. GitHub sieht die Anfrage wie jeder Webserver, mit Name und Version von Changmun; das Systemprofil von Sparkle, das Angaben zu deinem Mac hinzufügen würde, ist aus und bleibt aus (die Prüfung selbst lässt sich unter Einstellungen › Erweitert abschalten).
- Suchvorschläge senden, was du in die Befehlsleiste eingibst, an deine Suchmaschine (in den Einstellungen ausschaltbar; aus privaten Fenstern wird nie etwas gesendet).
- Die KI-Seitenleiste sendet deine Nachrichten, angehängte Bilder und die Seiteninhalte, die die KI liest, über das `claude`-CLI an Anthropic. „Tabs aufräumen“ und die Seitenübersetzung laufen auf deinem Mac.

## Passwörter und Sicherheit

Browsern, die Passwörter synchronisieren, wird eine berechtigte Frage gestellt: Liegt eine verschlüsselte Kopie meiner Passwörter auf eurem Server, und könntet ihr sie entschlüsseln, euch als mich anmelden oder sie verkaufen, wenn die Firma pleitegeht? Bei Changmun sind die Antworten kurz, und jede wurde am Code überprüft.

- **Wo sie liegen.** Im Anmelde-Schlüsselbund deines Mac, als Internetpasswörter mit der Bezeichnung `Changmun` (such in der Schlüsselbundverwaltung danach). Changmun markiert sie nicht als synchronisierbar, deshalb trägt auch der iCloud-Schlüsselbund sie nirgendwohin. Löschst du eines unter Einstellungen › Datenschutz › Gesicherte Passwörter › Verwalten …, ist es auch aus dem Schlüsselbund weg.
- **Nirgends sonst eine Kopie.** Changmun hat kein Konto und keinen Server, also gibt es keine verschlüsselte Kopie, die man entschlüsseln, verkaufen, leaken oder erben könnte. Außer den Anfragen unter Datenschutz holt die App von sich aus nur die Werbefilterlisten, eine von dir gewünschte Erweiterung aus dem Chrome Web Store und das Symbol jeder Website direkt von dieser Website. Keine davon enthält ein Passwort.
- **Wer sie entschlüsseln kann.** Nur dieser Mac, nachdem du ihn entsperrt hast. Touch ID oder dein Mac-Passwort wird verlangt, bevor Changmun ein Passwort kopiert, bevor es eines in eine Seite einsetzt (Einstellungen › Datenschutz › Touch ID zum Ausfüllen von Passwörtern verlangen, standardmäßig an; nach der Bestätigung fragt das Einsetzen in der nächsten Minute nicht erneut) und bevor die KI sich für dich anmeldet. Bei Abbruch wird nichts eingesetzt.
- **Die KI bekommt sie nie.** Bei `sign_in` füllt Changmun das Formular selbst aus und sagt der KI nur, dass es das getan hat, ohne Passwort und Kontonamen. Die KI kann Passwortfelder weder lesen noch darin tippen oder Tasten drücken, und Screenshots verdecken sie. Liest sie danach die angemeldete Seite, ist deren Text Seiteninhalt wie jeder andere.
- **Was an Anthropic geht.** Deine Nachrichten, angehängte Bilder und die Seiten, die die KI liest, über dein eigenes `claude`-CLI, und sonst nichts. Changmun besitzt keinen Anthropic-Schlüssel und stellt selbst keine Anfragen an Anthropic.
- **Chatverlauf.** Beendete Chats liegen nur in einer Datei auf diesem Mac (abschaltbar unter Einstellungen › KI), ohne getippten Text und ohne den Teil einer Adresse ab ? oder #, und aus privaten Fenstern nie.
- **Importierte Passwörter.** Werden auf deinem Mac mit dem `Safe Storage`-Schlüsselbundschlüssel des jeweiligen Browsers entschlüsselt (macOS fragt vorher) und in deinem Anmelde-Schlüsselbund gesichert. Unterwegs wird nichts hochgeladen.
- **Wenn das Projekt stehen bleibt.** Es gibt nichts zu verkaufen und nichts abzuschalten: kein Server, kein Konto, keine Datenbank von irgendjemandem. Deine Passwörter bleiben in deinem Schlüsselbund, und die App läuft, solange macOS läuft. Sie ist Open Source unter MIT, also kann das jeder überprüfen, am besten ab `Sources/Changmun/Tabs/Logins.swift`.

## Für Entwickler

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Releases werden für Sparkle mit einem EdDSA-Schlüssel signiert. Trage den Pfad der privaten Schlüsseldatei in `~/.config/changmun/sparkle.env` als `SPARKLE_KEY_FILE=...` ein; `release.sh` läuft ohne sie oder mit einem Schlüssel, der nicht zum `SUPublicEDKey` in `Resources/Info.plist` passt, nicht. Bewahre eine Sicherung dieser Datei offline auf. Geht sie verloren, lassen sich installierte Kopien nie wieder aktualisieren; gelangt sie in fremde Hände, kann jeder ein Update signieren, das sie annehmen.

Der Text der Oberfläche steht im Code auf Englisch und wird in `Resources/<Sprache>.lproj/Localizable.strings` übersetzt; trage jeden neuen String in alle sechs Tabellen ein.

`scripts/headless.sh` startet die Testkopie `Changmun Headless.app` (sie teilt nie ein Profil mit dem `changmun headless` aus dem KI-Abschnitt, das für Agenten da ist), ein Changmun ohne Oberfläche für Tests und Agenten: außerhalb des Bildschirms, ohne je den Fokus zu nehmen oder Ton abzuspielen, mit eigenem Profil in `~/Library/Application Support/Changmun Headless`. Es berührt den Schlüsselbund nicht und beantwortet KI-Rückfragen, Website-Berechtigungen und JavaScript-Dialoge selbst (Berechtigungen werden abgelehnt).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## Lizenz

[MIT](LICENSE)
