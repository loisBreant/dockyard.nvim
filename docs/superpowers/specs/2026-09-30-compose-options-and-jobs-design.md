# Options compose et vue Jobs — design

Date : 2026-09-30 · Statut : validé d'avance par l'utilisateur · Sous-projets 1 et 2 sur 5

## Contexte et objectif

Le fork ajoute des boutons compose (`▶ Run`, `■ Stop`, `⟳ Build`, `▼ Down`…), mais :

1. Les commandes sont figées : `builder.run_cmd` lance toujours `up -d --force-recreate`, `compose_lens` n'ajoute que
   `-f <fichier>`. Pas de `--profile`, pas de `--build`, pas de `down -v`.
2. La sortie des commandes disparaît : `executor.lua` affiche un flottant de 5 lignes et le ferme après 3 s, succès ou
   échec. Rien n'est conservé.

**Objectif** : on peut choisir profils et flags compose (menu, défauts mémorisés par projet), et chaque commande lancée
reste consultable en entier, rejouable et annulable dans une vue « Jobs » du dashboard.

**Critères de réussite**

- Lancer un service à profil, ou avec `--build`, ou faire `down -v` est possible sans quitter Neovim.
- Après n'importe quelle commande (réussie ou non), on retrouve la commande exacte et sa sortie complète.
- `▶ Run` reste un clic ; le comportement actuel est inchangé tant qu'on ne touche à rien.
- Aucun changement destructif silencieux : `-v` n'est jamais mémorisé et demande confirmation.

**Hors périmètre** (specs suivantes) : matching de projet (3), nouvelles fonctions comme `watch`/`exec`/`prune` (4),
refonte visuelle (5), flags de `docker build` pour les Dockerfile.

## Décisions déjà prises avec l'utilisateur

- Options : menu à cases, défauts mémorisés par projet ; le bouton rapide garde son comportement.
- Sortie : vue « Jobs » dans le dashboard (liste, détail complet, rejeu) ; le flottant reste mais ne se ferme plus sur
  erreur.
- Architecture retenue : constructeur de commandes pur + registre de jobs + préférences par projet.

## Architecture

Quatre unités, chacune testable seule.

| Unité | Rôle | Dépend de |
|---|---|---|
| `commands/compose.lua` | argv exact à partir de projet + action + options (pur) | rien |
| `commands/prefs.lua` | préférences persistantes par projet | `stdpath("data")` |
| `commands/runner.lua` | lance les commandes, tient le registre des jobs | `vim.system` |
| UI : vue Jobs, buffer de sortie, menu, flottant | affichage, sans logique de commande | les trois ci-dessus |

`commands/executor.lua` reste la façade publique `executor.run(args, opts)` : elle crée un job via `runner` et branche le
flottant. Les appelants actuels (`compose_lens`, `commands/init`, `dockerfile_lens`) ne changent que pour construire leur
argv avec `compose.build`.

### 1. `commands/compose.lua`

```lua
compose.build(project, action, opts) --> argv|nil, err|nil
```

- `project` : `{ files = string[], dir = string, name? = string, env_file? = string }`. Le multi-fichiers et `-p` sont
  gérés dès maintenant (le sous-projet 3 les alimentera) ; le résolveur actuel passe un seul fichier.
- `action` : `up | down | stop | restart | build | pull`.
- `opts` : `profiles: string[]`, `all_profiles: boolean`, `services: string[]`, et les drapeaux
  `build, force_recreate, no_deps, wait, remove_orphans, renew_anon_volumes` (booléens) et
  `pull` (`false|"always"|"missing"|"never"`) pour `up` ; `volumes` (booléen), `rmi` (`false|"local"|"all"`),
  `remove_orphans` pour `down`. `false` = drapeau absent de la commande. Dans le menu, `pull` bascule entre `false` et
  `"always"`, `rmi` entre `false` et `"local"`.
- Forme : `docker compose [-f f]… [-p n] [--env-file e] [--profile p]… <verbe> [flags du verbe] [services]`.
  `docker-compose` est utilisé seulement si le binaire `docker` est absent (comportement actuel).
- `up` ajoute toujours `-d`. `--force-recreate` reste actif par défaut pour ne rien changer, mais devient décochable.
- **Profils et `down`/`stop`** : `down` ignore les services à profil non activés ; les profils actifs du projet sont donc
  passés aussi à `down`, `stop`, `restart`, sinon des conteneurs resteraient orphelins.
- `all_profiles` produit `--profile '*'`.
- Un drapeau incompatible avec l'action est ignoré (ex. `volumes` sur `up`), pas une erreur.

