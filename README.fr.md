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

## Compiler et lancer

Il n’y a pas encore de téléchargement : compilez l’app à partir des sources. Il vous faut macOS 14 ou ultérieur, ainsi que Xcode ou les Command Line Tools.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

Si seuls les Command Line Tools sont installés, les scripts compilent avec le SDK de macOS 26 (le plugin de macros SwiftUI du SDK de macOS 27 n’est fourni qu’avec Xcode). Les produits de compilation vont dans `~/Library/Caches/Changmun/build`, à l’abri de la synchronisation du Bureau par iCloud.

Au premier lancement, Changmun propose d’importer les signets, l’historique, les mots de passe et les sessions ouvertes du navigateur que vous utilisez actuellement.

## Fonctionnalités

- **Barre latérale.** Les favoris sous forme de vignettes, les dossiers de signets et les onglets verticaux. Faites glisser les onglets pour les réorganiser, ou sur les favoris pour les épingler. Comme dans Dia et Arc, chaque favori et chaque signet garde son propre onglet : un clic vous amène à cet onglet au lieu de remplacer celui que vous lisez (⌘-clic pour ouvrir un nouvel onglet).
- **Groupes d’onglets.** Clic droit sur un onglet › Ajouter à un nouveau groupe, donnez-lui un nom, repliez-le. Les onglets ouverts depuis l’onglet d’un groupe rejoignent ce groupe ; un onglet rouvert (⌘⇧T) retourne dans son groupe.
- **Ranger les onglets.** La baguette à côté de « Nouvel onglet » (Fenêtre › Ranger les onglets) regroupe les onglets isolés. Avec Apple Intelligence activée (macOS 26), le modèle de votre Mac les regroupe par sujet et nomme les groupes ; rien de ce qui concerne vos onglets ne quitte le Mac. Sans elle, les onglets ouverts les uns à partir des autres et les onglets d’un même site vont ensemble. « Annuler » remet tout en place pendant quelques secondes. Les nouveaux onglets ouverts depuis la barre d’adresse rejoignent d’eux-mêmes un groupe correspondant (désactivez cette option dans Réglages › Onglets et apparence).
- **Archivage des anciens onglets** (désactivé par défaut). Les onglets que vous n’avez pas consultés depuis un délai défini (de 12 heures à 30 jours, décompté uniquement pendant que Changmun est ouvert) se ferment dans Historique › Onglets archivés, prêts à être rouverts dans leur groupe. Les onglets visibles, en lecture, en image dans l’image, utilisant la caméra ou le micro, les favoris et les onglets privés ne sont jamais archivés.
- **Écran partagé** (⌥⌘\\) affiche deux onglets côte à côte. Le **mode concentration** (⌘⇧F) masque tout sauf la page. **Aperçu de lien** : ⇧-clic sur un lien pour l’ouvrir dans une carte flottante, ⌘↩ pour le conserver comme onglet.
- **Les fenêtres privées** gardent leurs cookies et les données des sites en mémoire et les oublient à la fermeture ; rien n’est envoyé à l’historique, à la session ni à l’IA.
- **Barre de commande** (⌘T) : recherche, adresses, passage aux onglets ouverts, signets et historique, et questions à l’IA.
- **Traduction des pages** sur place avec la traduction sur l’appareil de macOS (⌥⌘T, macOS 26 ou ultérieur). Les liens et la mise en page sont conservés ; le texte ne quitte jamais le Mac.
- **Image dans l’image** (⌃⌘P) s’active toute seule quand vous quittez un onglet où une vidéo est en lecture. ⌃⌘← / ⌃⌘→ avancent ou reculent de 5 secondes, même si vous êtes dans une autre app, et « Retour à l’onglet » ramène l’onglet au premier plan.
- **Les mots de passe** sont enregistrés dans le Trousseau après votre connexion (https uniquement) et remplis depuis la clé située dans la barre d’adresse. Pour en copier un, Touch ID ou le mot de passe de votre Mac est demandé.
- **Les pop-ups** ouverts sans clic sont bloqués, avec « Ouvrir » et « Toujours autoriser pour ce site » juste au-dessus de la page.
- **Les téléchargements** affichent leur progression en bas de la barre latérale et reçoivent l’indicateur de quarantaine de Safari, si bien que Gatekeeper les vérifie à la première ouverture. Les apps, scripts et installateurs sont affichés dans le Finder au lieu d’être exécutés.
- **Onglets en veille.** Les onglets en arrière-plan que vous n’avez pas vus depuis 20 minutes, et tous les onglets en arrière-plan quand la mémoire se fait rare, libèrent leur processus web et reviennent avec leur historique quand vous les rouvrez.
- Le zoom des pages est mémorisé pour chaque site, et les onglets ouverts sont enregistrés toutes les 15 secondes : un plantage ne coûte presque rien.

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
| Console | ⌥⌘C | ⌥⌘J |
| Téléchargements | ⌥⌘L | ⌘⇧J |
| Onglet précédent / Onglet suivant | | ⌥⌘← ⌥⌘→ |

## IA

Le panneau de droite (⌘E) utilise la CLI `claude` que vous avez déjà, il fonctionne donc avec votre abonnement Claude Code. Le modèle par défaut est Sonnet ; pour en changer, utilisez `defaults write io.github.namekun.Changmun aiModel opus`.

L’IA pilote le navigateur grâce à ces outils : `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. Elle ne peut ni lire ni remplir les champs de mot de passe.

Pour que des instructions cachées dans une page ne puissent pas lui faire emporter ailleurs ce qu’elle a lu, Changmun vous demande d’abord (et refuse après 90 secondes sans réponse) :

- avant qu’elle utilise un onglet que vous ne regardez pas, une fois par onglet et par site ;
- avant qu’elle ouvre une adresse, sauf s’il s’agit d’une recherche, d’une adresse déjà ouverte, visitée ou enregistrée dans les signets, ou de la page d’accueil d’un site connu ;
- avant chaque saisie de texte une fois que la conversation a lu un autre site, en vous montrant ce qu’elle va saisir. Une nouvelle conversation (⌘⇧E) repart de zéro.

D’autres agents, comme Claude Code, peuvent utiliser les mêmes outils via MCP, avec les mêmes questions :

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` lance Changmun s’il n’est pas déjà ouvert. Le serveur de contrôle écoute uniquement sur 127.0.0.1 et exige un jeton qui change à chaque lancement.

## Blocage des publicités

Changmun transforme EasyList (publicités) et EasyPrivacy (traqueurs) en règles de blocage de contenu WebKit et les actualise tous les 4 jours. Dans Réglages › Confidentialité, vous pouvez désactiver des listes ou en ajouter d’autres par leur adresse (une liste de publicités coréennes est à un clic). Si un site ne s’affiche plus correctement, le bouclier de la barre d’adresse désactive le blocage pour ce site. Les règles que WebKit ne sait pas exprimer (expressions régulières, `$redirect`, scriptlets, `:has-text` et autres sélecteurs étendus) sont ignorées plutôt que devinées.

## Extensions

Elles se gèrent dans Réglages › Extensions (les extensions web exigent macOS 15.4 ou ultérieur).

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
- Les suggestions de recherche envoient à votre moteur de recherche ce que vous saisissez dans la barre de commande (désactivez-les dans les Réglages ; jamais envoyées depuis les fenêtres privées).
- Le panneau IA envoie vos messages, ainsi que le contenu des pages que l’IA lit, à Anthropic via la CLI `claude`. Le rangement des onglets et la traduction des pages s’exécutent sur votre Mac.

## Pour les développeurs

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
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
