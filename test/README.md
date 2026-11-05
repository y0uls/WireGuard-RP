# Tests

Vérifications automatiques du script. Elles ne demandent ni Raspberry Pi, ni WireGuard,
ni privilèges : les commandes réseau dont le code dépend (`upnpc`, `ping`, `ip`) sont
simulées par de faux exécutables placés en tête de `PATH`.

## Tout lancer

```bash
bash test/run-all.sh
```

| Fichier | Rôle |
|---|---|
| `lint.sh` | les mêmes contrôles que la CI : fins de ligne LF, `bash -n`, `shellcheck -S warning` |
| `detect-reachability.sh` | tests unitaires de `detect_reachability` : la ligne peut-elle recevoir une connexion entrante ? |
| `run-all.sh` | enchaîne les deux et renvoie un code de sortie non nul au premier échec |

`VERBOSE=1 bash test/detect-reachability.sh` affiche en plus la phrase d'explication rendue à
l'utilisateur pour chaque cas : c'est le moyen le plus rapide de relire les messages en
français sans dérouler toute l'installation.

## Depuis Windows

Lancez-les dans un conteneur plutôt qu'en natif : Git Bash masque les retours chariot, ce
qui rend le contrôle des fins de ligne inopérant.

```bash
docker run --rm -v "$PWD:/repo" debian:12-slim bash -c "apt-get -qq update && apt-get -qq install -y shellcheck >/dev/null && bash /repo/test/run-all.sh /repo/wg-pi.sh"
```

## Reproduire l'intégration continue avant de déposer

Les tests passent facilement sur une machine confortable et échouent sur le runner, qui
diffère sur trois points : **Node 22** (et non 18), un utilisateur **non privilégié**, et
**`sshd` installé**. Les trois ont déjà causé des échecs. Pour rejouer la CI à l'identique :

```bash
docker run --rm -v "$PWD:/repo:ro" node:22-bookworm-slim bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq update >/dev/null && apt-get -qq install -y --no-install-recommends shellcheck python3 iproute2 openssh-server >/dev/null && useradd -m runner && mkdir -p /src && cp -r /repo/wg-pi.sh /repo/test /src/ && chown -R runner /src && su runner -c "cd /src && for t in helpers access cli-access engine apply json ui role detect-reachability firewall heredoc; do bash ./test/\$t.sh >/dev/null 2>&1 && echo \"OK   \$t\" || echo \"ECHEC \$t\"; done"'
```

Règle qui en découle : **un test ne doit jamais dépendre de ce qui est installé sur la
machine qui l'exécute.** Si un test a besoin qu'une commande soit absente, il doit
neutraliser la fonction qui l'appelle, pas espérer que la machine soit nue.

## Ajouter un cas à `detect-reachability.sh`

Une ligne suffit, les colonnes sont alignées sur le commentaire d'en-tête du tableau :

```
t "<libellé>" <attendu> <ext UPnP> "<sauts ping>" "<IP publique>" <passerelle> <adresse du Pi>
```

Le verdict attendu est `ok`, `cgnat` ou `unknown`. Une chaîne vide pour `<ext UPnP>` ou
`<sauts ping>` simule une commande **absente du système**, et non une commande muette :
pour une box qui ne répond pas, donnez une table de sauts sans aucun des TTL sondés,
par exemple `"9=1.1.1.1"`.

## Ce qui n'est pas couvert

- Les ~1 365 lignes de Python et de JavaScript de l'interface web : aucun test, et la CI
  ne les analyse pas non plus.
- L'installation de bout en bout (systemd, `wg-quick`, iptables) : demande un conteneur
  privilégié, avec `--cap-add NET_ADMIN`.
