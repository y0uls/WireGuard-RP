<div align="center">

# WireGuard-RP

**Votre VPN WireGuard à la maison, sur Raspberry Pi, avec une installation entièrement guidée.**

Un seul script en français : il installe tout, crée les QR codes de vos appareils
et vous accompagne jusqu'à l'ouverture du port sur votre box.

[![ShellCheck](https://github.com/y0uls/WireGuard-RP/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/y0uls/WireGuard-RP/actions/workflows/shellcheck.yml)
![Raspberry Pi OS | Debian](https://img.shields.io/badge/Raspberry%20Pi%20OS%20%7C%20Debian-11%20%C3%A0%2013-A22846?logo=raspberrypi&logoColor=white)
![WireGuard](https://img.shields.io/badge/VPN-WireGuard-88171A?logo=wireguard&logoColor=white)
![Bash](https://img.shields.io/badge/script-bash-4EAA25?logo=gnubash&logoColor=white)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

```bash
curl -fsSL https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash
```

</div>

---

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Aperçu](#aperçu)
- [Utilisation](#utilisation)
- [Connecter un appareil](#connecter-un-appareil)
- [Mise à jour](#mise-à-jour)
- [Sauvegarde et restauration](#sauvegarde-et-restauration)
- [Désinstallation](#désinstallation)
- [Dépannage](#dépannage)
- [Comment ça marche](#comment-ça-marche)
- [Pourquoi ce projet](#pourquoi-ce-projet)
- [Contribuer](#contribuer)
- [Licence](#licence)

## Fonctionnalités

- **Installation guidée en 7 étapes**, entièrement en français. Entrée accepte la réponse proposée.
- **Détection automatique** du réseau (adresse du Pi, box, adresse MAC), de l'IP publique et de
  l'opérateur (Orange, Free, SFR, Bouygues) pour adapter les conseils.
- **IP fixe du Pi** : explique comment la réserver dans la box, ou la fixe directement via NetworkManager.
- **DuckDNS intégré** (gratuit) si votre IP publique change : le nom est mis à jour toutes les 5 minutes.
- **Ouverture automatique du port via UPnP**, vérifiée toutes les 30 minutes. Si la box refuse, le
  script affiche le chemin des menus de *votre* box (Freebox, Livebox, box SFR, Bbox) avec les
  valeurs exactes à saisir.
- **QR code** pour chaque appareil, plus un fichier `.conf` et une image `.png` prêts à copier sur un PC.
- **Test en direct** : après l'installation, le script attend que votre téléphone se connecte et
  confirme que tout fonctionne.
- **Deux modes par appareil** : tout le trafic passe par la maison, ou seulement l'accès au réseau
  local (NAS, Home Assistant…).
- **DNS au choix** : box, Cloudflare, Quad9, ou Pi-hole / AdGuard Home s'il est détecté sur le Pi.
- **Commande `wg-pi`** pour gérer les appareils, faire un diagnostic complet, sauvegarder,
  restaurer et se mettre à jour.
- **Réglages sûrs par défaut** : clé pré-partagée par appareil, IPv6 sans fuite, compatibilité
  Docker et UFW, mises à jour de sécurité automatiques en option.

## Prérequis

- Un Raspberry Pi sous **Raspberry Pi OS** ou **Debian 11, 12 ou 13** (les dérivés de Debian
  comme Ubuntu devraient fonctionner, sans garantie).
- Un accès SSH (ou un écran et un clavier) avec un compte qui peut utiliser `sudo`.
- Le Pi branché à la box, de préférence **en Ethernet**.
- L'accès à l'interface d'administration de la box.
- Une **IPv4 publique** : pas de CGNAT (voir [Dépannage](#dépannage)).

## Installation

Sur le Raspberry Pi, une seule commande :

```bash
curl -fsSL https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash
```

Ou, si vous préférez lire le script avant de le lancer :

```bash
curl -O https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh
chmod +x wg-pi.sh
sudo ./wg-pi.sh
```

<details>
<summary>Pas de <code>curl</code> (Debian minimale) ? Avec <code>wget</code></summary>

En une ligne :

```bash
wget -qO- https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash
```

Ou en téléchargeant d'abord le script :

```bash
wget -O wg-pi.sh https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh
chmod +x wg-pi.sh
sudo ./wg-pi.sh
```

</details>

L'assistant se déroule en 7 étapes :

| Étape | Ce qui se passe |
|:-:|---|
| 1 | Vérification du système et installation des paquets (`wireguard-tools`, `qrencode`, `iptables`…) |
| 2 | Détection du réseau local et choix pour garder une IP fixe au Pi |
| 3 | Adresse publique : IP, nom DuckDNS ou votre propre nom de domaine |
| 4 | Réglages du VPN : DNS, mode de routage, port, UPnP, mises à jour automatiques, puis récapitulatif |
| 5 | Génération des clés, configuration, pare-feu, démarrage du service |
| 6 | Ouverture du port sur la box (automatique ou guidée) |
| 7 | Création du premier appareil, QR code et test de connexion en direct |

**Ce qu'il vous reste à faire :**

1. Ouvrir le port UDP sur la box, si l'UPnP n'a pas fonctionné. Le script vous dit où cliquer.
2. Réserver l'adresse du Pi dans la box. Le script vous donne l'adresse MAC.
3. Installer l'application **WireGuard** sur le téléphone, scanner le QR code, **couper le Wi-Fi**
   et activer le tunnel.

<details>
<summary>Installation sans aucune question</summary>

Toutes les réponses par défaut sont acceptées. L'adresse publique est votre IP actuelle, sauf si
vous en précisez une avec `--endpoint`. DuckDNS ne peut pas être configuré dans ce mode.

```bash
curl -fsSL https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash -s -- install --yes --client telephone
```

| Option | Rôle |
|---|---|
| `--yes` | accepter toutes les réponses par défaut |
| `--endpoint <adresse>` | IP publique ou nom de domaine utilisé par les appareils |
| `--port <port>` | port UDP du VPN (par défaut `51820`) |
| `--client <nom>` | nom du premier appareil (par défaut `telephone`) |

</details>

## Aperçu

Exemple avec une Livebox (extraits) :

```text
━━━━ Étape 3/7 — Comment vos appareils trouveront votre maison ━━━━

➜ Recherche de votre adresse IP publique…
   IP publique            86.xxx.xxx.xxx
   Opérateur              Orange / Sosh

Chez Orange, l'IP publique change de temps en temps (redémarrage de la Livebox…).
→ Un nom gratuit DuckDNS évite que le VPN tombe en panne ce jour-là.

? Quelle adresse vos appareils doivent-ils utiliser pour joindre la maison ?
    1) Mon IP publique (86.xxx.xxx.xxx)
    2) Un nom gratuit DuckDNS (xxx.duckdns.org) mis à jour automatiquement — je vous guide
    3) J'ai déjà un nom de domaine / DynDNS (xxxx.freeboxos.fr, No-IP…)
?   Votre choix [2]
```

```text
━━━━ Étape 6/7 — Ouvrir le port sur votre box ━━━━

Connectez-vous à votre Livebox depuis un appareil de la maison :
   http://192.168.1.1 (identifiant « admin », mot de passe sur l'étiquette de la box)

① Ouvrir le port du VPN — Paramètres avancés › Réseau › NAT/PAT (règle personnalisée)
   Nom / application      WireGuard
   Protocole              UDP (pas TCP)
   Port externe           51820
   Port interne           51820
   Appareil / IP          192.168.1.50 (raspberrypi)

② Réserver l'adresse du Pi — Paramètres avancés › Réseau › DHCP › Baux DHCP statiques
   Appareil (adresse MAC) dc:a6:32:xx:xx:xx (raspberrypi)
   Adresse IP             192.168.1.50
```

```text
$ sudo wg-pi list

  Serveur : ● actif — chezmoi-vpn.duckdns.org:51820 — réseau 10.8.0.0/24

  APPAREIL         IP VPN        REÇU      ENVOYÉ     DERNIÈRE CONNEXION
  telephone        10.8.0.2      2.2Mo     18Mo       ● connecté (37.xxx.xxx.xxx:51023)
  pc-portable      10.8.0.3      0o        0o         jamais

➜ 2 appareil(s), dont 1 connecté(s) en ce moment.
```

## Utilisation

Une fois l'installation terminée, tout se gère avec la commande `wg-pi` :

| Commande | Rôle |
|---|---|
| `sudo wg-pi` | menu interactif |
| `sudo wg-pi add [nom] [--split\|--full]` | ajouter un appareil et afficher son QR code |
| `sudo wg-pi remove [nom]` | supprimer un appareil |
| `sudo wg-pi list` | appareils, trafic et état des connexions |
| `sudo wg-pi qr [nom]` | réafficher le QR code d'un appareil |
| `sudo wg-pi check` | diagnostic complet |
| `sudo wg-pi box` | rappel de la configuration de la box |
| `sudo wg-pi endpoint [adresse]` | changer l'adresse publique : sans adresse, menu (IP, DuckDNS, nom de domaine) ; avec une adresse, IP ou nom fixe |
| `sudo wg-pi backup` | sauvegarder la configuration, clés comprises |
| `sudo wg-pi restore <fichier>` | restaurer une sauvegarde |
| `sudo wg-pi update` | mettre à jour wg-pi depuis ce dépôt |
| `sudo wg-pi uninstall` | tout désinstaller |
| `sudo wg-pi help` | aide complète |

Sans nom, `remove` et `qr` vous proposent la liste des appareils, et `add` vous demande le nom.
Un nom fait de 1 à 15 caractères parmi lettres, chiffres, `-` et `_`.

Sans option, un nouvel appareil utilise le mode choisi à l'installation.

```bash
sudo wg-pi add tablette           # mode choisi à l'installation
sudo wg-pi add pc-portable --full # tout le trafic passe par la maison
sudo wg-pi add nas-acces --split  # seulement l'accès au réseau de la maison
```

`--yes` confirme automatiquement `remove` et `uninstall`, ce qui est pratique dans un script.

## Connecter un appareil

**Téléphone ou tablette** : installez l'application WireGuard
([Android](https://play.google.com/store/apps/details?id=com.wireguard.android) /
[iOS](https://apps.apple.com/app/wireguard/id1441195209)), puis **+** › **Scanner un code QR**.

**Ordinateur** : la configuration est copiée dans `~/wireguard-clients/` sur le Pi. Récupérez-la
en tapant la commande **sur l'ordinateur**, pas sur le Pi. Le script l'affiche avec votre
utilisateur et l'adresse du Pi.

Windows (PowerShell), le fichier arrive dans Téléchargements :

```bash
scp utilisateur@192.168.1.50:wireguard-clients/pc-portable.conf $HOME\Downloads\
```

Mac / Linux, le fichier arrive dans le dossier personnel :

```bash
scp utilisateur@192.168.1.50:wireguard-clients/pc-portable.conf ~/
```

La première fois, répondez `yes` (en entier) à la question sur l'empreinte du Pi, puis tapez le
mot de passe de votre utilisateur sur le Pi. Importez ensuite le fichier dans l'application
[WireGuard](https://www.wireguard.com/install/) avec **Importer un tunnel depuis un fichier**, et
supprimez-le de l'ordinateur une fois importé : il contient la clé privée de l'appareil.

> [!IMPORTANT]
> Pour tester, utilisez la **4G/5G** et non le Wi-Fi de la maison : beaucoup de box ne savent pas
> renvoyer vers elles-mêmes une connexion qui part de chez vous.

## Mise à jour

```bash
sudo wg-pi update
```

La dernière version est téléchargée depuis ce dépôt et vérifiée avant de remplacer la commande.
Vos réglages et vos appareils ne changent pas.

## Sauvegarde et restauration

Les cartes SD finissent par s'user : faites une sauvegarde de temps en temps.

```bash
sudo wg-pi backup
```

Le fichier `wg-pi-sauvegarde-AAAAMMJJ-HHMMSS.tar.gz` est créé dans votre dossier personnel, et le
script affiche la commande `scp` pour le copier sur votre ordinateur. Faites-le : une sauvegarde
restée sur la carte SD disparaît avec elle. Elle contient les clés du VPN, gardez-la en lieu sûr.

Pour tout retrouver sur un Pi neuf, copiez-y la sauvegarde puis lancez, depuis le dossier où elle
se trouve :

```bash
curl -fsSL https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash -s -- restore wg-pi-sauvegarde-AAAAMMJJ-HHMMSS.tar.gz
```

Vos appareils se reconnectent sans rien changer. Si l'adresse du Pi a changé, le script vous
prévient qu'il faut mettre à jour la redirection de port.

## Désinstallation

```bash
sudo wg-pi uninstall
```

Le script propose une sauvegarde, puis supprime le service, la configuration (copies de
`~/wireguard-clients` comprises) et les tâches DuckDNS/UPnP. Il retire aussi la redirection UPnP
et la règle UFW si elles existent.

Restent en place : les paquets installés, les mises à jour de sécurité automatiques et l'IP fixe
du Pi si vous l'aviez fixée via NetworkManager. Pensez à supprimer la redirection de port sur la
box si vous l'aviez faite à la main.

## Dépannage

Commencez toujours par :

```bash
sudo wg-pi check
```

Le diagnostic vérifie le service, le port, le routage, le NAT, l'adresse du Pi, l'IP publique,
DuckDNS, UPnP et UFW. Si tout est vert et que ça ne marche pas, c'est presque toujours la
**redirection de port sur la box** : protocole UDP, bon port, bonne IP du Pi.

<details>
<summary><b>Le téléphone ne se connecte pas</b></summary>

- Testez en **4G/5G**, Wi-Fi coupé.
- Vérifiez la redirection sur la box : **UDP** (pas TCP), port `51820` (ou celui choisi), vers l'IP du Pi.
- Vérifiez que l'adresse publique est à jour : `sudo wg-pi check` compare l'adresse utilisée par
  les appareils à votre IP publique actuelle.

</details>

<details>
<summary><b>Free : la redirection ne marche pas</b></summary>

Sur les lignes Free récentes, l'IPv4 peut être **partagée** : seule une plage de ports est alors
redirigeable. Demandez l'« IP fixe V4 full-stack » (gratuite) dans votre espace abonné, puis
redémarrez la Freebox.

</details>

<details>
<summary><b>Box 4G/5G, Starlink… (CGNAT)</b></summary>

L'opérateur partage la même IP publique entre plusieurs clients : aucune redirection de port n'est
possible. Il faut lui demander une IPv4 publique. Le script détecte ce cas quand la box répond en UPnP.

</details>

<details>
<summary><b>Mon IP publique a changé</b></summary>

```bash
sudo wg-pi endpoint
```

Choisissez la nouvelle adresse, idéalement un nom DuckDNS pour ne plus y penser, puis réimportez
les QR codes sur les appareils (`sudo wg-pi qr <nom>`).

</details>

<details>
<summary><b>L'adresse du Pi a changé</b></summary>

`sudo wg-pi check` le signale. Lancez `sudo wg-pi box` : il enregistre la nouvelle adresse et
affiche la redirection à corriger sur la box. Réservez ensuite l'adresse du Pi dans le DHCP de la
box pour que ça ne se reproduise pas.

</details>

<details>
<summary><b>Je n'accède pas à certains appareils là où je me trouve</b></summary>

En France, beaucoup de box utilisent la même plage `192.168.1.x`. En mode `--split`, si le réseau
où vous êtes utilise la même plage que chez vous, ses appareils peuvent devenir injoignables tant
que le VPN est actif. C'est une limite commune à tous les VPN.

</details>

<details>
<summary><b>Journaux</b></summary>

- Installation : `/var/log/wg-pi.log`
- Service WireGuard : `journalctl -u wg-quick@wg0`
- État brut : `sudo wg show`

</details>

## Comment ça marche

| Élément | Choix |
|---|---|
| VPN | WireGuard du noyau, service `wg-quick@wg0` démarré automatiquement |
| Clés | Curve25519, plus une **clé pré-partagée** par appareil |
| Réseau du VPN | `10.8.0.0/24` par défaut (une autre plage si celle-ci est déjà utilisée), jusqu'à 253 appareils |
| IPv6 | réseau privé aléatoire (ULA) dans le tunnel, relayé vers Internet si le Pi a une IPv6 publique ; `::/0` toujours routé en mode « tout le trafic » pour éviter les fuites |
| Pare-feu / NAT | règles `iptables` insérées en tête de chaîne par `PostUp`/`PostDown`, compatibles Docker et UFW |
| Ajout / suppression | à chaud (`wg syncconf`), sans couper les autres appareils |
| Appareils | `PersistentKeepalive = 25` pour garder la connexion à travers les NAT des réseaux mobiles |
| Mises à jour | `unattended-upgrades` en option, dépôts Raspberry Pi OS inclus |
| Sécurité des fichiers | clés et token DuckDNS en `600` (lisibles par root seulement) |

Fichiers créés sur le Pi :

| Fichier | Contenu |
|---|---|
| `/etc/wireguard/wg0.conf` | configuration du serveur et liste des appareils |
| `/etc/wg-pi/settings.conf` | réglages choisis à l'installation |
| `/etc/wg-pi/clients/*.conf` | configuration de chaque appareil |
| `/etc/wg-pi/firewall.sh` | règles pare-feu et NAT |
| `/etc/sysctl.d/99-wg-pi.conf` | activation du routage |
| `/usr/local/sbin/wg-pi` | la commande de gestion |
| `~/wireguard-clients/` | copies des configurations et QR codes, pour les récupérer facilement |

## Pourquoi ce projet

Plusieurs scripts existent déjà, mais aucun ne vise le cas « Raspberry Pi derrière une box » :

| Projet | Points forts | Limites pour un Pi à la maison |
|---|---|---|
| [PiVPN](https://github.com/pivpn/pivpn) | la référence historique sur Pi, WireGuard et OpenVPN | fin du projet annoncée avec la v4.6.0, maintenu « au mieux » depuis |
| [angristan/wireguard-install](https://github.com/angristan/wireguard-install) | simple, IPv4/IPv6, gestion des clients | pensé pour un serveur VPS : rien pour la box, l'IP locale ou le DynDNS |
| [Nyr/wireguard-install](https://github.com/Nyr/wireguard-install) | très simple | même public (VPS) |
| [wg-easy](https://github.com/wg-easy/wg-easy) | interface web | nécessite Docker ; la v15 ne prend plus en charge les Pi 32 bits |

WireGuard-RP ajoute ce qui manque chez soi : le guidage pour la box et l'IP fixe, DuckDNS, l'UPnP,
le test de connexion en direct, le diagnostic, la sauvegarde et la restauration.

> [!NOTE]
> Le script a été testé dans un conteneur Debian 12 : installation, connexion réelle d'un client,
> gestion des appareils, sauvegarde/restauration et redémarrage. Les retours sur de vrais Raspberry
> Pi et de vraies box (UPnP, DuckDNS) sont les bienvenus dans les
> [issues](https://github.com/y0uls/WireGuard-RP/issues).

## Contribuer

Les issues et les pull requests sont les bienvenues. Avant de proposer une modification :

- gardez des fins de ligne Unix (LF) : un fichier en CRLF ne s'exécute pas sur le Pi ;
- vérifiez le script avec `bash -n wg-pi.sh` et `shellcheck -S warning wg-pi.sh` (la même
  vérification tourne automatiquement sur GitHub à chaque envoi).

## Licence

Distribué sous licence [MIT](LICENSE).
