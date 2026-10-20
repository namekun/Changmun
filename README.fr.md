<p align="center"><img src="docs/images/icon.png" width="120" alt="Icône de Changmun"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>Un navigateur Mac léger, avec une barre latérale et une IA capable de s’en servir.</b><br>
  Le moteur WebKit de Safari, des onglets verticaux, des favoris et des dossiers de signets à gauche, et un panneau Claude qui lit les pages, clique et saisit du texte à votre place.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 ou ultérieur">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="Licence MIT"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="Swift natif">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <b>Français</b>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="Fenêtre de Changmun avec des onglets verticaux dans la barre latérale et une carte de page">
</p>

*Changmun* (창문) signifie *fenêtre* en coréen. Le navigateur est gratuit et open source, sans compte ni suivi. L’app est disponible en anglais, coréen, japonais, chinois simplifié, espagnol, allemand et français.

## Installer

```sh
brew install --cask namekun/tap/changmun
```

Il vous faut [Homebrew](https://brew.sh), macOS 14 Sonoma ou ultérieur et un Mac avec puce Apple. L’app est signée avec un Developer ID et notarisée par Apple, elle s’ouvre donc directement. Pour mettre à jour, lancez `brew update && brew upgrade --cask changmun`.

Au premier lancement, Changmun propose d’importer les signets, l’historique, les mots de passe et les sessions ouvertes du navigateur que vous utilisez actuellement.

### Compiler à partir des sources

Il vous faut macOS 14 ou ultérieur, ainsi que Xcode ou les Command Line Tools.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

Si seuls les Command Line Tools sont installés, les scripts compilent avec le SDK de macOS 26 (le plugin de macros SwiftUI du SDK de macOS 27 n’est fourni qu’avec Xcode). Les produits de compilation vont dans `~/Library/Caches/Changmun/build`, à l’abri de la synchronisation du Bureau par iCloud.

## Fonctionnalités

- **Barre latérale.** Les favoris sous forme de vignettes, les dossiers de signets et les onglets verticaux. Faites glisser les onglets pour les réorganiser, ou sur les favoris pour les épingler. Comme dans Dia et Arc, chaque favori et chaque signet garde son propre onglet : un clic vous amène à cet onglet au lieu de remplacer celui que vous lisez (⌘-clic pour ouvrir un nouvel onglet). Faites glisser un lien d’une page dans la barre latérale pour l’ouvrir dans un onglet, en faire un favori ou le ranger dans un dossier. Le menu d’un onglet permet aussi de le recharger, le dupliquer, le déplacer vers une nouvelle fenêtre, le partager ou l’ouvrir dans un autre navigateur. Fermer les onglets d’un groupe ou supprimer un signet peut s’annuler pendant quelques secondes.
- **La barre d’adresse où vous voulez.** En haut de la barre latérale, sous Précédent et Suivant, comme dans Arc, ou au-dessus de la page, comme dans Dia : Réglages › Apparence › Position de la barre d’adresse. Elle n’affiche que le site ; le bouclier et l’étoile apparaissent au survol. Sur une page favorite, l’étoile reste affichée : cliquez dessus pour la retirer des favoris.
- **Dossiers de signets.** Les dossiers importés gardent leur imbrication, comme dans le navigateur d’origine. Épinglez ceux que vous utilisez dans la barre latérale (clic droit ou … › Épingler dans la barre latérale, ou faites glisser le dossier sous les favoris) et ouvrez-les sur place. Faites glisser un signet sur un autre dossier ou sur les favoris, ou utilisez Déplacer vers dans son menu. Les autres signets sont derrière le bouton des signets, en bas de la barre latérale, avec un champ de recherche ; le … à côté ouvre l’Historique, les Onglets archivés, le Mode concentration et les Réglages.
- **Groupes d’onglets.** Clic droit sur un onglet › Ajouter à un nouveau groupe, donnez-lui un nom, repliez-le. Les onglets ouverts depuis l’onglet d’un groupe rejoignent ce groupe ; un onglet rouvert (⌘⇧T) retourne dans son groupe.
- **Espaces.** La rangée en bas de la barre latérale permet de changer d’espace : cliquez sur un point, appuyez sur ⌃1–⌃9 ou balayez latéralement à deux doigts sur la barre latérale (Fenêtre › Espace suivant, Espace précédent, Nouvel espace…). Chaque espace a ses propres onglets, groupes d’onglets, favoris et dossiers épinglés, et teinte légèrement la barre latérale de sa couleur. La bibliothèque de signets, l’historique et les mots de passe enregistrés sont partagés. Activez « Séparer connexions et cookies (profil) » à la création pour que l’espace ait aussi ses propres cookies et données de sites : un même site peut alors avoir deux comptes connectés côte à côte. Ce choix ne peut plus être changé, et supprimer un profil efface ses cookies et ses données de sites. Votre premier espace est créé à partir de ce que vous aviez déjà. Les fenêtres privées n’ont pas d’espaces. L’IA voit les onglets des espaces ordinaires (avec le nom de l’espace), mais ceux d’un espace à profil seulement quand vous y êtes.
- **Ranger les onglets.** La baguette à côté de « Nouvel onglet » (Fenêtre › Ranger les onglets) regroupe les onglets isolés. Avec Apple Intelligence activée (macOS 26), le modèle de votre Mac les regroupe par sujet et nomme les groupes ; rien de ce qui concerne vos onglets ne quitte le Mac. Sans elle, les onglets ouverts les uns à partir des autres et les onglets d’un même site vont ensemble. « Annuler » remet tout en place pendant quelques secondes. Les nouveaux onglets ouverts depuis la barre d’adresse rejoignent d’eux-mêmes un groupe correspondant (désactivez cette option dans Réglages › Onglets).
- **Archivage des anciens onglets** (désactivé par défaut). Les onglets que vous n’avez pas consultés depuis un délai défini (de 12 heures à 30 jours, décompté uniquement pendant que Changmun est ouvert) se ferment dans Historique › Onglets archivés, prêts à être rouverts dans leur groupe. Les onglets visibles, en lecture, en image dans l’image, utilisant la caméra ou le micro, les favoris et les onglets privés ne sont jamais archivés.
- **Écran partagé** (⌥⌘\\) affiche deux onglets côte à côte. Le **mode concentration** (⌘⇧F) masque tout sauf la page. **Aperçu de lien** : ⇧-clic sur un lien pour l’ouvrir dans une carte flottante, ⌘↩ pour le conserver comme onglet.
- **Les fenêtres privées** gardent leurs cookies et les données des sites en mémoire et les oublient à la fermeture ; rien n’est envoyé à l’historique, à la session ni à l’IA.
- **Barre de commande** (⌘T) : recherche, adresses, passage aux onglets ouverts, signets et historique, et questions à l’IA.
- **Traduction des pages** sur place avec la traduction sur l’appareil de macOS (⌥⌘T, macOS 26 ou ultérieur). Les liens et la mise en page sont conservés ; le texte ne quitte jamais le Mac.
- **Réglages du site.** Cliquez sur le cadenas, à gauche de la barre d’adresse, pour afficher un petit panneau avec ce que Changmun retient pour ce site : blocage des publicités, zoom, pop-ups, caméra et micro, et si ses onglets peuvent se mettre en veille. Cliquez ailleurs sur la barre, y compris sur le nom du site, pour modifier l’adresse, comme avant.
- Le **mode lecture** (⇧⌘R, ou ⌥⌘R avec les raccourcis façon Chrome) affiche un article en texte épuré et lisible par-dessus la page. Quand la page ressemble à un article, un bouton apparaît dans la barre d’adresse. Échap, la × ou le même raccourci rend la page telle qu’elle était. Un petit script dans la page s’en charge : les images de l’article se chargent depuis les mêmes endroits que ceux de la page, et rien d’autre n’est téléchargé ni envoyé.
- **Image dans l’image** (⌃⌘P) s’active toute seule quand vous quittez un onglet où une vidéo est en lecture. ⌃⌘← / ⌃⌘→ avancent ou reculent de 5 secondes, même si vous êtes dans une autre app, et « Retour à l’onglet » ramène l’onglet au premier plan.
- **Les mots de passe** sont enregistrés dans le Trousseau après votre connexion (https uniquement) et remplis depuis la clé située dans la barre d’adresse. Pour en copier un, Touch ID ou le mot de passe de votre Mac est demandé.
- **Les pop-ups** ouverts sans clic sont bloqués, avec « Ouvrir » et « Toujours autoriser pour ce site » juste au-dessus de la page.
- **Enregistrer une page** en un long PDF d’une seule page (Fichier › Enregistrer en PDF…) ou en une image de la page entière, et pas seulement de la partie visible (Fichier › Capturer la page entière…). Les deux sont aussi dans le menu d’un onglet, vont dans Téléchargements sauf si vous choisissez un autre dossier et fonctionnent aussi dans les fenêtres privées. Les pages qui défilent dans un panneau interne et les images chargées au défilement peuvent ne pas être capturées en entier.
- **Les téléchargements** affichent leur progression en bas de la barre latérale et reçoivent l’indicateur de quarantaine de Safari, si bien que Gatekeeper les vérifie à la première ouverture. Les apps, scripts et installateurs sont affichés dans le Finder au lieu d’être exécutés. Un téléchargement interrompu reprend là où il s’était arrêté avec Réessayer sur sa ligne.
- **Onglets en veille.** Les onglets en arrière-plan que vous n’avez pas vus depuis 20 minutes, et tous les onglets en arrière-plan quand la mémoire se fait rare, libèrent leur processus web et reviennent avec leur historique quand vous les rouvrez.
- Le zoom des pages est mémorisé pour chaque site, et les onglets ouverts sont enregistrés toutes les 15 secondes : un plantage ne coûte presque rien.
- **Avis de mise à jour.** Changmun se met à jour avec Homebrew. Une fois par jour, il demande à GitHub la dernière version et, s’il y en a une plus récente, une note discrète en bas de la barre latérale copie `brew upgrade --cask changmun` pour vous. Désactivez-la dans Réglages › Avancé › Rechercher des mises à jour.

## Raccourcis

Choisissez le style Safari ou le style Chrome dans les Réglages (⌘,). Seules les touches sur lesquelles les deux navigateurs divergent changent.

| Touches | Action |
| --- | --- |
| ⌘T / ⌘L | Barre de commande / modifier l’adresse actuelle |
| ⌘E / ⌘⇧E | Panneau IA / nouvelle conversation IA |
| ⌘D | Ajouter ou retirer un favori |
| ⌘N / ⌘⇧N / ⌘⇧W | Nouvelle fenêtre / nouvelle fenêtre privée / fermer la fenêtre |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | Fermer l’onglet, aller à un onglet dans l’ordre de la barre latérale |
| ⌃Tab / ⌃⇧Tab | Changer d’onglet dans l’ordre où vous les avez vus en dernier (maintenez ⌃, appuyez sur Tab, relâchez ; esc annule) |
| ⌃1–9 | Aller à un espace (9 est le dernier) ; cède la place à « Passer au bureau N » de macOS s’il est activé |
| ⌃⌥← / ⌃⌥→ | Espace précédent / suivant |
| ⌃⌘N | Nouvel espace |
| ⌥⌘\\ | Activer ou désactiver l’écran partagé |
| ⇧-clic | Aperçu de lien : esc le ferme, ⌘↩ l’ouvre dans un onglet |
| ⌘⇧T | Rouvrir l’onglet fermé (ou la fenêtre fermée quand il ne reste plus d’onglet) |
| ⌃⌘M | Couper ou réactiver le son de l’onglet |
| ⌃⌘P | Activer ou désactiver l’image dans l’image |
| ⌃⌘← / ⌃⌘→ | Reculer ou avancer la vidéo de 5 secondes |
| ⌥⌘T | Traduire la page / afficher l’original |
| ⌘F, ⌘G, ⌘⇧G | Rechercher dans la page, suivant, précédent |
| ⌘Y | Historique |
| ⌘O, ⌘P, ⌘⇧C | Ouvrir un fichier, imprimer, copier l’adresse |
| F12 ou ⌥⌘I | Inspecteur web |
| ⌘⇧F | Mode concentration |

| Action | Style Safari | Style Chrome |
| --- | --- | --- |
| Barre latérale | ⌘⇧L | ⌘S |
| Actualisation forcée | ⌥⌘R | ⌘⇧R |
| Mode lecture | ⇧⌘R | ⌥⌘R |
| Console | ⌥⌘C | ⌥⌘J |
| Téléchargements | ⌥⌘L | ⌘⇧J |
| Onglet précédent / Onglet suivant | | ⌥⌘← ⌥⌘→ |

## IA

Le panneau de droite (⌘E) utilise la CLI `claude` que vous avez déjà, il fonctionne donc avec votre abonnement Claude Code. Le modèle par défaut est Sonnet ; pour en changer, utilisez `defaults write io.github.namekun.Changmun aiModel opus`.

L’IA pilote le navigateur grâce à ces outils : `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `read_tabs`, `click`, `type_text`, `scroll`, `screenshot`. Elle ne peut ni lire ni remplir les champs de mot de passe.

Pour travailler sur plusieurs onglets, ajoutez-les sous le chat avec « Ajouter un onglet » (un par un, un groupe d’onglets ou tous les onglets ouverts) : ils apparaissent sous forme de pastilles que vous pouvez retirer, l’IA les lit ensemble avec `read_tabs` et ne vous demande rien avant de les lire. Avec deux onglets ou plus, le panneau propose de les comparer ou de résumer l’essentiel de chacun.

Pour que des instructions cachées dans une page ne puissent pas lui faire emporter ailleurs ce qu’elle a lu, Changmun vous demande d’abord (et refuse après 90 secondes sans réponse) :

- avant qu’elle utilise un onglet que vous ne regardez pas, une fois par onglet et par site ;
- avant qu’elle ouvre une adresse, sauf s’il s’agit d’une recherche, d’une adresse déjà ouverte, visitée ou enregistrée dans les signets, ou de la page d’accueil d’un site connu ;
- avant chaque saisie de texte une fois que la conversation a lu un autre site, en vous montrant ce qu’elle va saisir. Une nouvelle conversation (⌘⇧E) repart de zéro.

D’autres agents, comme Claude Code, peuvent utiliser les mêmes outils via MCP, avec les mêmes questions :

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` lance Changmun s’il n’est pas déjà ouvert. Le serveur de contrôle écoute uniquement sur 127.0.0.1 et exige un jeton qui change à chaque lancement.

Ou depuis un shell, pour tout agent capable de lancer des commandes (Homebrew place `changmun` dans le PATH) :

```sh
changmun tabs
changmun open example.com
changmun read
changmun read-tabs 3 5
changmun click 12
changmun type 3 "hello" --submit
```

`changmun help` liste le reste. Chaque commande est l’un des mêmes outils, avec les mêmes questions, et lance Changmun si besoin.

## Blocage des publicités

Changmun transforme EasyList (publicités) et EasyPrivacy (traqueurs) en règles de blocage de contenu WebKit et les actualise tous les 4 jours. Dans Réglages › Confidentialité, vous pouvez désactiver des listes ou en ajouter d’autres par leur adresse (une liste de publicités coréennes est à un clic). Si un site ne s’affiche plus correctement, le bouclier de la barre d’adresse désactive le blocage pour ce site. Les règles que WebKit ne sait pas exprimer (expressions régulières, `$redirect`, scriptlets, `:has-text` et autres sélecteurs étendus) sont ignorées plutôt que devinées.

## Extensions

Elles se gèrent dans Réglages › Extensions (les extensions web exigent macOS 15.4 ou ultérieur).

Dans les onglets d’un espace à profil, les extensions fonctionnent, mais leurs API de cookies ne voient que le stockage de données par défaut, pas celui du profil.

- **Les extensions Safari de l’App Store** apparaissent dès qu’elles sont installées et demandent leurs autorisations quand vous les activez.
- **Les extensions du Chrome Web Store** : ouvrez la page d’une extension et « Ajouter à Changmun » s’affiche au-dessus (ou collez son adresse ou son ID dans les Réglages). Changmun la décompresse dans `~/Library/Application Support/Changmun/Extensions` et la charge comme extension WebKit ; l’ajouter de nouveau la met à jour.
- **Les bloqueurs de contenu Safari** (Unicorn, AdGuard et d’autres) : macOS n’autorise que Safari à demander ses règles à un bloqueur, c’est pourquoi Changmun lit le fichier de règles que le bloqueur a enregistré. macOS demande une fois s’il peut lire les données d’une autre app.
- Un dossier d’extension décompressé (contenant `manifest.json`) se charge aussi. Certaines fonctionnalités, comme la communication avec une app native, peuvent ne pas fonctionner.

## Importer depuis d’autres navigateurs

Au premier lancement, ou depuis le menu, Changmun importe les signets et l’historique de Safari et des navigateurs Chromium : Chrome, Arc (avec sa barre latérale), Dia, Aside, Whale, Brave, Edge, Vivaldi. Depuis les navigateurs Chromium, il reprend aussi les mots de passe et les cookies, pour que vous restiez connecté.

- Les mots de passe et les cookies sont déchiffrés avec l’élément du Trousseau de chaque navigateur (`<name> Safe Storage`), et macOS vous demande donc de l’autoriser. Les mots de passe importés vont dans votre Trousseau de session sous le nom `Changmun`.
- La lecture de Safari exige l’accès complet au disque. macOS ne transmet pas les mots de passe de Safari aux autres apps.

## Confidentialité

- Votre navigation reste sur votre Mac. Changmun n’a ni compte, ni serveur, ni outil d’analyse.
- La recherche de mises à jour interroge une fois par jour l’API publique des versions de GitHub pour connaître le dernier numéro de version et n’envoie rien d’autre (désactivable dans Réglages › Avancé).
- Les suggestions de recherche envoient à votre moteur de recherche ce que vous saisissez dans la barre de commande (désactivez-les dans les Réglages ; jamais envoyées depuis les fenêtres privées).
- Le panneau IA envoie vos messages, ainsi que le contenu des pages que l’IA lit, à Anthropic via la CLI `claude`. Le rangement des onglets et la traduction des pages s’exécutent sur votre Mac.

## Pour les développeurs

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Le texte de l’interface est en anglais dans le code et traduit dans `Resources/<language>.lproj/Localizable.strings` ; ajoutez chaque nouvelle chaîne aux six tables.

`scripts/headless.sh` lance un Changmun sans interface pour les tests et les agents : hors écran, sans jamais prendre le focus ni émettre de son, avec son propre profil dans `~/Library/Application Support/Changmun Headless`. Il ne touche pas au Trousseau et répond lui-même aux confirmations de l’IA, aux autorisations des sites et aux boîtes de dialogue JavaScript (les autorisations sont refusées).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## Licence

[MIT](LICENSE)
