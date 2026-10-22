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

*Changmun* (창문) signifie *fenêtre* en coréen. Pour un nom de navigateur, difficile de faire plus franc. Il est gratuit et open source, sans compte ni suivi. L’app est disponible en anglais, coréen, japonais, chinois simplifié, espagnol, allemand et français.

## Pourquoi Changmun

- **Léger.** Chaque navigateur Chromium embarque sa propre copie de Chromium. Changmun emprunte plutôt le moteur WebKit livré avec macOS, celui de Safari : le téléchargement fait environ 3 Mo (le DMG de la 0.4.1 pèse 2,6 Mo). Il ménage la batterie, et les correctifs de sécurité du moteur arrivent avec les mises à jour de macOS et de Safari.
- **Une barre latérale comme Arc et Dia.** Des onglets verticaux dont les titres ont la place de respirer, des favoris en vignettes, des dossiers de signets, des groupes d’onglets et des espaces.
- **Une IA qui utilise le navigateur.** Le panneau Claude lit les pages, clique et saisit à votre place via la CLI `claude` que vous avez déjà. Elle prête ses mains, mais n’a pas carte blanche : elle demande avant toute action risquée.
- **Privé par défaut.** Ni compte, ni serveur, ni analyse : rien à créer pour commencer. Le blocage des publicités et des traqueurs est intégré.
- **Déménagement, meubles compris.** Importe signets et historique depuis Safari et les navigateurs Chromium, et depuis ces derniers aussi les mots de passe et les connexions. Les mots de passe de Safari restent sur place : macOS ne les confie à aucune autre app.

## Installer

```sh
brew install --cask namekun/tap/changmun
```