**Détection des profils** : `docker compose -f <file> config --profiles` (asynchrone, résultat en cache par fichier et
mtime, invalidé à l'écriture du buffer). Si la commande échoue (variable `${X:?}` manquante, par exemple), repli
best-effort : balayage des listes `profiles:` du buffer (forme `[a, b]` et forme `- a`). L'échec de la commande est
signalé une fois, discrètement.

`context.compose_services` retient aussi les profils de chaque service, pour afficher un chip `[debug]` à côté du
service dans les lignes lens.

### 2. `commands/prefs.lua`

- Fichier : `stdpath("data") .. "/dockyard/projects.json"`, `{ version = 1, projects = { [clé] = prefs } }`.
- Clé : chemin réel (`fs_realpath`) du fichier compose principal.
- Contenu mémorisé : `profiles`, `all_profiles`, et les drapeaux `build, pull, force_recreate, no_deps, wait,
  remove_orphans`.
- **Jamais mémorisés** (repartent à zéro à chaque ouverture du menu) : `volumes`, `rmi`, `renew_anon_volumes`.
- Lecture paresseuse ; écriture atomique (fichier temporaire puis `rename`).
- Fichier illisible ou d'une version inconnue : copié en `projects.json.bak`, on repart de zéro, un avertissement est
  affiché. Jamais d'erreur bloquante.
- Valeurs par défaut : `require("dockyard.config").options.compose.defaults`, fusionnées sous les préférences du projet.

### 3. `commands/runner.lua` (registre de jobs)

```lua
---@class DockyardJob
---@field id integer
---@field title string        -- "compose up api"
---@field argv string[]       -- commande exacte
---@field cwd string
---@field status "running"|"ok"|"failed"|"cancelled"
---@field code integer|nil
---@field started_at integer  -- vim.uv.hrtime()
---@field ended_at integer|nil
---@field lines string[]      -- sortie, stdout et stderr entrelacés
---@field project string|nil  -- clé de préférences, pour info
```

API : `start(spec)`, `list()`, `get(id)`, `cancel(id)`, `rerun(id)`, `clear_finished()`, `subscribe(fn)`.
Chaque changement émet aussi `User DockyardJobChanged` (data = id) pour les intégrations utilisateur.

- Les chunks sont recollés en lignes complètes (une ligne coupée entre deux chunks n'est pas dupliquée) ; les séquences
  ANSI sont retirées.
- Historique borné (`jobs.history`, 50 par défaut) : les jobs terminés les plus anciens sont évincés, jamais un job en
  cours. Si une sortie dépasse 5000 lignes, les plus anciennes sont abandonnées et remplacées par une ligne « … N lignes omises ».
- L'historique est en mémoire seulement (pas de persistance entre sessions : YAGNI).
- `cancel` envoie SIGTERM (`job:kill`) ; statut `cancelled`. À `VimLeavePre`, les jobs en cours sont tués.
- Échec de lancement (binaire absent…) : job `failed` avec la raison en première ligne de sortie. Pas de `pcall`
  silencieux.

### 4. Interface

**Flottant** (`ui/popups/job_notice.lua`, logique extraite d'`executor.lua`) :
première ligne = commande exacte (`$ docker compose … up -d --build`), puis les 5 dernières lignes de sortie. Succès :
fermeture après `jobs.notice.close_after` (3000 ms, comme aujourd'hui). **Échec : il reste** jusqu'à `q`. `<CR>` ouvre le
détail complet.

**Vue « Jobs »** (`ui/views/jobs/{init,controller,renderer,keymaps,state}.lua`, même patron que `volumes`) : ajoutée à
`view_modules` et à `display.views` par défaut (en dernier). Colonnes : statut (icône colorée), heure de début, durée,
titre, dossier. Tri du plus récent au plus ancien. Rafraîchie via `runner.subscribe` (regroupement à 100 ms, seulement si
la vue est active). Touches (`keymaps.jobs`) : `<CR>` détail, `r` rejouer, `x` annuler, `D` effacer les terminés,
`y` copier la commande.

**Buffer de détail** : buffer `dockyard-job://<id>` (nom distinct de `dockyard://`, réservé aux fichiers de conteneur ; `buftype=nofile`, `filetype=dockyardjob`), ouvert en split. En-tête
`$ commande` et pied `✔/✖ exit N · durée`. Ajout en direct pendant l'exécution ; défilement automatique tant que le
curseur est sur la dernière ligne. `q` ferme, `r` rejoue, `x` annule.

**Lens compose** : la ligne `services:` gagne un bouton `⚙ Options` avec un chip résumé des réglages actifs
(`debug · +build`). `▶ Run all`, `▶ Run`, `■ Stop`, `↻ Restart`, `⟳ Build`, `▼ Down` construisent leur commande via
`compose.build` avec les préférences du projet.

**Menu** (`ui/popups/compose_menu/{model,init}.lua`), ouvert par le bouton `⚙ Options`, `:Dockyard compose [action]` ou
`<Plug>(dockyard-compose)` :

```
 Compose · docker-compose.yml

 Profiles
   [x] debug
   [ ] tools
   [ ] all profiles (*)

 Saved for this project
   [x] --force-recreate
   [ ] --build
   [ ] --pull always
   [ ] --no-deps
   [ ] --wait
   [ ] --remove-orphans

 This run only
   [ ] -v  remove volumes (down)
   [ ] --rmi local  remove images (down)
   [ ] -V  renew anonymous volumes (up)

 $ docker compose -f docker-compose.yml --profile debug up -d --force-recreate
 <CR> up · d down · b build · p pull · s stop · r restart · <Space> toggle · q close
```

- Le modèle (état → lignes, bascule d'une case, aperçu de la commande) est une fonction pure, testée ; la fenêtre ne fait
  que l'afficher.
- Les cases « Saved for this project » sont écrites dans `prefs` à chaque changement ; les cases « This run only » ne le sont pas.
- Un `down` contenant `-v` ou `--rmi` demande confirmation (`vim.ui.select` Oui/Non, Non par défaut) en nommant le
  projet.
- L'aperçu est la commande réellement lancée (même appel à `compose.build`).

**Commandes** : `:Dockyard compose [action]`, `:Dockyard jobs` (ouvre le dashboard sur la vue Jobs), `:Dockyard job
[id|last]`, `:Dockyard rerun`. Complétion pour chaque sous-commande. `<Plug>(dockyard-compose)`,
`<Plug>(dockyard-jobs)`, `<Plug>(dockyard-job-last)`. Les alias `:DockyardRun`/`:DockyardBuild` continuent de marcher.

### 5. Configuration

```lua
jobs = { history = 50, notice = { close_after = 3000 } },
compose = { defaults = { force_recreate = true, build = false, pull = false,
                         no_deps = false, wait = false, remove_orphans = false } },
keymaps = { jobs = { open_output = "<CR>", rerun = "r", cancel = "x", clear = "D", copy_command = "y" } },
```

Ajouts à `config.validate` et `unknown_keys`, au README, à `doc/dockyard.txt`, à `:checkhealth` (présence de
`docker compose`, lisibilité du fichier de préférences).

## Gestion des erreurs

| Cas | Comportement |
|---|---|
| `docker`/`docker-compose` introuvable | job `failed`, raison en sortie, flottant persistant |
| commande non nulle | job `failed`, sortie complète conservée, flottant persistant |
| `config --profiles` échoue | repli sur balayage du buffer, message unique |
| préférences corrompues | `.bak`, défauts, avertissement |
| fichier compose modifié non sauvé | sauvegardé avant l'exécution (comportement actuel) |
| annulation | job `cancelled`, SIGTERM |

## Tests

Même runner que l'existant (`make test` = `tests/run.lua`, pas de nouvelle dépendance) ; `make typecheck` doit rester
propre.

- `compose_spec` : tableau de cas (ordre des arguments, profils y compris sur `down`/`stop`, `*`, flags par verbe,
  multi-fichiers, `-p`, `--env-file`, services, flag ignoré, `docker-compose` de repli).
- `prefs_spec` : aller-retour dans un dossier temporaire, flags mémorisés vs éphémères, fichier corrompu, version
  inconnue, écriture atomique.
- `runner_spec` : vraies commandes courtes (`sh -c 'echo a; echo b >&2; exit 3'`) : statuts, recollage des lignes
  coupées, ANSI, éviction, troncature, annulation, rejeu, abonnements.
- `jobs_view_spec` et `compose_menu_spec` : fonctions pures de rendu et de bascule.
- Détection des profils : parseur du repli sur des fixtures (`tests/fixtures/`).
- Vérification manuelle avec Docker réel (fixture avec profils) : service à profil, `up --build`, `down -v` avec
  confirmation, échec volontaire (flottant persistant), rejeu, annulation d'un `build` long.

## Migration et compatibilité

- `builder.run_cmd`/`run_all_cmd` et `compose_lens.compose_cmd` disparaissent au profit de `compose.build` ;
  `builder.build_cmd`/`image_tag` (Dockerfile) restent.
- Aucune option existante ne change de sens. Seul ajout visible sans configuration : la vue « Jobs » (en dernier dans
  `display.views`) et le bouton `⚙ Options`.
- Version cible : 0.5.0 (entrée CHANGELOG, README, aide).

## Suite prévue

3. Matching de projet : partir des labels `com.docker.compose.project.config_files` / `project` (déjà exposés par
   `docker compose ls`, y compris les projets multi-fichiers) plutôt que du seul `working_dir`, projet actif explicite,
   conteneurs hors compose.
4. Fonctions utiles : `watch`, `exec`, `run --rm`, `pull`, prune, aperçu de `config`, ouverture du `.env`.
5. Interface : uniformisation et finitions.

## Points à vérifier à l'implémentation

- `<CR>` est aussi la touche globale `toggle_node` : vérifier la précédence dans `core/keymaps` pour la vue Jobs, sinon
  utiliser `K`.
- Le plugin est chargé depuis GitHub par la config actuelle (`~/dockyard.nvim` n'existe pas) : pour tester ce clone, il
  faudra pointer `dir` de `lua/plugins/init.lua` vers lui.
