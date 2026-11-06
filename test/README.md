# Tests

Vérifications automatiques du script. Elles ne demandent ni Raspberry Pi, ni WireGuard, ni
privilèges, **ni accès réseau** : les commandes dont le code dépend (`upnpc`, `ping`, `ip`,
`iptables`, `dpkg-query`, `apt-config`, `systemctl`, `curl`) sont simulées par de faux
exécutables, et le `PATH` est confiné à ces faux. Elles sont sans danger sur un Pi en
production : `STATE_DIR`, `WG_DIR`, le verrou, le journal et le relevé sont tous redirigés
vers un dossier temporaire.

## Tout lancer

```bash
bash test/run-all.sh
```

Toutes les étapes sont exécutées même si l'une échoue : on veut la liste complète des
problèmes, pas le premier.

| Fichier | Rôle |
|---|---|
| `lint.sh` | les mêmes contrôles que la CI : fins de ligne LF, `bash -n`, `shellcheck -S warning` |
| `helpers.sh` | les petites fonctions pures : adresses, CIDR, ports, noms, échappement JSON |
| `access.sh` | la couche d'accès : lecture, requêtes, validation, écriture avec purge des références mortes |
| `cli-access.sh` | les commandes `group`, `resource`, `access`, les mises à jour, et les codes de retour |
| `engine.sh` | le générateur de plan `access_rules_plan` : les lignes `iptables` produites, texte pour texte |
| `apply.sh` | l'application : bascule A/B, annulation automatique, état lu dans le noyau |
| `json.sh` | la sortie de `wg-pi json`, validée par `python3` et non à l'œil |
| `python.sh` | le Python du panneau, **exécuté** : avertissements, validation des règles, motifs |
| `ui.sh` | le JavaScript du panneau, **exécuté** sous un faux DOM (`lib/dom-stub.js`) |
| `role.sh` | le compte de consultation : ce qu'il voit, ce qui lui est refusé |
| `detect-reachability.sh` | `detect_reachability` : la ligne peut-elle recevoir une connexion entrante ? |
| `firewall.sh` | le pare-feu généré : sa syntaxe, sa structure, et son **exécution** sous commandes simulées |
| `heredoc.sh` | le code embarqué dans le heredoc compile, et aucune fonction n'y est déclarée deux fois |
| `run-all.sh` | enchaîne tout et renvoie un code de sortie non nul si une étape a échoué |

`VERBOSE=1 bash test/detect-reachability.sh` affiche en plus la phrase d'explication rendue à
l'utilisateur pour chaque cas : c'est le moyen le plus rapide de relire les messages en
français sans dérouler toute l'installation.

## Bout en bout, sur un vrai noyau

`e2e.sh` et `e2e-migration.sh` ne sont **pas** lancés par `run-all.sh` : ils installent
réellement, montent une interface `wg0`, posent de vraies règles `iptables` et désinstallent.
Ils demandent un conteneur avec `systemd` et `NET_ADMIN`. Voir [e2e-lancer.md](e2e-lancer.md).

C'est le seul moyen de prouver qu'un jeu de règles est accepté par un noyau — et `e2e.sh` a
déjà attrapé une régression qu'aucun test unitaire ne voyait.

## Depuis Windows

Lancez-les dans un conteneur plutôt qu'en natif : Git Bash masque les retours chariot, ce
qui rend le contrôle des fins de ligne inopérant.

```bash
docker run --rm -v "$PWD:/repo" debian:12-slim bash -c "apt-get -qq update && apt-get -qq install -y shellcheck python3 >/dev/null && bash /repo/test/run-all.sh /repo/wg-pi.sh"
```

## Reproduire l'intégration continue avant de déposer

Les tests passent facilement sur une machine confortable et échouent sur le runner, qui
diffère sur trois points : **Node 22** (et non 18), un utilisateur **non privilégié**, et
**`sshd` installé**. Les trois ont déjà causé des échecs. Pour rejouer la CI à l'identique :