Il vous faut [Homebrew](https://brew.sh), macOS 14 Sonoma ou ultérieur et un Mac avec puce Apple. L’app est signée avec un Developer ID et notarisée par Apple, elle s’ouvre donc directement. Les mises à jour arrivent dans l’app (Changmun › Rechercher des mises à jour…, automatiques par défaut) ; Homebrew ne sert qu’à l’installation.

Au premier lancement, Changmun propose d’importer les signets et l’historique du navigateur que vous utilisez actuellement, avec les mots de passe et les sessions ouvertes si c’est un navigateur Chromium.

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

### Barre latérale et onglets

- **Barre latérale.** Réunit vos favoris, signets et onglets ouverts dans une colonne à gauche : favoris en vignettes, dossiers de signets, onglets verticaux. Faites glisser les onglets pour les réorganiser, ou sur les favoris pour les épingler. Comme dans Dia et Arc, chaque favori et chaque signet garde son propre onglet : un clic vous amène à cet onglet au lieu de remplacer celui que vous lisez (⌘-clic pour ouvrir un nouvel onglet). Faites glisser un lien d’une page dans la barre latérale pour l’ouvrir dans un onglet, en faire un favori ou le ranger dans un dossier. Le menu d’un onglet permet aussi de le recharger, le dupliquer, le déplacer vers une nouvelle fenêtre, le partager ou l’ouvrir dans un autre navigateur. Fermer les onglets d’un groupe ou supprimer un signet peut s’annuler pendant quelques secondes, le temps que le regret arrive.
- **La barre d’adresse où vous voulez.** Placez-la là où votre main la cherche : en haut de la barre latérale, sous Précédent et Suivant, comme dans Arc, ou au-dessus de la page, comme dans Dia (Réglages › Apparence › Position de la barre d’adresse). Elle n’affiche que le site ; le bouclier et l’étoile apparaissent au survol. Sur une page favorite, l’étoile reste affichée : cliquez dessus pour la retirer des favoris.
- **Dossiers de signets.** Vos signets gardent le classement que vous avez bâti, et restent à portée de main. Les dossiers importés gardent leur imbrication, comme dans le navigateur d’origine. Épinglez ceux que vous utilisez dans la barre latérale (clic droit ou … › Épingler dans la barre latérale, ou faites glisser le dossier sous les favoris) et ouvrez-les sur place. Faites glisser un signet sur un autre dossier ou sur les favoris, ou utilisez Déplacer vers dans son menu. Les autres signets sont derrière le bouton des signets, en bas de la barre latérale, avec un champ de recherche ; le … à côté ouvre l’Historique, les Onglets archivés, le Mode concentration et les Réglages.
- **Groupes d’onglets.** Garde ensemble les onglets liés et les met à l’écart. Clic droit sur un onglet › Ajouter à un nouveau groupe, donnez-lui un nom, repliez-le. Les onglets ouverts depuis l’onglet d’un groupe rejoignent ce groupe ; un onglet rouvert (⌘⇧T) retourne dans son groupe. Faites glisser un groupe par son en-tête pour le déplacer, ou vers le haut sur les favoris ou les dossiers épinglés pour le garder, onglets compris, dans un seul dossier de signets.
- **Ranger les onglets.** Transforme en un clic un tas d’onglets isolés en groupes. Un coup de baguette à côté de « Nouvel onglet » (Fenêtre › Ranger les onglets) et les onglets isolés sont regroupés. Avec Apple Intelligence activée (macOS 26), le modèle de votre Mac les regroupe par sujet et nomme les groupes ; rien de ce qui concerne vos onglets ne quitte le Mac. Sans elle, les onglets ouverts les uns à partir des autres et les onglets d’un même site vont ensemble. « Annuler » remet tout en place pendant quelques secondes. Les nouveaux onglets ouverts depuis la barre d’adresse rejoignent d’eux-mêmes un groupe correspondant (désactivez cette option dans Réglages › Onglets).
- **Archivage des anciens onglets** (désactivé par défaut). Met de côté les onglets que vous ne regardez plus, au lieu de les jeter. Les onglets que vous n’avez pas consultés depuis un délai défini (de 12 heures à 30 jours, décompté uniquement pendant que Changmun est ouvert) se ferment dans Historique › Onglets archivés, prêts à être rouverts dans leur groupe. Les onglets visibles, en lecture, en image dans l’image, utilisant la caméra ou le micro, les favoris et les onglets privés ne sont jamais archivés.
- **Onglets en veille.** Laisse les onglets en arrière-plan faire la sieste et vous rend leur mémoire. Les onglets en arrière-plan que vous n’avez pas vus depuis 20 minutes, et tous les onglets en arrière-plan quand la mémoire se fait rare, libèrent leur processus web et reviennent avec leur historique quand vous les rouvrez.
- **Barre de commande** (⌘T). Une seule zone pour tout : la recherche, les adresses, le passage aux onglets ouverts, les signets et l’historique, et les questions à l’IA.

### Espaces et profils

- **Espaces.** Sépare onglets, groupes d’onglets et favoris selon l’usage, pour que le travail ne vous suive pas le week-end. La rangée en bas de la barre latérale permet de changer d’espace : cliquez sur un point, appuyez sur ⌃1–⌃9 ou balayez latéralement à deux doigts sur la barre latérale (Fenêtre › Espace suivant, Espace précédent, Nouvel espace…). Chaque espace a ses propres onglets, groupes d’onglets, favoris et dossiers épinglés, et teinte légèrement la barre latérale de sa couleur. La bibliothèque de signets, l’historique et les mots de passe enregistrés sont partagés. Activez « Séparer connexions et cookies (profil) » à la création pour que l’espace ait aussi ses propres cookies et données de sites : un même site peut alors avoir deux comptes connectés côte à côte. Ce choix ne peut plus être changé, et supprimer un profil efface ses cookies et ses données de sites. Votre premier espace est créé à partir de ce que vous aviez déjà. Les fenêtres privées n’ont pas d’espaces. L’IA voit les onglets des espaces ordinaires (avec le nom de l’espace), mais ceux d’un espace à profil seulement quand vous y êtes.

### Lire et regarder

- **Mode lecture.** Lisez un article en texte épuré et lisible. ⇧⌘R (ou ⌥⌘R avec les raccourcis façon Chrome) l’affiche par-dessus la page. Quand la page ressemble à un article, un bouton apparaît dans la barre d’adresse. Échap, la × ou le même raccourci rend la page telle qu’elle était. Un petit script dans la page s’en charge : les images de l’article se chargent depuis les mêmes endroits que ceux de la page, et rien d’autre n’est téléchargé ni envoyé.
- **Traduction des pages.** Lisez une page dans une autre langue sans la quitter. Elle se fait sur place avec la traduction sur l’appareil de macOS (⌥⌘T, macOS 26 ou ultérieur). Les liens et la mise en page sont conservés ; le texte ne quitte jamais le Mac.
- **Écran partagé** (⌥⌘\\). Pour les fois où une page ne suffit pas : deux onglets côte à côte.
- **Mode concentration** (⌘⇧F). Masque tout sauf la page. Rester concentré, en revanche, reste votre affaire.
- **Aperçu de lien.** Jetez un œil à un lien sans quitter la page où vous êtes. ⇧-clic sur un lien pour l’ouvrir dans une carte flottante, ⌘↩ pour le conserver comme onglet.
- **Image dans l’image** (⌃⌘P). Garde une vidéo à l’écran après avoir quitté son onglet. Elle s’active toute seule quand vous quittez un onglet où une vidéo est en lecture. ⌃⌘← / ⌃⌘→ avancent ou reculent de 5 secondes, même si vous êtes dans une autre app, et « Retour à l’onglet » ramène l’onglet au premier plan.

### Confidentialité et sécurité

- **Fenêtres privées.** Naviguez sans rien laisser derrière vous. Les fenêtres privées gardent leurs cookies et les données des sites en mémoire et les oublient à la fermeture ; rien n’est envoyé à l’historique, à la session ni à l’IA.
- **Réglages du site.** Affiche et modifie au même endroit ce que Changmun retient pour un site. Cliquez sur le cadenas, à gauche de la barre d’adresse, pour afficher un petit panneau avec ce que Changmun retient pour ce site : blocage des publicités, zoom, pop-ups, caméra et micro, et si ses onglets peuvent se mettre en veille. Cliquez ailleurs sur la barre, y compris sur le nom du site, pour modifier l’adresse, comme avant.
- **Mots de passe.** Les retenir, c’est le travail du Trousseau. Ils sont enregistrés dans le Trousseau après votre connexion (https uniquement) et remplis depuis la clé située dans la barre d’adresse. Pour en copier ou en remplir un, Touch ID ou le mot de passe de votre Mac est demandé (au remplissage, cela se désactive dans Réglages › Confidentialité).
- **Pop-ups.** Les pages n’ouvrent pas de fenêtres sans qu’on le leur demande. Les pop-ups ouverts sans clic sont bloqués, avec « Ouvrir » et « Toujours autoriser pour ce site » juste au-dessus de la page.

Le blocage des publicités et des traqueurs est décrit dans [Blocage des publicités](#blocage-des-publicités), et ce qui reste sur votre Mac ou est envoyé dans [Confidentialité](#confidentialité).

### Enregistrer et télécharger

- **Enregistrer une page.** Gardez une page pour plus tard en PDF ou en image. Enregistrez-la en un long PDF d’une seule page (Fichier › Enregistrer en PDF…) ou en une image de la page entière, et pas seulement de la partie visible (Fichier › Capturer la page entière…). Les deux sont aussi dans le menu d’un onglet, vont dans Téléchargements sauf si vous choisissez un autre dossier et fonctionnent aussi dans les fenêtres privées. Les pages qui défilent dans un panneau interne et les images chargées au défilement peuvent ne pas être capturées en entier.
- **Téléchargements.** Suivez un téléchargement, avec une vérification de sécurité à la première ouverture. La progression s’affiche en bas de la barre latérale et les fichiers reçoivent l’indicateur de quarantaine de Safari, si bien que Gatekeeper les vérifie à la première ouverture. Les apps, scripts et installateurs sont affichés dans le Finder au lieu d’être exécutés. Un téléchargement interrompu reprend là où il s’était arrêté avec Réessayer sur sa ligne.
- **Zoom des pages.** Réglez le zoom d’un site une fois, il reste ainsi. Il est mémorisé pour chaque site, vous ne plissez donc les yeux qu’une fois.
- **Sauvegarde de session.** Les navigateurs aussi plantent. Les onglets ouverts sont enregistrés toutes les 15 secondes, un plantage ne coûte donc presque rien.

### Mises à jour

- **Mises à jour automatiques.** Changmun se met à jour tout seul avec Sparkle. Il vérifie une fois par jour en arrière-plan et, quand une nouvelle version est disponible, propose de l’installer ; Changmun › Rechercher des mises à jour… vérifie tout de suite. Les mises à jour sont signées, et Changmun n’en installe une que si la signature correspond à la clé intégrée à l’app. Dans Réglages › Avancé, vous pouvez désactiver la vérification automatique ou le laisser télécharger et installer seul.

## IA

Le panneau de droite (⌘E) utilise la CLI `claude` que vous avez déjà, il fonctionne donc avec votre abonnement Claude Code. Le modèle par défaut est Sonnet ; pour en changer, utilisez `defaults write io.github.namekun.Changmun aiModel opus`.

L’IA pilote le navigateur grâce à ces outils : `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `read_tabs`, `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover`, `drag`, `wait_for`, `scroll`, `screenshot`, `sign_in`. Elle ne peut ni lire, ni remplir, ni toucher au clavier les champs de mot de passe, de code à usage unique et de carte, et les captures d’écran les masquent. Elle ne peut pas non plus téléverser de fichiers.

- `read_page` ajoute à chaque élément ses états entre crochets : `[checked]`/`[unchecked]`, `[selected]`, `[expanded]`/`[collapsed]`, `[disabled]`, `[focused]`, `[pressed]`, `[required]`, `[invalid]`. La valeur actuelle des champs et des listes tient sur une ligne, mais jamais pour un mot de passe, un code ou une carte.
- Après `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover` et `drag`, une fois la page stabilisée (1,5 seconde au plus), la réponse dit ce qui a changé depuis le dernier regard de l’IA : adresse et titre, éléments nouveaux (`+`, numérotés à la suite, donc utilisables tout de suite), modifiés (`~`) et disparus (`-`). 40 lignes au plus ; après une navigation, elle le dit simplement et conseille `read_page`. Cela compte comme une lecture. Un changement du seul focus vient en dernier et ne compte pas dans les 40 lignes ; un cadre qui ne répond pas est laissé de côté et signalé ; un élément qui revient (un menu rouvert) est de nouveau nouveau.
- `screenshot` avec `labels` relit la page et dessine sur l’image un cadre portant le numéro de `read_page` de chaque élément visible. Rien n’est ajouté à la page : le dessin n’est fait que sur l’image. La place des cadres suit la mise en page de la page ; pour les éléments, ce que dit `read_page` fait foi. `changmun screenshot --labels` marche aussi.
- Chaque outil accepte un `title` facultatif (« Comparaison des prix ») affiché tel quel dans la ligne de progression du panneau ; sinon, le texte que Changmun fabrique. C’est du texte du modèle : il est ramené à une ligne de 60 caractères et ne joue aucun rôle dans une question ou une décision. Le titre vient après le texte de Changmun (« Clic sur « Acheter » · Comparaison des prix ») et ne le remplace jamais ; pour `sign_in` et ce qui demande à chaque fois, seul le texte de Changmun est montré.
- Pendant que l’IA travaille, le champ accepte encore des messages. Entrée en met un en file d’attente sous forme de pastille, et ils partent dans l’ordre quand l’exécution précédente se termine bien (avec les onglets du moment où vous l’avez écrit). Si l’exécution échoue ou est interrompue, les pastilles restent et un bouton « Envoyer la file » attend votre feu vert. ⌘Entrée arrête l’exécution comme Arrêter et poursuit aussitôt, dans la même conversation, avec le nouveau message. Arrêter et Nouvelle conversation vident la file. 8 messages au plus attendent (une ligne le dit au-delà) ; un second ⌘Retour pendant l’attente s’ajoute au premier ; si la conversation ne peut pas être reprise après l’interruption, le message repart dans une nouvelle conversation et le panneau le dit. Avec une méthode de saisie (coréen, japonais, chinois), Retour lui appartient tant que du texte est en cours de composition.
- `sign_in` remplit votre identifiant enregistré dans le formulaire sans que l’IA le voie. L’hôte exact de la page doit être celui de l’identifiant enregistré (https seulement), et c’est impossible en navigation privée. À chaque fois, une fenêtre demande « Laisser l’IA se connecter à … en tant que … ? » et Touch ID ou le mot de passe du Mac confirme (avec plusieurs comptes, vous en choisissez un dans la fenêtre). Si aucun identifiant n’est enregistré, si vous refusez, ne répondez pas ou ne confirmez pas, l’IA entend toujours la même chose, « La connexion n’a pas été faite », et ne peut donc pas savoir quels comptes vous avez. L’IA ne reçoit ni le mot de passe ni le nom du compte. Rien n’est pressé : le clic suivant est celui de l’IA, jugé comme les autres. Sans identifiant enregistré, une fenêtre s’affiche aussi (à fermer seulement) et l’IA attend aussi longtemps ; après un refus pour un site, il n’y a plus de fenêtre dans le même chat mais une attente fixe de quatre secondes et une ligne dans le panneau. Les formulaires dont l’action ou un bouton d’envoi (où qu’il soit) mène à un autre site sont refusés.

Pour travailler sur plusieurs onglets, ajoutez-les sous le chat avec « Ajouter un onglet » (un par un, un groupe d’onglets ou tous les onglets ouverts) : ils apparaissent sous forme de pastilles que vous pouvez retirer, l’IA les lit ensemble avec `read_tabs` et ne vous demande rien avant de les lire. Avec deux onglets ou plus, le panneau propose de les comparer ou de résumer l’essentiel de chacun.

Pour que des instructions cachées dans une page ne puissent pas lui faire emporter ailleurs ce qu’elle a lu, Changmun vous demande d’abord (et refuse après 90 secondes sans réponse) :

- avant qu’elle utilise un onglet que vous ne regardez pas, une fois par onglet et par site ;
- avant qu’elle ouvre une adresse, sauf s’il s’agit d’une recherche, d’une adresse déjà ouverte, visitée ou enregistrée dans les signets, ou de la page d’accueil d’un site connu ;
- avant chaque clic, touche, survol, glisser-déposer, texte saisi ou option choisie une fois que la conversation a lu un autre site, en vous montrant ce qu’elle va faire. Vous pouvez l’autoriser une fois, ou sur ce site jusqu’à la fin de la conversation. Le défilement, le regard sur la page au premier plan (lecture, capture, attente, liste des onglets) et le retour, l’avance ou le rechargement ne demandent rien. Une nouvelle conversation (⌘⇧E) repart de zéro.
- avant tout ce qui ressemble à un paiement, une commande, un envoi, une publication, un commentaire, un partage, un téléversement, un accès accordé (autoriser, connecter), une suppression, une annulation ou une résiliation, à chaque fois, quoi que vous ayez autorisé (seulement « Autoriser une fois » ou « Ne pas autoriser »). De même pour Entrée dans une zone de message, un formulaire qui envoie vers un autre site et Suppr ou Retour arrière hors d’un champ de texte.
- avant tout ce qui ressemble à accepter ou autoriser dans une bannière de cookies, ou à un réglage (enregistrer, effacer, réinitialiser, bloquer), une fois par site. Dans le panneau IA, vous pouvez l’autoriser sur ce site jusqu’à la fin de la conversation ; les autres agents sont interrogés à chaque fois.

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

## Blocage des publicités

Changmun transforme EasyList (publicités) et EasyPrivacy (traqueurs) en règles de blocage de contenu WebKit et les actualise tous les 4 jours. Dans Réglages › Confidentialité, vous pouvez désactiver des listes ou en ajouter d’autres par leur adresse (une liste de publicités coréennes est à un clic). Si un site ne s’affiche plus correctement, le bouclier de la barre d’adresse désactive le blocage pour ce site. Les règles que WebKit ne sait pas exprimer (expressions régulières, `$redirect`, scriptlets, `:has-text` et autres sélecteurs étendus) sont ignorées plutôt que devinées : mieux vaut rater une publicité que casser une page.

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
- La recherche de mises à jour récupère sur GitHub Pages une petite liste de versions (`appcast.xml`). GitHub reçoit la requête comme n’importe quel serveur web, avec le nom et la version de Changmun ; le profil système de Sparkle, qui ajouterait des détails sur votre Mac, est désactivé et le reste (Réglages › Avancé désactive la vérification).
- Les suggestions de recherche envoient à votre moteur de recherche ce que vous saisissez dans la barre de commande (désactivez-les dans les Réglages ; jamais envoyées depuis les fenêtres privées).
- Le panneau IA envoie vos messages, ainsi que le contenu des pages que l’IA lit, à Anthropic via la CLI `claude`. Le rangement des onglets et la traduction des pages s’exécutent sur votre Mac.

## Mots de passe et sécurité

On pose aux navigateurs qui synchronisent les mots de passe une question légitime : une copie chiffrée de mes mots de passe est-elle sur votre serveur, et pourriez-vous la déchiffrer, vous connecter à ma place ou la vendre si l’entreprise fait faillite ? Pour Changmun, les réponses sont courtes, et chacune a été vérifiée dans le code.

- **Où ils se trouvent.** Dans le Trousseau de session de votre Mac, comme mots de passe Internet portant le nom `Changmun` (cherchez-le dans Accès au trousseau). Changmun ne les marque pas comme synchronisables, donc le Trousseau iCloud ne les emporte pas non plus. En supprimer un dans Réglages › Confidentialité › Mots de passe enregistrés › Gérer…, c’est aussi le retirer du Trousseau.
- **Aucune copie ailleurs.** Changmun n’a ni compte ni serveur : il n’existe donc aucune copie chiffrée à déchiffrer, vendre, divulguer ou hériter. En dehors des requêtes listées sous Confidentialité, l’app ne télécharge d’elle-même que les listes de filtres publicitaires, une extension du Chrome Web Store que vous avez demandée, et l’icône de chaque site, directement depuis ce site. Aucune ne transporte de mot de passe.
- **Qui peut les déchiffrer.** Seulement ce Mac, une fois que vous l’avez déverrouillé. Touch ID ou le mot de passe de votre Mac est demandé avant que Changmun copie un mot de passe, avant qu’il en remplisse un dans une page (Réglages › Confidentialité › Exiger Touch ID pour remplir les mots de passe, activé par défaut ; une fois confirmé, les remplissages de la minute suivante ne redemandent rien) et avant que l’IA se connecte pour vous. Si vous annulez, rien n’est rempli.
- **L’IA ne les reçoit jamais.** Avec `sign_in`, Changmun remplit lui-même le formulaire et dit seulement à l’IA qu’il l’a fait, sans le mot de passe ni le nom du compte. L’IA ne peut ni lire les champs de mot de passe, ni y saisir du texte, ni y appuyer sur des touches, et les captures d’écran les masquent. Si elle lit ensuite la page connectée, le texte de cette page est du contenu de page comme un autre.
- **Ce qui part chez Anthropic.** Vos messages et les pages que lit l’IA, via votre propre CLI `claude`, et rien d’autre. Changmun ne détient aucune clé Anthropic et n’adresse lui-même aucune requête à Anthropic.
- **Mots de passe importés.** Déchiffrés sur votre Mac avec la clé `Safe Storage` du Trousseau de chaque navigateur (macOS demande d’abord) et enregistrés dans votre Trousseau de session. Rien n’est envoyé en chemin.
- **Si le projet s’arrête.** Il n’y a rien à vendre ni à éteindre : pas de serveur, pas de compte, la base de données de personne. Vos mots de passe restent dans votre Trousseau et l’app fonctionne tant que macOS fonctionne. Le code est ouvert sous licence MIT : chacun peut tout vérifier, en commençant par `Sources/Changmun/Logins.swift`.

## Pour les développeurs

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Les versions sont signées pour Sparkle avec une clé EdDSA. Indiquez le chemin du fichier de la clé privée dans `~/.config/changmun/sparkle.env` avec `SPARKLE_KEY_FILE=...` ; `release.sh` refuse de tourner sans lui, ou avec une clé qui ne correspond pas au `SUPublicEDKey` de `Resources/Info.plist`. Gardez une sauvegarde de ce fichier hors ligne. S’il est perdu, les copies installées ne pourront plus jamais être mises à jour ; s’il fuit, n’importe qui peut signer une mise à jour qu’elles accepteront.

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
