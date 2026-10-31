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

*Changmun* (창문) signifie *fenêtre* en coréen. Il est gratuit, open source et ne demande aucun compte. L’app est disponible en anglais, coréen, japonais, chinois simplifié, espagnol, allemand et français.

## Installer

```sh
brew install --cask namekun/tap/changmun
```

Ou [téléchargez l’app](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg) directement.

- Nécessite macOS 14 ou ultérieur sur un Mac à puce Apple.
- Signée et notarisée par Apple, elle s’ouvre tout de suite.
- Elle se met à jour toute seule.
- Au premier lancement, elle propose de récupérer vos signets et votre historique.

## Pourquoi Changmun

- **Léger.** Une app de 21 Mo, pour un téléchargement d’environ 7 Mo. Elle utilise le moteur WebKit que votre Mac possède déjà.
- **Une barre latérale.** Onglets verticaux, favoris, dossiers de signets, groupes d’onglets et espaces dans une seule colonne. Vous préférez les onglets en haut ? C’est un réglage.
- **Une IA qui utilise le navigateur.** Claude lit les pages, clique et saisit à votre place, et demande avant toute action risquée.
- **Privé.** Pas de compte, pas de serveur, pas d’analyse. Les publicités et les traceurs sont bloqués d’emblée.
- **Vos affaires vous suivent.** Il importe les signets et l’historique de Safari et des navigateurs Chromium, et les mots de passe de ces derniers.
- **Une page de démarrage à vous.** Trois styles, des sections que vous réorganisez à votre guise et votre propre arrière-plan.

## L’IA

Appuyez sur ⌘E et demandez avec vos mots :

- « Résume cette page. »
- « Compare les prix dans ces trois onglets. »
- « Connecte-moi à ce site. »

Elle s’appuie sur la CLI `claude` que vous avez déjà, donc sur votre propre abonnement Claude Code. Si vous n’utilisez pas Claude, ignorez simplement le panneau : le reste du navigateur fonctionne sans lui.

**Ce qui la garde sous contrôle**

- Elle demande avant de payer, d’envoyer, de publier ou de supprimer.
- Elle demande avant d’utiliser un onglet que vous ne regardez pas ou d’ouvrir un site inconnu.
- Elle ne voit pas les mots de passe et ne voit jamais les fenêtres privées.

Vos messages, les images que vous joignez et les pages qu’elle lit sont envoyés à Anthropic via la CLI `claude`. D’autres outils peuvent aussi piloter Changmun, via MCP ou la commande `changmun`.

## Comparaison avec les autres navigateurs

Changmun ne cherche pas à battre tous les navigateurs sur tous les points. Voici en quoi il diffère, et quand vous serez mieux servi ailleurs.

| | Taille de l’app | Moteur |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21 Mo** | WebKit, celui de macOS |
| Safari 27 | 35 Mo | WebKit, celui de macOS |
| Google Chrome 156 | 731 Mo | Chromium, sa propre copie |
| Arc 1.168 | 862 Mo | Chromium, sa propre copie |
| Dia 1.53 | 1,3 Go | Chromium, sa propre copie |

<sub>Mesuré avec `du -sh` sur un Mac à puce Apple en octobre 2026.</sub>

| Face à | Ce que Changmun vous apporte | Restez-y si vous avez besoin de |
| :-- | :-- | :-- |
| **Safari** | Le même moteur, avec en plus une barre latérale à onglets verticaux, une IA capable de manœuvrer une page et les extensions du Chrome Web Store | La synchronisation iCloud des onglets, des mots de passe et des clés d’accès |
| **Chrome** | Pas de compte Google ni de serveur de synchronisation, et une app d’environ 3 % de sa taille | Des sites conçus uniquement pour Chromium, la synchronisation de Chrome, ou Windows, Linux et les téléphones |
| **Arc** | La même idée de barre latérale et d’espaces, et il continue de gagner des fonctions (Arc est en mode maintenance depuis mai 2025) | Boosts ou Easels |
| **Dia** | La même famille d’idées, sans service d’IA propre ni compte : il utilise votre CLI `claude` | Ses fonctions d’IA hébergées et ses intégrations professionnelles |

Cela vient de ce que chaque projet dit de lui-même. Si quelque chose est périmé, [ouvrez une issue](https://github.com/namekun/Changmun/issues).

### Ce qui manque encore

- **Pas de synchronisation.** Signets, historique et mots de passe restent sur le Mac où ils ont été créés.
- **Mac uniquement.** Ni iPhone, ni Windows, ni Linux.
- **Pas encore de clés d’accès.** Les navigateurs ont besoin d’une autorisation (entitlement) d’Apple pour les gérer ; Changmun l’a demandée et attend.
- **Les extensions demandent macOS 15.4 ou ultérieur,** et certaines extensions Chrome s’appuient sur des choses que WebKit n’a pas.
- **Les sites conçus uniquement pour Chromium** peuvent mal se comporter ici, comme dans Safari.
- **Un seul mainteneur.** Moins d’yeux que chez les grands navigateurs, et des aspérités en proportion. Les rapports de bogues sont les bienvenus.

## Raccourcis à connaître

| Touches | Ce qu’elles font |
| :-- | :-- |
| ⌘T | Nouvel onglet |
| ⌘L | Modifier l’adresse |
| ⌘E | Panneau IA |
| ⌘D | Ajouter ou retirer un favori |
| ⌃1–9 | Aller à un espace |
| ⌥⌘\\ | Écran partagé |
| ⇧-clic sur un lien | En afficher un aperçu sans quitter la page |
| ⌘⇧T | Rouvrir un onglet fermé |

Touches style Safari ou style Chrome ? Choisissez dans les Réglages (⌘,). [Tous les raccourcis](GUIDE.fr.md#raccourcis).

## Confidentialité

Ce que vous faites sur le web reste sur votre Mac. L’app n’envoie d’elle-même que quelques requêtes, comme la recherche de mises à jour et l’actualisation des listes de filtres de publicités. Les suggestions de recherche envoient ce que vous saisissez à votre moteur de recherche ; vous pouvez les désactiver, et les fenêtres privées ne les envoient jamais. [Tout ce qui est envoyé, et quand](GUIDE.fr.md#confidentialité).

## En savoir plus

Le [guide](GUIDE.fr.md) détaille tout :

- [Fonctionnalités](GUIDE.fr.md#fonctionnalités) : onglets, espaces, mode lecture, fenêtres privées, téléchargements
- [IA](GUIDE.fr.md#ia) : modèles, approbations, outils, MCP et ligne de commande
- [Blocage des publicités](GUIDE.fr.md#blocage-des-publicités), [extensions](GUIDE.fr.md#extensions) et [importer depuis d’autres navigateurs](GUIDE.fr.md#importer-depuis-dautres-navigateurs)
- [Mots de passe et sécurité](GUIDE.fr.md#mots-de-passe-et-sécurité)
- [Pour les développeurs](GUIDE.fr.md#pour-les-développeurs) et [compiler à partir des sources](GUIDE.fr.md#compiler-à-partir-des-sources)

## Licence

MIT. Voir [LICENSE](LICENSE).
