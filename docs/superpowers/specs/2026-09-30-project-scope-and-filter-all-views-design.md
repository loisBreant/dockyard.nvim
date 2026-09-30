# Portée projet et filtre dans toutes les vues — design

Date : 2026-09-30 · Statut : validé par l'utilisateur (« ok go ») · Travail directement sur `main` (local, sans push)

## Contexte et objectif

Seule la vue Containers sait se limiter au projet courant (`P`) et filtrer (`F` / `C`). Images, Networks, Volumes et Jobs
montrent tout, alors qu'on travaille sur un projet à la fois.

**Objectif** : ces quatre vues se comportent comme Containers :

- un filtre texte (`F` / `C`), avec la ligne `Filter: … (n/N)` ;
- la portée « projet courant » **active par défaut** quand le projet a un fichier compose (`display.project_scope = "auto"`),
  avec la ligne `Project: … (n/N) [press P to show all]` et `P` pour tout voir.

**Critères de réussite**

- Dans un dossier avec un compose, ouvrir Images / Networks / Volumes / Jobs ne montre que ce qui touche ce projet.
- `P` bascule la portée dans toutes les vues à la fois (un seul état partagé) ; le filtre est propre à chaque vue.
- Aucun raccourci existant ne change, sauf `prune` dans Images (`P` → `X`).
- Hors d'un projet compose, rien ne change (portée inactive).

**Hors périmètre** (sous-projet 3, plus tard) : projets multi-fichiers (`config_files`), projet actif explicite, nom de projet
forcé par `-p` ou `COMPOSE_PROJECT_NAME`, ressources hors compose.

## Ce que Docker expose (vérifié)

- Réseaux et volumes nommés créés par compose : label `com.docker.compose.project` (le **nom** du projet, pas son dossier).
- Images construites par compose : même label. Images tirées d'un registre : aucun label.
- Volumes anonymes, `bridge`/`host`/`none` : aucun lien avec un projet.
- `docker images --format` n'expose pas les labels : il faut `docker image inspect`.
- Les conteneurs portent `compose_project` **et** `compose_dir` (déjà utilisés par la portée actuelle).

## Règles d'appartenance