```bash
docker run --rm -v "$PWD:/repo:ro" node:22-bookworm-slim bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends shellcheck python3 iproute2 iptables openssh-server iputils-ping unattended-upgrades >/dev/null && useradd -m runner && mkdir -p /src && cp -r /repo/wg-pi.sh /repo/test /src/ && chown -R runner /src && su runner -c "cd /src && for t in helpers access cli-access engine apply json python ui role detect-reachability firewall heredoc; do bash ./test/\$t.sh >/dev/null 2>&1 && echo \"OK   \$t\" || echo \"ECHEC \$t\"; done"'
```

La liste des étapes est exactement celle de l'étape « Tests unitaires » du workflow ; `lint`
n'y figure pas parce que la CI lance `shellcheck` dans une étape à part.

`iputils-ping` et `unattended-upgrades` sont installés **exprès** : ce sont eux qui ont révélé
des tests qui affirmaient un fait de la machine au lieu de le simuler. Le runner les a, une
image minimale non — et la suite doit passer dans les deux cas.

Règle qui en découle, et qui est maintenant **tenue** : un test ne doit jamais dépendre de ce
qui est installé sur la machine qui l'exécute, ni de l'accès au réseau. Si un test a besoin
qu'une commande soit absente, il confine le `PATH` à ses propres faux exécutables. Retirer un
faux ne « désinstalle » rien : la vraie commande est juste derrière, et le test se met à
mesurer la machine du développeur.

Pour le vérifier :

```bash
docker run --rm --network none -v "$PWD:/repo:ro" debian:12-slim bash -c "apt-get -qq install -y python3 >/dev/null 2>&1; cp -r /repo/wg-pi.sh /repo/test /tmp/ && cd /tmp/test && bash run-all.sh"
```

## Un test doit tomber quand le code casse

Un test vert ne prouve rien par lui-même. La seule preuve est la mutation : casser le code à
un endroit précis, relancer, et vérifier que le test censé l'attraper tombe.

```bash
mkdir -p /tmp/mut && cp -r wg-pi.sh test /tmp/mut/
sed -i 's|  if ! filtering; then|  if true; then|' /tmp/mut/wg-pi.sh
bash /tmp/mut/test/firewall.sh /tmp/mut/wg-pi.sh   # doit sortir en 1
```

Trois pièges déjà payés dans ce dépôt :

- une **fenêtre fixe** (`grep -A8 '^rules()'`) cesse de voir ce qu'elle surveille dès que la
  fonction grossit — et ne le dit pas. On délimite une fonction par ses accolades.
- un **`grep -c` sur un motif trop large** passe pour la mauvaise raison. On nomme le geste
  attendu plutôt que de compter des occurrences.
- une **valeur écrite en dur** (un numéro de génération) se périme en silence. On la lit dans
  le script testé.

## Ajouter un cas à `detect-reachability.sh`

Une ligne suffit, les colonnes sont alignées sur le commentaire d'en-tête du tableau :

```
t "<libellé>" <attendu> <ext UPnP> "<sauts ping>" "<IP publique>" <passerelle> <adresse du Pi>
```

Le verdict attendu est `ok`, `cgnat` ou `unknown`. Une chaîne vide pour `<ext UPnP>` ou
`<sauts ping>` simule une commande **absente du système** — et elle l'est vraiment, le `PATH`
de la sonde étant confiné. Pour une box qui ne répond pas, c'est différent : donnez une table
de sauts sans aucun des TTL sondés, par exemple `"9=1.1.1.1"`.

## Ce qui n'est pas couvert

- Le **rendu visuel** du panneau : le JavaScript est exécuté et ses sorties vérifiées, mais
  rien ne regarde la mise en page, les couleurs ni le thème sombre.
- Les **routes HTTP** du panneau : le Python est exercé fonction par fonction, et `role.sh`
  vérifie le point d'application du rôle, mais aucune requête n'est envoyée à un vrai serveur
  par `run-all.sh`. Un conteneur de bout en bout est nécessaire pour cela.
- Ce qu'un conteneur n'est pas : le comportement réel de l'UPnP et de DuckDNS, la détection
  d'opérateur, la cohabitation avec UFW et Docker **installés sur le Pi**, et les performances
  de chiffrement sur du matériel ARM.
