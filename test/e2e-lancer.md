# Lancer les tests de bout en bout

Les tests de `test/run-all.sh` ne demandent aucun privilège : ils vérifient la logique.
Les deux tests ci-dessous vont plus loin — ils **installent réellement**, montent une
interface `wg0`, posent de vraies règles `iptables`, activent le filtrage et désinstallent.
C'est le seul moyen de prouver que les règles sont acceptées par un noyau.

Ils demandent donc un conteneur avec `systemd`, `NET_ADMIN`, et un noyau hôte qui sait
créer une interface WireGuard.

## L'image

```bash
docker build -t wgpi-e2e - <<'EOF'
FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus iproute2 iptables ca-certificates curl procps \
      openssh-server python3 iputils-ping netcat-openbsd && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /lib/systemd/system/multi-user.target.wants/* \
          /etc/systemd/system/*.wants/* \
          /lib/systemd/system/local-fs.target.wants/* \
          /lib/systemd/system/sockets.target.wants/*udev* \
          /lib/systemd/system/basic.target.wants/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
```

## Installation complète, filtrage, désinstallation

```bash
docker run -d --name wgpi-e2e-run --privileged --cgroupns=host --cap-add NET_ADMIN --tmpfs /run --tmpfs /run/lock -v "$PWD:/repo:ro" wgpi-e2e /sbin/init
```

Puis, une fois systemd démarré (quelques secondes) :

```bash
docker exec wgpi-e2e-run bash -c 'tr -d "\r" < /repo/test/e2e.sh > /root/e2e.sh && bash /root/e2e.sh /repo/wg-pi.sh'
```

## Migration depuis une version antérieure

`e2e.sh` se termine par une **restauration**, donc il laisse wg-pi installé. Or
`e2e-migration.sh` commence par installer la version publiée, ce que `cmd_install` refuse
sur un système déjà installé (« wg-pi est déjà installé »). Si vous venez d'enchaîner le
test précédent dans le même conteneur, repartez donc d'un système vierge :

```bash
docker exec wgpi-e2e-run bash -c 'command -v wg-pi >/dev/null && wg-pi uninstall --yes || true'
```

Exportez ensuite la version publiée, puis lancez le test avec les deux fichiers :

```bash
git show HEAD:wg-pi.sh > /tmp/publie.sh
```

```bash
docker cp /tmp/publie.sh wgpi-e2e-run:/root/publie.sh && docker exec wgpi-e2e-run bash -c 'tr -d "\r" < /repo/test/e2e-migration.sh > /root/m.sh && tr -d "\r" < /repo/wg-pi.sh > /root/nouvelle.sh && bash /root/m.sh /root/publie.sh /root/nouvelle.sh'
```

## Nettoyage

```bash
docker rm -f wgpi-e2e-run
```

## Ce que ces tests ne couvrent pas

Un conteneur n'est pas un Raspberry Pi derrière une box. Restent non vérifiés : le
comportement réel de l'UPnP et de DuckDNS, la détection d'opérateur, la cohabitation avec
Docker et UFW **installés sur le Pi** (ici le pare-feu est vierge), et les performances de
chiffrement sur du matériel ARM.