Soit `R` = racine du projet (racine git du cwd global, comme aujourd'hui) et `N` = l'ensemble des **noms de projets dans la
portée** :

- `N` = `compose_project` des conteneurs qui correspondent déjà à `R` (règle actuelle sur `compose_dir`) ∪ le nom du projet
  compose situé à `R` (clé `name:` du fichier, sinon le dossier normalisé comme Docker : minuscules, caractères hors
  `[a-z0-9_-]` retirés). Le second terme fait apparaître les réseaux et volumes d'un projet sans conteneur.

| Vue | Une ligne est dans la portée si |
|---|---|
| Networks, Volumes | son label `com.docker.compose.project` ∈ `N` |
| Images | son label `com.docker.compose.project` ∈ `N`, **ou** un conteneur de la portée l'utilise |
| Jobs | son `cwd` est dans `R` (ou `R` est dans son `cwd`, comme les conteneurs) ; un job sans `cwd` est hors portée |
| Containers | règle actuelle, inchangée |

Les ressources sans lien (volumes anonymes, `bridge`, images sans rapport) sont donc masquées tant que la portée est active.

## Architecture

| Unité | Rôle |
|---|---|
| `dockyard/scope.lua` (nouveau, remplace `ui/views/containers/scope.lua`) | état partagé (`enabled`, `toggle`), racine, noms de projet, règles d'appartenance pures, `ensure_containers` |
| `ui/components/scope_header.lua` (nouveau) | lignes `Project:` et `Filter:` d'une vue, et test de correspondance du filtre |
| `core/docker.lua` | labels des réseaux ; labels des images (un `docker image inspect` pour toutes) |
| vues Images, Networks, Volumes, Jobs | appliquent portée + filtre avant de dessiner, ajoutent les touches |
| `ui/views/containers/scope.lua` | devient un alias de `dockyard/scope.lua` (le picker et la vue Containers ne changent pas) |

### `dockyard/scope.lua`

- `enabled()` / `toggle()` : un seul état partagé (`nil` = suit `display.project_scope`, `"auto"` = un compose existe à `R`).
  Remplace `containers/state.project_scope`.
- `root()`, `matches(container, root)` : inchangés (déplacés).
- `project_name(root)` : `name:` du compose à `R`, sinon dossier normalisé ; `nil` sans compose.
- `project_names(containers)` : l'ensemble `N` ci-dessus.
- `label(labels, key)` : lit `key` dans la chaîne `k=v,k2=v2` des labels Docker.
- `apply_containers`, `apply_networks`, `apply_volumes`, `apply_images(images, containers)`, `apply_jobs(jobs)` : filtrent selon la
  portée (renvoient la liste inchangée si elle est inactive). `apply` reste un alias de `apply_containers`.
- `ensure_containers(cb)` : si la portée est active et que la liste des conteneurs est vide, la charge (silencieusement)
  avant d'appeler `cb` ; sinon appelle `cb` tout de suite. Les vues Images, Networks et Volumes s'en servent avant de dessiner.

### Données

- `list_networks` : ajoute `labels` (`{{json .Labels}}`).
- `list_images` : après `docker images`, un seul `docker image inspect` (ids des images listées) rattache `compose_project` à
  chaque image (id complet `sha256:…` comparé au préfixe de l'id court). Si l'inspection échoue, les images restent sans
  label (la règle « utilisée par un conteneur » continue de marcher).
- `list_volumes` fournit déjà `labels`.

### Interface

Chaque vue garde son `filter` dans son état de vue. `scope_header.lines({ view, scope_on, shown, total, filter, filter_shown,
filter_total })` produit, comme Containers :

```
 Project: ~/code/app  (3/12)  [press P to show all]
 Filter: api  (1/3)  [press C to clear]
```

Touches (configurables, `false` désactive) :

| Vue | Filtre | Effacer | Portée | Changement |
|---|---|---|---|---|
| Images | `F` | `C` | `P` | `images.prune` : `P` → `X` |
| Networks | `F` | `C` | `P` | — |
| Volumes | `F` | `C` | `P` | — |
| Jobs | `F` | `C` | `P` | — |

Champs filtrés : Images (dépôt, tag, id), Networks (nom, driver, id), Volumes (nom, driver), Jobs (titre, statut, dossier,
ligne de commande). Sous-chaîne, insensible à la casse. `P` bascule l'état partagé puis redessine la vue courante ; les autres
vues le reflètent à leur prochain dessin.

### Configuration

Nouvelles actions de touches : `images|networks|volumes|jobs` × `filter|clear_filter|toggle_project_scope`. `keymaps.images.prune`
vaut `"X"` par défaut. `core/keymaps.validate()` inclut ces actions dans les conflits de chaque vue. Aucune nouvelle option hors
touches : `display.project_scope` s'applique à toutes les vues.

## Gestion des erreurs et cas limites

| Cas | Comportement |
|---|---|
| Portée active mais aucune ressource du projet | ligne `Project: … (0/N)` et tableau vide |
| Conteneurs pas encore chargés | `ensure_containers` les charge avant le premier dessin ; sinon seul le nom du compose à `R` compte |
| `docker image inspect` échoue | images sans `compose_project`, règle « utilisée par un conteneur » seule |
| Dossier sans compose | portée inactive, rien ne change |
| Filtre qui ne correspond à rien | tableau vide, ligne `Filter: … (0/N)` |
| Job sans `cwd` | hors portée |

## Tests

Même mini-runner (`make test`), sans nouvelle dépendance.

- `scope_spec` : normalisation du nom de projet, `name:` du compose, `project_names`, appartenance des réseaux / volumes /
  images / jobs avec des chaînes de labels réelles (vues sur ce poste), état partagé, `apply_*` inactif = identité.
- `scope_header_spec` : lignes `Project:` / `Filter:`, correspondance du filtre (casse, plusieurs champs).
- Données : rattachement des labels d'images à partir d'une sortie d'inspect, format réseau.
- Vues : sélection (portée + filtre) testée par des fonctions pures exposées par chaque renderer ; touches et conflits.
- Vérification réelle avec Docker dans la config de l'utilisateur.

## Migration et compatibilité

- `ui/views/containers/scope.lua` reste importable (alias). `containers/state.project_scope` est supprimé au profit de l'état
  partagé ; `containers.toggle_project_scope` garde sa touche.
- Changement visible : `prune` passe sur `X` dans Images (documenté dans CHANGELOG et l'aide).
