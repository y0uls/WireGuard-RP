#!/usr/bin/env bash
# Tests de la CLI d'accès : group, resource, access.
#
# Une fausse installation complète est montée dans un dossier temporaire : STATE_DIR,
# WG_DIR, le verrou et le journal sont tous redirigés, donc rien ne touche /etc/wg-pi
# ni /etc/wireguard. Ces tests sont sans danger sur un Pi en production.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./cli-access.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
mkdir -p "$TMP/etc" "$TMP/wg"

sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" \
    -e "s|^readonly WG_DIR=.*|readonly WG_DIR='$TMP/wg'|" \
    -e "s|^readonly LOCK_FILE=.*|readonly LOCK_FILE='$TMP/lock'|" \
    -e "s|^readonly LOG_FILE=.*|readonly LOG_FILE='$TMP/log'|" \
    -e "s|^readonly SYS_DIR=.*|readonly SYS_DIR='$TMP/run'|" \
    -e "s|^readonly SYS_FILE=.*|readonly SYS_FILE='$TMP/run/systeme.json'|" \
    -e "s|^readonly REBOOT_FILE=.*|readonly REBOOT_FILE='$TMP/reboot-required'|" \
    "$SCRIPT" > "$TMP/full.sh"
# Le marqueur de redirection est verifie comme les autres : un « sed » qui ne mord plus
# ferait ecrire le test dans le VRAI /run, ce que la suite promet de ne jamais faire.
for marqueur in "STATE_DIR='$TMP/etc'" "WG_DIR='$TMP/wg'" "LOCK_FILE='$TMP/lock'" "SYS_FILE='$TMP/run/systeme.json'" "REBOOT_FILE='$TMP/reboot-required'"; do
  grep -q "$marqueur" "$TMP/full.sh" || { echo "Redirection manquante : $marqueur" >&2; exit 2; }
done
if [[ $(tail -n1 "$TMP/full.sh") == 'main "$@"' ]]; then
  head -n -1 "$TMP/full.sh" > "$SRC"
else
  cp "$TMP/full.sh" "$SRC"
fi

# --- fausse installation ----------------------------------------------------
cat > "$TMP/etc/settings.conf" <<'SET'
WG_PORT=51820
WG_NET4=10.8.0
WG_NET6=fd00:1234:5678::
IPV6_ON=0
IPV6_NAT=0
LAN_IF=eth0
LAN_IP=192.168.1.50
LAN_PREFIX=24
LAN_GW=192.168.1.1
LAN_NET=192.168.1.0/24
LAN_MAC=dc:a6:32:11:22:33
ENDPOINT=exemple.duckdns.org
CLIENT_DNS=1.1.1.1
DEFAULT_ROUTE=split
SERVER_PUBKEY=SRVKEY
DDNS=duckdns
UPNP=0
UNATTENDED=0
ISP=free
IP_MODE=reserve
REACH=ok
SET

cat > "$TMP/wg/wg0.conf" <<'WGC'
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = PRIV

### Client: telephone
[Peer]
PublicKey = KEY1
PresharedKey = PSK1
AllowedIPs = 10.8.0.2/32

### Client: pc-salon
[Peer]
PublicKey = KEY2
PresharedKey = PSK2
AllowedIPs = 10.8.0.3/32

### Client: tablette
[Peer]
PublicKey = KEY3
PresharedKey = PSK3
AllowedIPs = 10.8.0.4/32
WGC

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then
    ok "$1"
  else
    ko "$1"
    echo "       obtenu  : [$2]"
    echo "       attendu : [$3]"
  fi
}
# Lance une commande wg-pi dans un sous-shell : les fonctions appellent « die », qui sort.
run() { ( source "$SRC"; TTY=""; AUTO=1; "$@" ) 2>&1; }
# Vrai si la commande a réussi.
runok() { if ( source "$SRC"; TTY=""; AUTO=1; "$@" ) >/dev/null 2>&1; then echo oui; else echo non; fi; }
# Lance une commande en silence, sans rien ajouter a la sortie.
silent() { ( source "$SRC"; TTY=""; AUTO=1; "$@" ) >/dev/null 2>&1 || true; }

# --- faux outils du systeme -------------------------------------------------
# Le bloc des mises a jour interroge la MACHINE : le paquet unattended-upgrades, apt,
# systemd, et GitHub par curl. L affirmer tel quel revient a tester la machine de qui lance
# les tests et non le code. On confine donc le PATH a des faux outils, ce qui rend chaque
# branche atteignable et la suite independante de la machine comme du reseau.
# Retirer un faux ne suffirait pas : la fonction trouverait le vrai juste derriere.
SBIN=$TMP/sbin OUTILS=$TMP/outils
mkdir -p "$SBIN" "$OUTILS"
for u in date cat sed awk grep head tail tr sort wc cut install dirname basename mktemp chmod mv rm stat cp mkdir; do
  p=$(command -v "$u") || { echo "Utilitaire introuvable : $u" >&2; exit 2; }
  { echo "#!/bin/sh"; echo "exec '$p' " '"$@"'; } > "$OUTILS/$u"
  chmod +x "$OUTILS/$u"
done

q=$(printf %s '"')   # un guillemet double, pour ecrire des motifs sans contre-oblique

faux() {   # faux <nom> <code de sortie> [ligne affichee...]
  local nom=$1 code=$2 l; shift 2
  { echo "#!/bin/sh"
    for l in "$@"; do echo "echo '$l'"; done
    echo "exit $code"
  } > "$SBIN/$nom"
  chmod +x "$SBIN/$nom"
}
sans() { rm -f "$SBIN/$1"; }

faux_curl() {   # faux_curl <version annoncee par le depot>  (vide : depot injoignable)
  if [[ -z ${1:-} ]]; then
    { echo "#!/bin/sh"; echo "exit 22"; } > "$SBIN/curl"
  else
    # Deux appels a distinguer : l API GitHub, qui rend une empreinte de commit, puis le
    # script lui-meme, dont seule la ligne de version est lue.
    { echo "#!/bin/sh"
      echo 'case "$*" in'
      echo "  *api.github.com*) echo 0123456789abcdef0123456789abcdef01234567 ;;"
      echo "  *) echo 'readonly WGPI_VERSION=${q}$1${q}' ;;"
      echo "esac"
    } > "$SBIN/curl"
  fi
  chmod +x "$SBIN/curl"
}

# Sortie standard seule : c est elle que lit le serveur Python, et un avertissement part
# sur la sortie d erreur sans que cela pose probleme.
runsys()    { ( source "$SRC"; TTY=""; AUTO=1; PATH=$SBIN:$OUTILS; "$@" ) 2>/dev/null; }

# Lance une commande en faisant croire que le tunnel tourne, et note ce que l application
# du pare-feu a recu. Sans cela, rien ne prouve qu une ecriture atteint le noyau : la CLI
# ecrivait sans jamais appliquer, « access rm » annoncait « supprimee » et l acces restait
# OUVERT. Un test de structure ne suffit pas ; on veut voir l appel.
MOUCHARD=$TMP/applique
trace() {
  : > "$MOUCHARD"
  ( source "$SRC"; TTY=""; AUTO=1
    wg_running() { return 0; }
    access_kernel_state() { echo inconnu; }
    access_rollback_armed() { return 1; }
    cmd_access_apply() { echo "applique${*:+ $*}" >> "$MOUCHARD"; return 0; }
    "$@" ) >/dev/null 2>&1
  # Pas de « tr » : la substitution de commande retire deja le saut de ligne final, et
  # le mouchard ne porte qu une ligne par application.
  cat "$MOUCHARD" 2>/dev/null
}
runsysok()  { if ( source "$SRC"; TTY=""; AUTO=1; PATH=$SBIN:$OUTILS; "$@" ) >/dev/null 2>&1; then echo oui; else echo non; fi; }

ACC=$TMP/etc/access.conf
rows() { grep -v '^#' "$ACC" 2>/dev/null; }

echo "-- la fausse installation est bien vue"
# Pas de « tr » avec une séquence d échappement ici : on compare directement le
# multi-ligne, ce qui est aussi plus lisible en cas d échec.
eq "trois appareils détectés" "$(run peers_table | awk '{ print $1 }')" "telephone
pc-salon
tablette"

echo "-- groupes"
eq "liste vide : message pédagogique" "$(run cmd_group list | grep -c 'Aucun groupe')" "1"
eq "création d un groupe" "$(runok cmd_group add invites --libelle=Invites)" oui
eq "groupe enregistré" "$(rows | grep '^GROUP')" "GROUP|invites|Invites"
eq "nom invalide refusé" "$(runok cmd_group add 'nom avec espaces')" non
eq "le groupe automatique ne peut pas être créé" "$(runok cmd_group add tous)" non
eq "libellé accentué accepté" "$(runok cmd_group add confiance '--libelle=Appareils de confiance')" oui

eq "rattachement d un appareil" "$(runok cmd_group join telephone confiance)" oui
eq "appartenance écrite" "$(rows | grep '^MEMBER')" "MEMBER|telephone|confiance"
eq "appareil inconnu refusé" "$(runok cmd_group join fantome confiance)" non
eq "groupe inconnu refusé" "$(runok cmd_group join telephone absent)" non
eq "on ne rejoint pas le groupe automatique" "$(runok cmd_group join telephone tous)" non

eq "deuxième rattachement" "$(runok cmd_group join telephone invites)" oui
eq "les deux appartenances" "$(rows | grep -c '^MEMBER')" "2"
silent cmd_group join telephone invites
eq "rattachement en double sans effet" "$(rows | grep -c '^MEMBER')" "2"

eq "retrait d un groupe" "$(runok cmd_group leave telephone invites)" oui
eq "une seule appartenance restante" "$(rows | grep '^MEMBER')" "MEMBER|telephone|confiance"

eq "fixer la liste des groupes" "$(runok cmd_group set pc-salon invites,confiance)" oui
eq "les deux groupes de pc-salon" "$(rows | grep '^MEMBER|pc-salon' | sort)" "MEMBER|pc-salon|confiance
MEMBER|pc-salon|invites"
silent cmd_group set pc-salon ''
eq "liste vide : plus aucun groupe" "$(rows | grep -c '^MEMBER|pc-salon')" "0"

echo "-- ressources"
eq "création d une ressource" "$(runok cmd_resource add nas 192.168.1.20 '--libelle=Le NAS')" oui
eq "ressource enregistrée" "$(rows | grep '^RES')" "RES|nas|Le NAS|192.168.1.20"
eq "cible invalide refusée" "$(runok cmd_resource add imprimante pas-une-ip)" non
eq "réseau accepté" "$(runok cmd_resource add cameras 192.168.1.64/28)" oui
eq "hors réseau de la maison : averti mais accepté" "$(run cmd_resource add ailleurs 10.9.9.9 | grep -c 'risque')" "1"

echo "-- une cible aux bits d hote non nuls est refusee"
# « 192.168.1.20/24 » est exactement ce qu on recopie depuis les reglages reseau de sa
# machine. Le noyau masque les bits d hote : la regle ouvrait les 254 machines du reseau,
# box comprise, pendant que tout l affichage montrait « 192.168.1.20/24 ».
eq "le reseau mal ecrit est refuse" "$(runok cmd_resource add nas2 192.168.1.20/24)" non
# Le refus doit NOMMER les deux lectures : sans cela l utilisateur ne sait pas quoi taper.
eq "le refus nomme la machine seule" "$(run cmd_resource add nas2 192.168.1.20/24 | grep -c '« 192.168.1.20 »')" "1"
eq "le refus nomme le reseau entier" "$(run cmd_resource add nas2 192.168.1.20/24 | grep -c '192.168.1.0/24')" "1"
eq "rien n a ete ecrit" "$(rows | grep -c '^RES|nas2')" "0"
# Les formes correctes restent acceptees, y compris celles dont les bits d hote SONT nuls.
eq "un reseau correct passe" "$(runok cmd_resource add bloc2 192.168.1.64/28)" oui
eq "une machine en /32 passe" "$(runok cmd_resource add seul 192.168.1.23/32)" oui
eq "0.0.0.0/0 reste accepte" "$(runok cmd_resource add monde 0.0.0.0/0)" oui
# La fonction elle-meme, cas par cas : c est elle que « access check » reutilise.
eq "bits d hote detectes" "$(runok access_target_host_bits 192.168.1.20/24)" oui
eq "reseau propre : non" "$(runok access_target_host_bits 192.168.1.0/24)" non
eq "adresse nue : non" "$(runok access_target_host_bits 192.168.1.20)" non
eq "/32 : non" "$(runok access_target_host_bits 192.168.1.20/32)" non
eq "/0 propre : non" "$(runok access_target_host_bits 0.0.0.0/0)" non
eq "/0 sale : oui" "$(runok access_target_host_bits 1.2.3.4/0)" oui
# Une cible qui n est pas une adresse du tout n a pas « des bits d hote » : c est une autre
# faute, deja signalee a part. Confondre les deux donnerait deux messages pour une erreur.
eq "cible absurde : non" "$(runok access_target_host_bits pas-une-ip/24)" non
eq "cible vide : non" "$(runok access_target_host_bits)" non

echo "-- règles d accès"
eq "autorisation simple" "$(runok cmd_access allow invites internet)" oui
eq "règle enregistrée avec un identifiant" "$(rows | grep -c '^POLICY|p1|')" "1"
eq "autorisation avec ports" "$(runok cmd_access allow confiance res:nas --proto=tcp --ports=445,5000-5001)" oui
eq "ports conservés" "$(rows | grep '^POLICY|p2|' | awk -F'|' '{ print $6 "/" $7 }')" "tcp/445,5000-5001"
silent cmd_access allow tous pi
eq "identifiants qui s enchaînent" "$(rows | grep -c '^POLICY|p3|')" "1"

eq "groupe inconnu refusé" "$(runok cmd_access allow absent internet)" non
eq "destination inconnue refusée" "$(runok cmd_access allow invites ailleurs)" non
eq "ressource inconnue refusée" "$(runok cmd_access allow invites res:absente)" non
eq "protocole inconnu refusé" "$(runok cmd_access allow invites internet --proto=sctp)" non
eq "sens inconnu refusé" "$(runok cmd_access allow invites internet --sens=retour)" non
eq "ports au-delà du budget refusés" "$(runok cmd_access allow invites internet --proto=tcp --ports=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)" non
# Des ports sans protocole de transport ne veulent rien dire, et iptables refuserait la
# règle au moment de l appliquer : mieux vaut refuser la saisie.
eq "ports sans tcp ni udp refusés" "$(runok cmd_access allow invites internet --ports=445)" non

eq "suppression d une règle" "$(runok cmd_access rm p1)" oui
eq "règle disparue" "$(rows | grep -c '^POLICY|p1|')" "0"
eq "règle inconnue refusée" "$(runok cmd_access rm p99)" non
silent cmd_access allow invites maison
eq "identifiant libéré réutilisé" "$(rows | grep -c '^POLICY|p1|')" "1"

echo "-- garde-fous de suppression"
# Supprimer un groupe ou une ressource encore cité par une règle effacerait cette règle
# en silence, par la purge des références mortes : on refuse et on nomme la règle.
eq "groupe utilisé par une règle : refusé" "$(runok cmd_group rm invites)" non
eq "le refus nomme la règle" "$(run cmd_group rm invites | grep -c 'p1')" "1"
eq "ressource utilisée par une règle : refusé" "$(runok cmd_resource rm nas)" non
silent cmd_access rm p1
eq "après suppression de la règle, le groupe part" "$(runok cmd_group rm invites)" oui

echo "-- affichage et vérification"
eq "access show mentionne l absence de cloisonnement" "$(run cmd_access show | grep -c 'Aucun cloisonnement')" "1"
eq "access show liste les groupes" "$(run cmd_access show | grep -c 'Tous les appareils')" "1"
eq "access list affiche les règles" "$(run cmd_access list | grep -c 'p2')" "1"
eq "access check sur un fichier sain" "$(runok cmd_access check)" oui

# Un fichier modifié à la main avec une référence morte doit être signalé par check, et
# non pas réparé en silence.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|g|G"
  echo "POLICY|px|1|grp:g|res:fantome|any||aller|Vers une ressource inexistante"
} > "$ACC"
eq "check signale une ressource inexistante" "$(run cmd_access check | grep -c 'fantome')" "1"
eq "check sort en échec" "$(runok cmd_access check)" non
# Et la première écriture suivante purge la référence morte.
silent cmd_group add neuf
eq "une écriture purge la référence morte" "$(rows | grep -c '^POLICY')" "0"

# Une barre verticale dans un libelle de RESSOURCE decale la cible : « RES|<id>|<libelle>
# |<cible> » place le libelle AU MILIEU. Toutes les ecritures de wg-pi la refusent, mais
# un fichier edite a la main ou une sauvegarde ancienne peuvent encore en contenir une,
# et la ressource designerait alors une AUTRE machine sans que rien ne change a l ecran.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "RES|nas|Le NAS|192.168.1.99|192.168.1.20"
} > "$ACC"
# Depuis qu un cinquieme champ (la MAC du reveil a distance) existe, ce n est plus le
# controle de la cible qui attrape cette ligne : « 192.168.1.99 » EST une adresse valide,
# et c est « 192.168.1.20 » qui atterrit la ou une MAC est attendue. Le garde-fou a change
# de main, pas de role — et c est bien pour cela que access_valid_mac doit refuser une IP.
eq "check signale une cible decalee par un libelle" \
   "$(run cmd_access check | grep -c "pas une adresse MAC")" "1"
eq "check refuse alors de se declarer satisfait" "$(runok cmd_access check)" non

# Et le controle d origine doit continuer de parler quand la cible, elle, est absurde.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "RES|nas|Le NAS|pas-une-ip"
} > "$ACC"
eq "une cible absurde est toujours signalee" \
   "$(run cmd_access check | grep -c "ni une adresse IP ni un réseau")" "1"

{
  echo "V|1"
  echo "MODE|ouvert"
  echo "RES|nas|Le NAS|192.168.1.20"
} > "$ACC"
eq "une ressource saine ne declenche rien" "$(runok cmd_access check)" oui


echo "-- le mode reste ouvert : aucun effet sur le trafic"
eq "mode inchangé par toutes ces commandes" "$(run access_mode)" "ouvert"


echo "-- colonne des groupes dans wg-pi list"
# Sans aucun groupe, le tableau doit etre exactement celui d avant : une installation qui
# n utilise pas la fonctionnalite ne doit rien voir changer.
cat > "$ACC" <<'ACC'
V|1
MODE|ouvert
ACC
eq "aucun groupe : pas de colonne" "$(run cmd_list | grep -c 'GROUPES')" "0"
eq "l entete habituel est intact" "$(run cmd_list | grep -c 'APPAREIL')" "1"

silent cmd_group add famille '--libelle=Ma famille'
silent cmd_group join telephone famille
eq "des groupes existent : la colonne apparait" "$(run cmd_list | grep -c 'GROUPES')" "1"
# La colonne affiche les IDENTIFIANTS et non les libelles : c est ce qu on tape dans les
# commandes, et c est plus court dans un tableau de terminal.
eq "le groupe est affiche sur la ligne de l appareil" "$(run cmd_list | grep telephone | grep -c 'famille')" "1"
# « tous » est implicite : l afficher sur chaque ligne n apprendrait rien.
eq "le groupe automatique n est pas affiche" "$(run cmd_list | grep -c 'Tous les appareils')" "0"
eq "un appareil sans groupe nomme affiche un tiret" "$(run cmd_list | grep pc-salon | grep -c '—')" "1"

silent cmd_group join telephone invites
silent cmd_group add invites '--libelle=Invites'
silent cmd_group join telephone invites
eq "deux groupes sont joints par une virgule" "$(run cmd_list | grep telephone | grep -cE 'famille,invites|invites,famille')" "1"

echo
echo "-- destination tout"
# Donner tous les droits a un groupe d administration tenait en quatre regles — internet,
# maison, pi, et une par groupe — qu il aurait fallu completer a chaque nouveau groupe.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|admin|Administration"
} > "$ACC"
silent cmd_access allow admin tout
eq "la regle tout est enregistree" "$(rows | grep -c '^POLICY.*|tout|')" "1"
# Le meme mot qu a la creation d un appareil : deux vocabulaires pour la meme idee
# obligeraient l utilisateur a traduire mentalement.
eq "le libelle reprend le vocabulaire des appareils" "$(run cmd_access show | grep -c 'Tout le trafic')" "1"
# « deux sens » reste reserve aux groupes : ailleurs le retour ne repasse pas par le VPN.
eq "les deux sens sont refuses vers tout" "$(runok cmd_access allow admin tout --sens=deux)" non
eq "une destination inventee reste refusee" "$(runok cmd_access allow admin partout)" non

echo
echo "-- ecriture pendant que le filtrage tourne deja"
# Toutes les ecritures ci-dessus tournent en mode « ouvert ». Ce mode-la rendait vrai le
# test final de la branche « allow », qui renvoyait donc 0 : le code de retour etait juste
# PAR ACCIDENT. En mode « filtre » le test devenait faux, et comme il etait la derniere
# instruction de la branche, sa valeur devenait le code de retour de cmd_access tout entier.
# « access allow » sortait en erreur APRES avoir enregistre la regle. Le panneau web, qui se
# fie au code de retour, montrait le succes en rouge et n appliquait jamais la regle : la
# liste affichait une regle absente du noyau. On exerce donc chaque ecriture dans les DEUX
# modes, puisque c est le mode qui decidait du resultat.
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|admin|Administration"
} > "$ACC"
eq "autorisation acceptee avec le filtrage actif" "$(runok cmd_access allow admin tout)" oui
eq "et la regle est bien enregistree" "$(rows | grep -c "^POLICY")" "1"
# Avec le filtrage actif, la DERNIERE regle ne se supprime pas : zero regle, c est tout
# couper. cmd_access_apply refusait bien d appliquer, mais la suppression avait deja eu
# lieu — la regle disparaissait du fichier, l ANCIENNE restait dans le noyau, et l ecran
# affichait une erreur rouge. On refuse donc AVANT d ecrire.
eq "la derniere regle active est protegee" "$(runok cmd_access rm p1)" non
eq "elle est toujours dans le fichier" "$(rows | grep -c '^POLICY|p1|')" "1"
eq "et le refus nomme la seule action qui a du sens" "$(run cmd_access rm p1 | grep -c 'access off')" "1"
# Une regle qui n est PAS la derniere se supprime normalement.
silent cmd_access allow admin internet
eq "deux regles maintenant" "$(rows | grep -c '^POLICY')" "2"
eq "la premiere se supprime" "$(runok cmd_access rm p1)" oui
eq "et il en reste une" "$(rows | grep -c '^POLICY')" "1"
# Hors filtrage, rien ne protege la derniere : il n y a rien a couper.
silent cmd_access off
eq "hors filtrage, la derniere se supprime" "$(runok cmd_access rm p2)" oui
eq "le fichier est vide de regles" "$(rows | grep -c '^POLICY')" "0"
{ echo "V|1"; echo "MODE|filtre"; echo "GROUP|admin|Administration"; } > "$ACC"
silent cmd_access allow admin tout
eq "creation de groupe acceptee avec le filtrage actif" "$(runok cmd_group add salon)" oui
eq "creation de ressource acceptee avec le filtrage actif" "$(runok cmd_resource add nas3 192.168.1.30)" oui
# Le rappel « pas encore actif » serait un mensonge quand le filtrage tourne.
eq "aucun rappel trompeur quand le filtrage tourne" "$(run cmd_access allow admin maison | grep -c "pas encore actif")" "0"

{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|admin|Administration"
} > "$ACC"
eq "le rappel revient quand le filtrage dort" "$(run cmd_access allow admin internet | grep -c "pas encore actif")" "1"
eq "et le code de retour reste bon en mode ouvert" "$(runok cmd_access allow admin maison)" oui

echo
echo "-- modifier une regle sans la ressaisir"
# Ajouter un seul port obligeait a supprimer la regle puis a retaper toute la liste.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|gaming|Gaming"
  echo "GROUP|admin|Administration"
  echo "RES|moon|MoonLight|192.168.1.18"
} > "$ACC"
silent cmd_access allow gaming res:moon --proto=udp --ports=47998,47999
silent cmd_access allow admin maison
eq "modification des ports acceptee" "$(runok cmd_access set p1 --ports=9,47998,47999)" oui
eq "les ports sont bien changes" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $7 }')" "9,47998,47999"
# Ce qui n est pas donne ne bouge pas, sinon chaque retouche serait une ressaisie.
eq "le protocole est conserve" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $6 }')" "udp"
eq "la destination est conservee" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $5 }')" "res:moon"
eq "le groupe source est conserve" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $4 }')" "grp:gaming"
# La regle garde sa place : corriger un port ne doit pas la faire sauter en bas de liste.
eq "la regle garde sa position" "$(rows | grep '^POLICY' | head -1 | awk -F'|' '{ print $2 }')" "p1"
# « --ports= » vide est le seul moyen de revenir a tous les ports.
eq "ports vides acceptes" "$(runok cmd_access set p1 --ports=)" oui
eq "tous les ports sont revenus" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $7 }')" ""
eq "changement de destination" "$(runok cmd_access set p1 --dest=maison)" oui
eq "destination changee" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $5 }')" "maison"
eq "vider le libelle le regenere" "$(runok cmd_access set p1 --libelle=)" oui

eq "identifiant inconnu refuse" "$(runok cmd_access set p99 --ports=9)" non
eq "option inconnue refusee" "$(runok cmd_access set p1 --couleur=rouge)" non
# La modification DOIT refuser exactement ce que la creation refuse. Sinon il suffirait
# de creer une regle anodine puis de la modifier pour contourner la validation.
eq "ports invalides refuses comme a la creation" "$(runok cmd_access set p1 --proto=tcp --ports=abc)" non
eq "sens deux hors groupe refuse comme a la creation" "$(runok cmd_access set p1 --sens=deux)" non
eq "destination inventee refusee comme a la creation" "$(runok cmd_access set p1 --dest=ailleurs)" non
eq "ressource inexistante refusee comme a la creation" "$(runok cmd_access set p1 --dest=res:absente)" non
eq "protocole invente refuse comme a la creation" "$(runok cmd_access set p1 --proto=sctp)" non
# Et aucun de ces refus n a touche au fichier.
eq "un refus ne modifie rien" "$(rows | grep '^POLICY|p1|' | awk -F'|' '{ print $5 }')" "maison"

echo
echo "-- changer l adresse d une ressource"
# Repointer une ressource deplace toutes les regles qui la citent sans que leur ligne
# change d un caractere : le message doit le dire, sinon la portee reste invisible.
eq "l adresse peut changer" "$(runok cmd_resource add moon 192.168.1.30)" oui
eq "la nouvelle adresse est en place" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $4 }')" "192.168.1.30"
eq "le message parle de modification" "$(run cmd_resource add moon 192.168.1.31 | grep -c 'modifiée')" "1"
eq "une creation parle d enregistrement" "$(run cmd_resource add nas9 192.168.1.40 | grep -c 'enregistrée')" "1"

echo
echo "-- reveil a distance (Wake-on-LAN)"
# Une machine endormie ne repond plus a l ARP : le Pi ne sait pas a quelle carte livrer le
# paquet magique. Figer l association demande de retenir la MAC a cote de la ressource.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|gaming|Gaming"
} > "$ACC"
eq "une MAC est acceptee" "$(runok cmd_resource add moon 192.168.1.18 --mac=AA:BB:CC:DD:EE:FF)" oui
# Normalisee : deux ecritures de la meme carte doivent donner la meme chaine.
eq "la MAC est normalisee en minuscules" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $5 }')" "aa:bb:cc:dd:ee:ff"
eq "les tirets de Windows sont acceptes" "$(runok cmd_resource add imp 192.168.1.21 --mac=00-11-22-33-44-55)" oui
eq "et convertis en deux-points" "$(rows | grep '^RES|imp|' | awk -F'|' '{ print $5 }')" "00:11:22:33:44:55"
# LE point critique : access_save relisait neuf champs et n en reecrivait que trois. Toute
# commande d ecriture aurait donc efface la MAC en silence, y compris une sans rapport.
silent cmd_group add salon2
eq "la MAC survit a une ecriture sans rapport" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $5 }')" "aa:bb:cc:dd:ee:ff"
# « resource add » remplace en place : changer l adresse ne doit pas perdre le reveil.
eq "changer l adresse garde la MAC" "$(runok cmd_resource add moon 192.168.1.19)" oui
eq "la MAC est toujours la" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $5 }')" "aa:bb:cc:dd:ee:ff"
eq "et l adresse a bien change" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $4 }')" "192.168.1.19"
# Effacer reste possible, mais il faut le demander explicitement.
eq "une MAC vide la retire" "$(runok cmd_resource add moon 192.168.1.19 --mac=)" oui
eq "la MAC a disparu" "$(rows | grep '^RES|moon|' | awk -F'|' '{ print $5 }')" ""
# Sans MAC, la ligne doit retrouver EXACTEMENT sa forme d avant : pas de barre en trop.
eq "aucun champ vide surnumeraire" "$(rows | grep -c '^RES|moon|moon|192.168.1.19$')" "1"
eq "une MAC invalide est refusee" "$(runok cmd_resource add moon 192.168.1.19 --mac=aa:bb:cc)" non
# Si une IP passait pour une MAC, le garde-fou de la ligne decalee tomberait.
eq "une adresse IP n est pas une MAC" "$(runok cmd_resource add moon 192.168.1.19 --mac=192.168.1.20)" non
eq "une option inconnue est refusee" "$(runok cmd_resource add moon 192.168.1.19 --couleur=rouge)" non
eq "un fichier avec MAC reste coherent" "$(runok cmd_access check)" oui
eq "la liste montre le reveil" "$(run cmd_resource list | grep -c 'réveil')" "1"

# Figer une association, c est dire au noyau de ne plus jamais redemander. Une erreur
# d un octet sur la box rendrait le Pi incapable de joindre sa passerelle : plus d
# Internet, plus de mise a jour, plus de VPN pour venir reparer. Rien ne se recupere a
# distance. Ces cibles sont donc refusees a la saisie, et non simplement signalees.
eq "une MAC sur la box est refusee" "$(runok cmd_resource add box 192.168.1.1 --mac=aa:bb:cc:dd:ee:ff)" non
eq "le refus nomme la box" "$(run cmd_resource add box 192.168.1.1 --mac=aa:bb:cc:dd:ee:ff | grep -c 'votre box')" "1"
eq "une MAC sur le Pi lui-meme est refusee" "$(runok cmd_resource add soi 192.168.1.50 --mac=aa:bb:cc:dd:ee:ff)" non
# Un reseau entier n a pas de carte : la pose serait silencieusement ignoree.
eq "une MAC sur un reseau est refusee" "$(runok cmd_resource add bloc 192.168.1.64/28 --mac=aa:bb:cc:dd:ee:ff)" non
# Hors du reseau de la maison, une adresse materielle n a aucun effet.
eq "une MAC hors du reseau local est refusee" "$(runok cmd_resource add loin 10.9.9.9 --mac=aa:bb:cc:dd:ee:ff)" non
# Et aucun de ces refus ne doit avoir ecrit quoi que ce soit.
eq "aucun refus n a ecrit de ressource" "$(rows | grep -cE '^RES.(box|soi|bloc|loin).')" "0"
# Les memes cibles restent declarables SANS reveil : on ne refuse que la MAC.
eq "la box reste declarable sans MAC" "$(runok cmd_resource add box 192.168.1.1)" oui
eq "un reseau reste declarable sans MAC" "$(runok cmd_resource add bloc 192.168.1.64/28)" oui

# Une ligne abimee par une edition a la main doit rester REPARABLE par l outil meme qui
# sert a la reparer : la MAC reprise du fichier est de l etat, pas de la saisie.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "RES|nas|Le NAS|192.168.1.20|pas-une-mac"
} > "$ACC"
eq "une ressource a MAC abimee reste modifiable" "$(runok cmd_resource add nas 192.168.1.21)" oui
eq "et la MAC abimee a ete purgee" "$(rows | grep '^RES|nas|' | awk -F'|' '{ print $5 }')" ""

# Le code de retour, encore : « resource add » sans --mac se terminait sur un test faux.
eq "resource add sans --mac rend bien 0" "$(runok cmd_resource add simple 192.168.1.22)" oui
eq "resource add avec --mac rend bien 0" "$(runok cmd_resource add simple 192.168.1.22 --mac=aa:bb:cc:dd:ee:01)" oui
eq "resource rm rend bien 0" "$(runok cmd_resource rm simple)" oui

# Un fichier edite a la main peut porter ce que la saisie refuse : le diagnostic doit le
# dire, parce que le pare-feu, lui, ignorera la ligne sans rien signaler.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "RES|box|La box|192.168.1.1|aa:bb:cc:dd:ee:ff"
} > "$ACC"
eq "le diagnostic signale une MAC sur la box" "$(run cmd_access check | grep -c 'box ou sur le Pi')" "1"
eq "et refuse de se declarer satisfait" "$(runok cmd_access check)" non

echo
echo "-- avertissement : tout le trafic, mais pas d Internet"
# Le symptome le plus deroutant du produit. L appareil envoie TOUT son trafic dans le
# tunnel, son groupe n autorise que la maison : les noms de sites se resolvent — le DNS de
# la box est dans le reseau de la maison, donc autorise — et aucune page ne charge.
# L utilisateur conclut que le VPN est casse. Rien ne le signalait.
mkdir -p "$TMP/etc/clients"
printf '[Interface]\nAllowedIPs = 0.0.0.0/0, ::/0\n' > "$TMP/etc/clients/telephone.conf"
printf '[Interface]\nAllowedIPs = 192.168.1.0/24, 10.8.0.0/24\n' > "$TMP/etc/clients/pc-salon.conf"
acces_filtre() {
  {
    echo "V|1"
    echo "MODE|filtre"
    echo "GROUP|admin|Administration"
    echo "MEMBER|telephone|admin"
    echo "MEMBER|pc-salon|admin"
  } > "$ACC"
}
acces_filtre

# Le mode se lit dans le fichier de l appareil, seul endroit ou il est ecrit. Le deduire du
# reglage par defaut de l installation serait faux : creer un appareil dans l autre mode
# est parfaitement legal.
eq "le mode est lu dans la configuration de l appareil" "$(run client_route_mode telephone)" "full"
eq "et l appareil en reseau maison est reconnu" "$(run client_route_mode pc-salon)" "split"
eq "un appareil inconnu ne declenche rien" "$(run client_route_mode absent)" "split"

eq "le groupe sans Internet est reconnu comme tel" "$(runok access_group_has_internet admin)" non
eq "l appareil qui route tout est signale" "$(run access_route_warn | grep -c 'envoie tout son trafic')" "1"
# Celui qui ne route que la maison va tres bien : l avertir serait du bruit.
eq "l appareil en reseau maison ne l est pas" "$(run access_route_warn | grep -c 'pc-salon')" "0"
# UNE SEULE ligne d alerte, et elle porte les noms : le panneau ne remonte que ces lignes,
# les colle bout a bout et tronque a 400 caracteres. Une par appareil donnerait un pave
# coupe au milieu d un nom.
eq "une seule ligne d alerte" "$(run access_route_warn | grep -c '⚠')" "1"
eq "et elle nomme l appareil" "$(run access_route_warn | grep '⚠' | grep -c 'telephone')" "1"

# Les deux destinations qui donnent Internet doivent l eteindre, pas une seule.
silent cmd_access allow admin tout
eq "une regle « tout » eteint l avertissement" "$(run access_route_warn | grep -c 'telephone')" "0"
eq "et le groupe est alors reconnu" "$(runok access_group_has_internet admin)" oui
acces_filtre
silent cmd_access allow admin internet
eq "une regle « internet » l eteint aussi" "$(run access_route_warn | grep -c 'telephone')" "0"

# En mode ouvert rien ne filtre : l appareil a REELLEMENT Internet. Avertir serait faux,
# et un avertissement faux est pire que pas d avertissement du tout.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|admin|Administration"
  echo "MEMBER|telephone|admin"
} > "$ACC"
eq "rien n est signale quand le filtrage dort" "$(run access_route_warn | grep -c 'telephone')" "0"

echo
echo "-- et l avertissement ne doit jamais devenir un code d erreur"
# access_route_warn rend NON NUL quand il avertit. En derniere instruction d une branche de
# « case », ce code devient celui de la commande entiere, et le panneau web prend le succes
# pour une erreur : message vert affiche en rouge, fenetre qui reste ouverte, et surtout
# pare-feu jamais applique. Ce piege a deja coute une version : on le verifie sur CHAQUE
# ecriture qui peut declencher l avertissement.
acces_filtre
eq "l avertissement se declenche bien a l ecriture" "$(run cmd_access allow admin maison | grep -c 'Sans Internet')" "1"
eq "allow rend tout de meme 0" "$(runok cmd_access allow admin maison)" oui
eq "set rend tout de meme 0" "$(runok cmd_access set p1 --proto=tcp --ports=443)" oui
eq "rm rend tout de meme 0" "$(runok cmd_access rm p1)" oui
eq "group join rend tout de meme 0" "$(runok cmd_group join tablette admin)" oui
eq "group leave rend tout de meme 0" "$(runok cmd_group leave tablette admin)" oui
eq "group set rend tout de meme 0" "$(runok cmd_group set tablette admin)" oui
# Celle-ci ne parle pas du code de retour sous avertissement : elle verifie le refus d un
# groupe qui n existe pas. Son ancien intitule le faisait passer pour le contraire, et le
# vrai test du code de retour est la ligne suivante.
eq "group rm d un groupe inexistant est refuse" "$(runok cmd_group rm vide)" non
silent cmd_group add jetable
eq "group rm reussi rend 0" "$(runok cmd_group rm jetable)" oui
eq "access show rend tout de meme 0" "$(runok cmd_access show)" oui
# Celle du dessus ne peut PAS echouer : dans access_show, access_route_note est suivie
# d access_listening_note, qui rend toujours 0 et masque donc tout code non nul laisse par
# la premiere. On verifie donc l invariant a la source : la fonction qui avale le code de
# retour de l avertissement doit rendre 0 ALORS MEME qu elle avertit.
eq "l avertissement sonne bien dans cet etat" "$(run access_route_warn | grep -c 'Sans Internet')" "1"
eq "access_route_warn rend NON NUL quand il avertit" "$(runok access_route_warn)" non
eq "et access_route_note l avale et rend 0" "$(runok access_route_note)" oui

echo
echo "-- toute ecriture doit atteindre le noyau quand le filtrage tourne"
# Le defaut : seul le panneau web rappelait « access-apply ». En ligne de commande, la
# regle partait dans le fichier et jamais dans le noyau — et « access check », qui compare
# le fichier a lui-meme, confirmait que tout etait coherent. Les identifiants de regles
# etant reemployes, le noyau finissait meme par appliquer un « p1 » qui designait un tout
# autre acces.
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|jeu|Jeu"
  echo "MEMBER|telephone|jeu"
  echo "RES|nas|Le NAS|192.168.1.20"
  echo "POLICY|p1|1|grp:jeu|res:nas|tcp|445|aller|Vers le NAS"
} > "$ACC"

# « --modifie » et non une application nue : le jeu de regles n est plus celui qu un humain
# a approuve, le filet d annulation doit donc jouer pour le NOUVEAU.
eq "access allow applique"    "$(trace cmd_access allow jeu maison)" "applique --modifie"
eq "access set applique"      "$(trace cmd_access set p1 --ports=445,139)" "applique --modifie"
eq "access rm applique"       "$(trace cmd_access rm p1)" "applique --modifie"
eq "group join applique"      "$(trace cmd_group join pc-salon jeu)" "applique --modifie"
eq "group leave applique"     "$(trace cmd_group leave pc-salon jeu)" "applique --modifie"
eq "group set applique"       "$(trace cmd_group set pc-salon jeu)" "applique --modifie"
eq "resource add applique"    "$(trace cmd_resource add nas 192.168.1.30)" "applique --modifie"
# Le cycle de vie des appareils compte autant : « wg syncconf » ne rejoue pas le PostUp de
# wg-quick, donc un appareil ajoute n avait aucun saut vers la chaine de son groupe et
# tombait sur le refus, QR code affiche et diagnostics verts.
# Sans « --modifie » pour le cycle de vie : la liste des appareils change, mais pas ce que
# les appareils deja en place peuvent joindre. Armer l annulation la aurait fait retomber
# tout le cloisonnement deux minutes apres un simple « wg-pi add » laisse sans reponse.
eq "disable applique"         "$(trace cmd_set_state off tablette)" "applique"
eq "enable applique"          "$(trace cmd_set_state on tablette)" "applique"
eq "rename applique"          "$(trace cmd_rename tablette tab2)" "applique"

# Et le renommage doit emmener les appartenances : sinon elles citent un appareil qui
# n existe plus, l appareil perd tous ses acces, et la premiere ecriture suivante les purge.
{
  echo "V|1"; echo "MODE|ouvert"; echo "GROUP|jeu|Jeu"; echo "MEMBER|tab2|jeu"
} > "$ACC"
silent cmd_rename tab2 tablette
eq "le renommage suit dans les appartenances" "$(rows | grep '^MEMBER')" "MEMBER|tablette|jeu"

# Hors filtrage, rien ne doit etre applique : il n y a pas de chaines a reconstruire.
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|jeu|Jeu"; } > "$ACC"
eq "en mode ouvert, aucune application" "$(trace cmd_access allow jeu maison)" ""

echo
echo "-- le protocole double par la ligne de commande"
# La seule couverture de tcpudp etait le generateur pur : le chemin d ecriture, ses deux
# validateurs et le code de retour n etaient testes nulle part. Trois mutations du
# validateur laissaient la suite entierement verte.
{
  echo "V|1"; echo "MODE|ouvert"; echo "GROUP|jeu|Jeu"
  echo "RES|nas|Le NAS|192.168.1.20"
} > "$ACC"
eq "allow --proto=tcpudp est accepte" "$(runok cmd_access allow jeu res:nas --proto=tcpudp --ports=27015,27036)" oui
eq "et la regle est enregistree une seule fois" "$(rows | grep -c '|tcpudp|')" "1"
eq "avec ses ports" "$(rows | grep '^POLICY' | cut -d'|' -f7)" "27015,27036"
# Les ports n ont de sens qu avec tcp, udp ou tcpudp — et tcpudp en fait partie.
eq "des ports avec tcpudp sont acceptes" "$(runok cmd_access allow jeu maison --proto=tcpudp --ports=8080)" oui
eq "des ports avec icmp sont refuses" "$(runok cmd_access allow jeu maison --proto=icmp --ports=8080)" non
eq "un protocole invente est refuse" "$(runok cmd_access allow jeu maison --proto=tcpudpicmp)" non
# Le message de refus doit nommer tcpudp : dire a l utilisateur que ce qu il cherche
# n existe pas est pire que ne rien dire.
eq "le refus nomme tcpudp" "$(run cmd_access allow jeu maison --proto=sctp | grep -c tcpudp)" "1"
# Et la modification doit pouvoir passer une regle en tcpudp.
PID=$(rows | grep '|tcpudp|' | head -n1 | cut -d'|' -f2)
eq "set peut repasser en tcp" "$(runok cmd_access set "$PID" --proto=tcp)" oui
eq "et set peut revenir a tcpudp" "$(runok cmd_access set "$PID" --proto=tcpudp)" oui
eq "l affichage ne montre jamais le jeton brut" "$(run cmd_access list | grep -c 'tcpudp')" "0"
# Deux : les deux regles tcpudp posees plus haut, celle vers le NAS et celle vers la maison.
eq "il dit TCP et UDP" "$(run cmd_access list | grep -c 'TCP et UDP')" "2"

echo
echo "-- Internet donne par une ressource couvrant tout"
# access_group_has_internet ne reconnaissait que les destinations « internet » et « tout ».
# Une ressource en 0.0.0.0/0 donne pourtant reellement Internet : l avertissement
# « sans Internet malgre tout le trafic » sonnait sur un appareil qui a tout.
{
  echo "V|1"; echo "MODE|filtre"; echo "GROUP|adm|Administration"
  echo "MEMBER|telephone|adm"
  echo "RES|monde|Internet|0.0.0.0/0"
  echo "POLICY|p1|1|grp:adm|res:monde|any||aller|Tout"
} > "$ACC"
eq "une ressource couvrant tout compte pour Internet" "$(runok access_group_has_internet adm)" oui
eq "et aucun avertissement ne sonne" "$(run access_route_warn | grep -c 'tout son trafic')" "0"
# Une ressource ordinaire ne compte pas, elle.
{
  echo "V|1"; echo "MODE|filtre"; echo "GROUP|adm|Administration"
  echo "MEMBER|telephone|adm"
  echo "RES|nas|Le NAS|192.168.1.20"
  echo "POLICY|p1|1|grp:adm|res:nas|any||aller|Le NAS"
} > "$ACC"
eq "une ressource ordinaire ne donne pas Internet" "$(runok access_group_has_internet adm)" non


echo "-- une cible deja enregistree avec des bits d hote"
# Un access.conf ecrit par une version anterieure, ou a la main, peut en contenir. Le
# pare-feu ouvre deja tout le reseau : l ecran doit dire la meme chose que le noyau.
{
  echo "V|1"; echo "MODE|filtre"; echo "GROUP|inv|Invites"
  echo "MEMBER|telephone|inv"
  echo "RES|nas|Le NAS|192.168.99.20/24"
  echo "POLICY|p1|1|grp:inv|res:nas|tcp|445|aller|Partage"
} > "$ACC"
eq "la cible lue est normalisee" "$(run access_res_target nas)" "192.168.99.0/24"
eq "le plan pose la regle que le noyau appliquera" "$(run access_match_dest res:nas)" "-d 192.168.99.0/24"
eq "le diagnostic le signale" "$(run access_check | grep -c 'ouvre tout le réseau')" "1"
eq "et il propose la correction" "$(run access_check | grep -c 'resource add nas 192.168.99.20')" "1"
# Une ressource saine ne doit evidemment rien declencher.
{
  echo "V|1"; echo "MODE|filtre"; echo "GROUP|inv|Invites"
  echo "MEMBER|telephone|inv"
  echo "RES|nas|Le NAS|192.168.1.20"
  echo "POLICY|p1|1|grp:inv|res:nas|tcp|445|aller|Partage"
} > "$ACC"
eq "une ressource saine ne declenche rien" "$(run access_check | grep -c 'ouvre tout le réseau')" "0"
eq "et sa cible sort telle quelle" "$(run access_res_target nas)" "192.168.1.20"

echo

echo
echo "-- les reseaux locaux du Pi, lus dans le systeme"
# « internet » n excluait que LAN_NET. Un Pi qui heberge Pi-hole ou Home Assistant porte
# aussi des ponts Docker, et peut avoir une seconde carte ou un VLAN : tout cela restait
# joignable depuis un groupe cense n avoir qu Internet. La liste est donc lue dans le
# systeme — et ici dans un FAUX « ip », pour que le test ne mesure pas la machine.
# LAN_NET est pose a la main : « source » seul ne charge pas les reglages, et sans lui le
# test ne mesurerait que le faux « ip » au lieu des deux sources que la fonction fond.
nets() { ( source "$SRC"; LAN_NET=192.168.1.0/24; PATH=$SBIN:$OUTILS; access_local_nets ) 2>/dev/null; }
# « ip » doit distinguer « addr show » de « route show » : les reseaux que le Pi ROUTE sans
# y avoir d adresse — un second routeur, le VLAN invites de la box — ne sont visibles que
# dans la table de routage, et ils etaient entierement laisses dehors.
IPADDR=$TMP/ip-addr IPROUTE=$TMP/ip-route
: > "$IPADDR"; : > "$IPROUTE"
faux_ip() {
  { echo "#!/bin/sh"
    echo "case \"\$*\" in"
    echo "  *route*) cat '$IPROUTE' ;;"
    echo "  *) cat '$IPADDR' ;;"
    echo "esac"
    echo "exit 0"
  } > "$SBIN/ip"
  chmod +x "$SBIN/ip"
}
faux ip 0 "1: lo    inet 127.0.0.1/8 scope host lo" "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0" "3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0" "4: br-9f12ab    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-9f12ab" "5: wg0    inet 10.8.0.1/24 scope global wg0" "6: eth0.20@eth0    inet 10.10.0.5/16 brd 10.10.255.255 scope global eth0.20"
# Comparaison multi-ligne directe : la cible doit etre lisible dans le message d echec.
eq "la maison, les deux ponts Docker et le VLAN" "$(nets)" "192.168.1.0/24
172.17.0.0/16
172.18.0.0/16
10.10.0.0/16"
# wg0 est le tunnel lui-meme : l ecarter de « internet » couperait le pair-a-pair, qui est
# deja traite par « ! -o wg0 ». Et « lo » n est pas un reseau local au sens du filtrage.
eq "le tunnel n y est pas" "$(nets | grep -c '^10.8.0')" "0"
eq "la boucle locale n y est pas" "$(nets | grep -c '^127')" "0"
# LAN_NET vient des reglages, pas de « ip » : il doit figurer meme quand la commande manque,
# sinon une seule absence d outil rendrait « Internet seulement » plus large que promis.
sans ip
eq "sans la commande ip, la maison reste exclue" "$(nets)" "192.168.1.0/24"
# Un doublon — la meme adresse vue deux fois, ce qui arrive avec une IP secondaire sur la
# meme carte — ne doit pas poser deux fois la meme regle.
faux ip 0 "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0" "2: eth0    inet 192.168.1.51/24 brd 192.168.1.255 scope global eth0:1"
eq "les doublons sont fondus" "$(nets)" "192.168.1.0/24"
# Une sortie que « ip » ne produirait jamais ne doit pas faire entrer n importe quoi dans
# le plan : le moteur garantit qu aucun argument emis ne contient d espace.
faux ip 0 "2: eth0    inet pas-une-adresse/24 scope global eth0" "3: eth1    inet 192.168.7.9/0 scope global eth1" "4: eth2    inet 192.168.8.9/99 scope global eth2"
eq "les lignes absurdes sont ignorees" "$(nets)" "192.168.1.0/24"

echo
echo "-- les reseaux que le Pi ROUTE sans y avoir d adresse"
# Un VLAN invites ou IoT derriere la box, un second routeur, un maillage Wi-Fi : le Pi n y
# a aucune adresse, donc « ip addr » ne les montre pas, et « Internet seulement » les
# laissait joignables. « maison » ne couvre que LAN_NET : rien d autre ne les atteignait.
faux_ip
printf '%s\n' "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0" > "$IPADDR"
printf '%s\n' "default via 192.168.1.1 dev eth0" \
  "192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50" \
  "192.168.2.0/24 via 192.168.1.9 dev eth0" > "$IPROUTE"
eq "le VLAN route est ecarte lui aussi" "$(nets)" "192.168.1.0/24
192.168.2.0/24"
# La route par DEFAUT est le chemin vers Internet : l ecarter viderait la destination de
# tout son sens.
eq "la route par defaut n entre pas" "$(nets | grep -c '^default')" "0"
# Une route vers un reseau PUBLIC est un chemin vers Internet, pas un reseau local.
printf '%s\n' "default via 192.168.1.1 dev eth0" \
  "9.9.9.0/24 via 192.168.1.1 dev eth0" \
  "10.77.0.0/16 via 192.168.1.9 dev eth0" > "$IPROUTE"
eq "un reseau public route reste Internet" "$(nets | grep -c '^9[.]9[.]9')" "0"
eq "un reseau prive route est local" "$(nets | grep -c '^10[.]77')" "1"
# Et le tunnel lui-meme ne compte pas : il est deja traite par « ! -o wg0 ».
printf '%s\n' "10.8.0.0/24 dev wg0 proto kernel scope link src 10.8.0.1" > "$IPROUTE"
eq "les routes du tunnel sont ignorees" "$(nets | grep -c '^10[.]8[.]0')" "0"
# La fonction de classement, cas par cas.
prive() { ( source "$SRC"; access_net_prive "$1" && echo oui || echo non ); }
eq "10/8 est prive"        "$(prive 10.0.0.0/8)" oui
eq "172.16/12 aussi"       "$(prive 172.18.0.0/16)" oui
eq "192.168/16 aussi"      "$(prive 192.168.2.0/24)" oui
eq "la plage operateur aussi" "$(prive 100.64.0.0/10)" oui
eq "le lien-local aussi"    "$(prive 169.254.0.0/16)" oui
eq "9.9.9.9 est public"     "$(prive 9.9.9.0/24)" non
eq "172.32 est public"      "$(prive 172.32.0.0/16)" non
eq "une adresse nue est acceptee" "$(prive 192.168.4.4)" oui
eq "et une absurdite est refusee" "$(prive pas-une-ip)" non

echo "-- une interface restee DOWN n a pas de reseau joignable"
# « ip addr show up » ne rend que les interfaces montees : nommer le reseau d une carte
# eteinte n ajoutait qu une regle morte dans la chaine. Le faux « ip » recoit ici
# l argument « up » et c est a lui de filtrer, comme le vrai.
{ echo "#!/bin/sh"
  echo "case \"\$*\" in"
  echo "  *route*) cat '$IPROUTE' ;;"
  echo "  *\"addr show up\"*) cat '$IPADDR' ;;"
  echo "  *) cat '$IPADDR'; echo '9: eth9    inet 192.168.44.1/24 scope global eth9' ;;"
  echo "esac"
  echo "exit 0"
} > "$SBIN/ip"
chmod +x "$SBIN/ip"
printf '%s\n' "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0" > "$IPADDR"
: > "$IPROUTE"
eq "la carte eteinte n est pas ecartee" "$(nets | grep -c '^192[.]168[.]44')" "0"
eq "et la carte montee l est" "$(nets)" "192.168.1.0/24"
sans ip

echo
echo "-- mises a jour de securite : les trois reponses possibles"
# Le panneau n affiche « actives » ou « arretees » que d apres ce seul mot. Celui qui compte
# vraiment est le troisieme : demande mais inoperant, le cas qui laisse croire a l utilisateur
# qu il est protege alors que rien ne tourne.
sans dpkg-query
eq "sans le paquet : inactif" "$(runsys unattended_state)" inactif
eq "et le code de retour reste 0" "$(runsysok unattended_state)" oui

faux dpkg-query 0 "install ok installed"
sans apt-config
eq "le paquet seul, sans apt-config : inactif" "$(runsys unattended_state)" inactif

faux apt-config 0 "1"
faux systemctl 0 "active"
eq "demande et minuteur actif : actif" "$(runsys unattended_state)" actif

faux systemctl 0 "inactive"
eq "demande mais minuteur arrete : incoherent" "$(runsys unattended_state)" incoherent

# Le cas qui compte : la cle a 0 veut dire « rien ne s installera », quoi que fasse le
# minuteur d apt — livre ACTIF par Debian. Le declarer « incoherent » faisait compter un
# probleme a « wg-pi check » juste apres un « maj-auto off », et lui proposait d annuler
# ce que l utilisateur venait de demander.
faux apt-config 0 "0"
faux systemctl 0 "active"
eq "periode nulle : inactif, meme minuteur actif" "$(runsys unattended_state)" inactif

faux systemctl 0 "inactive"
eq "rien de demande, rien qui tourne : inactif" "$(runsys unattended_state)" inactif

# Une sortie vide d apt-config doit compter pour zero, et non passer pour « non nul ».
faux apt-config 0 ""
eq "apt-config muet compte pour zero" "$(runsys unattended_state)" inactif

echo
echo "-- paquets en attente"
# Ce compte part dans du JSON : il doit TOUJOURS etre un nombre, meme quand apt est absent,
# en echec, ou bavard sur sa sortie d erreur.
sans apt-get
eq "sans apt-get : zero" "$(runsys pending_upgrades)" "0"
faux apt-get 1 "E: Could not get lock /var/lib/dpkg/lock-frontend"
eq "apt-get en echec : zero quand meme" "$(runsys pending_upgrades)" "0"
faux apt-get 0 "Inst libc6 [2.36-9] (2.36-9+deb12u7 Debian-Security:12/stable [armhf])"
eq "une ligne Inst est comptee" "$(runsys pending_upgrades)" "1"

echo
echo "-- releve servi au panneau"
# Le panneau interroge son etat en boucle. Une requete vers GitHub et un fork d apt a chaque
# releve mettraient un Raspberry Pi a genoux : le resultat est donc mis en cache, et la
# moitie distante vit six heures quand la moitie locale en vit un quart d heure.
# Toutes les sondes sont ici simulees : le systeme est en ordre, et le depot annonce 9.9.9.
faux dpkg-query 0 "install ok installed|1.0.20210914-1"
faux apt-config 0 "1"
faux systemctl 0 "active"
faux apt-get 0 "Inst libc6 [2.36-9] (2.36-9+deb12u7 Debian-Security:12/stable [armhf])"
faux_curl 9.9.9
rm -f "$TMP/run/systeme.json"
SJ=$(runsys cmd_sys_json)
# Rien d autre que du JSON sur la sortie standard : un ok, un warn ou un info y
# feraient echouer la lecture cote Python.
eq "le releve tient sur une seule ligne" "$(printf '%s' "$SJ" | wc -l)" "0"
eq "et commence par une accolade" "$(printf '%s' "$SJ" | cut -c1)" "{"
for cle in ts wgpi wireguard auto demande paquets reboot maj_ts maj_version maj_etat; do
  eq "le releve porte la cle $cle" "$(printf '%s' "$SJ" | grep -c "$q$cle$q:")" "1"
done
# La distinction qui compte : ce qui a ete DEMANDE n est pas ce qui EST. Ici les sondes
# disent « actif » alors que le reglage enregistre vaut UNATTENDED=0 : les deux doivent
# rester separes, sans quoi le panneau afficherait l un pour l autre.
eq "l etat reel suit les sondes" "$(printf '%s' "$SJ" | grep -c "${q}auto$q:${q}actif$q")" "1"
eq "et ne se confond pas avec le reglage" "$(printf '%s' "$SJ" | grep -c "${q}demande$q:false")" "1"
# Les sondes locales sont reportees telles quelles.
eq "la version de wireguard-tools est lue" "$(printf '%s' "$SJ" | grep -c "${q}wireguard$q:${q}1.0.20210914-1$q")" "1"
eq "le nombre de paquets en attente est repris" "$(printf '%s' "$SJ" | grep -c "${q}paquets$q:1")" "1"
# Et la moitie distante : 9.9.9 est posterieure a la version du script.
eq "une version plus recente se dit neuve" "$(printf '%s' "$SJ" | grep -c "${q}maj_etat$q:${q}neuf$q")" "1"
eq "et la version du depot est reportee" "$(printf '%s' "$SJ" | grep -c "${q}maj_version$q:${q}9[.]9[.]9$q")" "1"

eq "le cache est ecrit" "$([[ -s $TMP/run/systeme.json ]] && echo oui || echo non)" oui
# Deuxieme appel : servi depuis le cache, a l identique.
eq "le second appel ressert le cache" "$(runsys cmd_sys_json)" "$SJ"
# Et le cache tient tete au depot : la moitie locale vit un quart d heure.
faux_curl 1.0.0
eq "le cache tient tete au depot" "$(runsys cmd_sys_json)" "$SJ"
# --rafraichir passe outre, et une version anterieure se dit « a jour ».
SJ2=$(runsys cmd_sys_json --rafraichir)
eq "le rafraichissement reinterroge le depot" "$(printf '%s' "$SJ2" | grep -c "${q}maj_etat$q:${q}ajour$q")" "1"

# Depot injoignable : ne pas savoir doit se dire, et surtout ne pas passer pour « a jour ».
faux_curl ""
SJ3=$(runsys cmd_sys_json --rafraichir)
eq "depot injoignable : la sortie reste du JSON pur" "$(printf '%s' "$SJ3" | cut -c1)" "{"
eq "ne pas savoir se dit" "$(printf '%s' "$SJ3" | grep -c "${q}maj_etat$q:${q}inconnu$q")" "1"
eq "et aucune version n est inventee" "$(printf '%s' "$SJ3" | grep -c "${q}maj_version$q:$q$q")" "1"

echo
echo "-- resource add : le libelle de l existant est repris"
# La commande que le diagnostic affiche pour corriger une cible — et l exemple « une
# machine a change d adresse » du README — ne repassent pas --libelle. Le libelle etait
# donc remplace par l identifiant, en silence. Or c est le seul texte que l utilisateur
# lit : dans le panneau, dans chaque titre de regle, en tete de colonne de la matrice.
{ echo "V|1"; echo "MODE|ouvert"; } > "$ACC"
silent cmd_resource add nas 192.168.1.20 --libelle="Le NAS" --mac=aa:bb:cc:dd:ee:ff
eq "la ressource est posee" "$(rows | grep '^RES|nas')" "RES|nas|Le NAS|192.168.1.20|aa:bb:cc:dd:ee:ff"
# Exactement la commande du README, sans --libelle :
silent cmd_resource add nas 192.168.1.25
eq "le libelle survit au changement d adresse" "$(rows | grep '^RES|nas')" "RES|nas|Le NAS|192.168.1.25|aa:bb:cc:dd:ee:ff"
# Et --libelle le remplace toujours quand il est donne.
silent cmd_resource add nas 192.168.1.26 --libelle="Le nouveau NAS"
eq "--libelle reste maitre" "$(rows | grep '^RES|nas')" "RES|nas|Le nouveau NAS|192.168.1.26|aa:bb:cc:dd:ee:ff"
# Une creation garde le repli sur l identifiant.
silent cmd_resource add imprimante 192.168.1.30
eq "sans libelle, une creation prend l identifiant" "$(rows | grep '^RES|imprimante')" "RES|imprimante|imprimante|192.168.1.30"

echo "-- le titre d une regle ne fige plus l adresse de la ressource"
# Il etait calcule une fois avec l adresse du moment, puis grave. cmd_resource promet
# pourtant en commentaire que « toutes les regles res:<nom> suivent la nouvelle adresse
# sans changer d un caractere a l ecran » : la destination suivait, le titre non, et
# « access list » affichait deux adresses differentes pour la MEME regle.
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|fam|La famille"; echo "MEMBER|telephone|fam"
  echo "RES|nas|Le NAS|192.168.1.20"; } > "$ACC"
silent cmd_access allow fam res:nas --proto=tcp --ports=445
eq "le titre ne porte aucune adresse" "$(rows | grep '^POLICY|p1|' | cut -d'|' -f9)" "La famille → Le NAS"
silent cmd_resource add nas 192.168.1.25 --libelle="Le NAS"
eq "apres le demenagement, le titre est toujours juste" "$(rows | grep '^POLICY|p1|' | cut -d'|' -f9)" "La famille → Le NAS"
# Une seule adresse a l ecran, et c est la bonne.
eq "access list ne montre qu une adresse" "$(run cmd_access list | grep -c '192.168.1.20')" "0"
eq "et c est la nouvelle" "$(run cmd_access list | grep -c '192.168.1.25')" "1"
# « maison » non plus ne fige le reseau dans le titre.
silent cmd_access allow fam maison
eq "le titre de maison reste stable" "$(rows | grep '^POLICY|p2|' | cut -d'|' -f9)" "La famille → Le réseau de la maison"

echo "-- le diagnostic complet signale aussi la cible trop large"
# La boucle ne vivait que dans « access check », alors que le README presente
# « sudo wg-pi check » comme le diagnostic complet et le met en avant partout.
{ echo "V|1"; echo "MODE|ouvert"; echo "RES|nas|Le NAS|192.168.99.20/24"; } > "$ACC"
eq "access_hostbits_warn le dit" "$(run access_hostbits_warn | grep -c 'ouvre tout le réseau')" "1"
eq "et nomme la correction" "$(run access_hostbits_warn | grep -c 'resource add nas 192.168.99.20')" "1"
eq "il rend non nul quand il signale" "$(runok access_hostbits_warn)" non
eq "la version note avale le code" "$(runok access_hostbits_note)" oui
{ echo "V|1"; echo "MODE|ouvert"; echo "RES|nas|Le NAS|192.168.99.20"; } > "$ACC"
eq "une cible saine ne declenche rien" "$(run access_hostbits_warn | grep -c 'ouvre tout')" "0"
eq "et il rend 0" "$(runok access_hostbits_warn)" oui

echo "-- --mac sur un /32 : c est une machine unique"
# access_target_host_bits, ecrite pour trancher entre « une machine » et « un reseau »,
# classe « /32 » comme machine unique. cmd_resource refusait toute barre oblique : le
# produit portait deux definitions contradictoires, et c etait la plus ancienne qui
# parlait a l utilisateur.
{ echo "V|1"; echo "MODE|ouvert"; } > "$ACC"
eq "un /32 avec une MAC est accepte" "$(runok cmd_resource add nas 192.168.1.20/32 --mac=aa:bb:cc:dd:ee:ff)" oui
# Et la cible est enregistree comme une adresse nue : les garde-fous voisins comparent
# des adresses, et « ip neigh » n accepte pas de prefixe.
eq "et la cible est rangee sans le /32" "$(rows | grep '^RES|nas')" "RES|nas|nas|192.168.1.20|aa:bb:cc:dd:ee:ff"
eq "un vrai reseau reste refuse" "$(runok cmd_resource add bloc 192.168.1.64/28 --mac=aa:bb:cc:dd:ee:ff)" non
eq "et le refus parle d adresse unique" "$(run cmd_resource add bloc 192.168.1.64/28 --mac=aa:bb:cc:dd:ee:ff | grep -c 'adresse unique')" "1"

echo "-- le garde-fou DNS part avec les ecritures, pas seulement avec le diagnostic"
# Il n avait que trois appelants : « check », « access check » et « access on ». Or le
# panneau web n apprend un avertissement que par les lignes « ⚠ » de la commande qu il
# vient de lancer : poser la regle piege depuis le navigateur coupait donc toute
# resolution de noms sans un mot.
sed -i "s/^CLIENT_DNS=.*/CLIENT_DNS=192.168.1.1/" "$TMP/etc/settings.conf"
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|inv|Invites"; echo "MEMBER|telephone|inv"; } > "$ACC"
eq "access allow avertit sur le DNS" "$(run cmd_access allow inv internet | grep -c 'aucun nom de site')" "1"
eq "et il nomme l appareil bloque" "$(run cmd_access allow inv internet | grep -c 'telephone')" "1"
# Un avertissement ne doit JAMAIS devenir un echec : c est le piege que ce projet a deja
# paye deux fois.
eq "et la commande reussit quand meme" "$(runok cmd_access allow inv internet)" oui
# Une fois le DNS couvert, le silence revient.
silent cmd_access allow inv maison
eq "DNS couvert : plus d avertissement" "$(run cmd_access allow inv pi --proto=tcp --ports=443 | grep -c 'aucun nom de site')" "0"
sed -i "s/^CLIENT_DNS=.*/CLIENT_DNS=1.1.1.1/" "$TMP/etc/settings.conf"

echo
echo "-- le releve local : ce que l utilisateur vient de faire doit se voir"
# Signale depuis l usage reel : « j avais 2 mises a jour systeme que j ai faites, pourtant
# il me dit encore que j ai des mises a jour sur l interface web apres les avoir faites. Il
# fallait que je redemarre... dommage que ca ne me le disait pas aussi sur l interface. »
# Le panneau servait le bloc ENTIER depuis le cache de quinze minutes : le compte de
# paquets ET le redemarrage demande avec.
faux dpkg-query 0 "install ok installed|1.0.20210914-1"
faux apt-config 0 "1"
faux systemctl 0 "active"
faux apt-get 0 "Inst libc6 [2.36-9] (2.36-9+deb12u7 Debian-Security:12/stable [armhf])"
faux_curl 9.9.9
rm -f "$TMP/run/systeme.json" "$TMP/reboot-required"
SL0=$(runsys cmd_sys_json)
eq "le cache part avec un paquet en attente" "$(printf '%s' "$SL0" | grep -c "${q}paquets$q:1")" "1"
# L utilisateur installe ses mises a jour : apt n a plus rien a proposer, et le systeme
# demande un redemarrage.
faux apt-get 0 ""
: > "$TMP/reboot-required"
# Le cache tel quel : il mentirait sur les paquets...
eq "le cache garde son compte de paquets" "$(runsys cmd_sys_json | grep -c "${q}paquets$q:1")" "1"
# ...mais PAS sur le redemarrage, qui est un simple test de fichier et ne coute rien.
eq "le redemarrage, lui, est toujours frais" "$(runsys cmd_sys_json | grep -c "${q}reboot$q:true")" "1"
# Et « --local » refait toute la moitie locale : c est ce que la fenetre du panneau demande.
SL1=$(runsys cmd_sys_json --local)
eq "--local voit les paquets installes" "$(printf '%s' "$SL1" | grep -c "${q}paquets$q:0")" "1"
eq "--local voit le redemarrage demande" "$(printf '%s' "$SL1" | grep -c "${q}reboot$q:true")" "1"
# ...et il ne touche PAS au reseau : la moitie distante reste celle du cache. Le depot
# annonce maintenant 1.0.0, donc un appel reel aurait change maj_version.
faux_curl 1.0.0
eq "--local garde la moitie distante en cache" \
   "$(runsys cmd_sys_json --local | grep -c "${q}maj_version$q:${q}9[.]9[.]9$q")" "1"
# La preuve directe : sans curl du tout, « --local » doit quand meme rendre un relevé
# complet. S il interrogeait le depot, la version annoncee tomberait a vide.
sans curl
eq "--local n a pas besoin de curl" \
   "$(runsys cmd_sys_json --local | grep -c "${q}maj_version$q:${q}9[.]9[.]9$q")" "1"
faux_curl 1.0.0
# --rafraichir, lui, reinterroge bien.
eq "--rafraichir reinterroge le depot" \
   "$(runsys cmd_sys_json --rafraichir | grep -c "${q}maj_version$q:${q}1[.]0[.]0$q")" "1"
# Le redemarrage repart quand le fichier disparait (un vrai redemarrage l efface).
rm -f "$TMP/reboot-required"
eq "apres le redemarrage, plus de demande" "$(runsys cmd_sys_json --local | grep -c "${q}reboot$q:false")" "1"
eq "et le cache ne la ressuscite pas" "$(runsys cmd_sys_json | grep -c "${q}reboot$q:false")" "1"
# Le verbe que la route du panneau appelle. Ce qui compte n est pas sa forme mais ce qu il
# RAFRAICHIT : c est lui que /api/systeme appelle, et le remplacer par un « cmd_sys_json »
# nu rendrait au panneau le cache perime — le defaut meme que l utilisateur a signale.
: > "$TMP/reboot-required"
faux apt-get 0 "Inst libc6 [2.36-9] (2.36-9+deb12u7 Debian-Security:12/stable [armhf])"
rm -f "$TMP/run/systeme.json"
runsys cmd_sys_json >/dev/null          # un cache frais, avec un paquet en attente
faux apt-get 0 ""                       # l utilisateur installe ses mises a jour
# Le cache d abord, car « --local » le REECRIT : interroge apres, il rendrait la valeur
# fraiche et la comparaison ne dirait plus rien.
eq "le relevé en cache les annonce encore" "$(runsys cmd_sys_json | grep -c "${q}paquets$q:1")" "1"
eq "sys-local, lui, voit les paquets installes" "$(runsys cmd_sys_local | grep -c "${q}paquets$q:0")" "1"
eq "sys-local rend du JSON" "$(runsys cmd_sys_local | cut -c1)" "{"
eq "sys-local rend 0" "$(runsysok cmd_sys_local)" oui
rm -f "$TMP/reboot-required"
faux apt-get 0 "Inst libc6 [2.36-9] (2.36-9+deb12u7 Debian-Security:12/stable [armhf])"
faux_curl 9.9.9

# Il ne doit jamais echouer, meme quand toutes les sondes echouent.
sans dpkg-query; sans apt-config; sans apt-get; sans systemctl; sans curl
eq "le releve rend toujours 0" "$(runsysok cmd_sys_json)" oui
eq "le rafraichissement aussi" "$(runsysok cmd_sys_json --rafraichir)" oui
eq "et le releve local aussi" "$(runsysok cmd_sys_json --local)" oui
eq "toutes sondes muettes : du JSON local quand meme" "$(runsys cmd_sys_json --local | cut -c1)" "{"
eq "toutes sondes muettes : du JSON quand meme" "$(runsys cmd_sys_json --rafraichir | cut -c1)" "{"
eq "update-check ne dit rien" "$(runsys cmd_update_check)" ""

echo
echo "-- group leave verifie avant de confirmer"
# « join » verifie l appareil ET le groupe ; « leave » ne verifiait RIEN. Une faute de
# frappe reecrivait un fichier identique et annoncait quand meme le retrait — puis
# reappliquait en mode « modifie », ce qui EFFACE la validation humaine et rearme
# l annulation de deux minutes : faute de reponse, tout le cloisonnement retombait.
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|conf|Confiance"; echo "MEMBER|telephone|conf"; } > "$ACC"
eq "un appareil inconnu est refuse" "$(runok cmd_group leave fantome conf)" non
eq "et le refus le nomme" "$(run cmd_group leave fantome conf | grep -c 'fantome')" "1"
eq "un groupe inconnu est refuse" "$(runok cmd_group leave telephone absent)" non
# Un retrait qui n a rien a retirer le DIT, et ne touche a rien.
eq "un retrait sans objet le dit" "$(run cmd_group leave pc-salon conf | grep -c 'ne fait déjà pas partie')" "1"
eq "et il ne pretend pas avoir retire" "$(run cmd_group leave pc-salon conf | grep -c 'ne fait plus partie')" "0"
eq "il rend 0 quand meme" "$(runok cmd_group leave pc-salon conf)" oui
eq "et il ne touche pas au fichier" "$(rows | grep -c '^MEMBER')" "1"
# Le vrai retrait, lui, marche.
eq "un vrai retrait est accepte" "$(runok cmd_group leave telephone conf)" oui
eq "et il retire" "$(rows | grep -c '^MEMBER')" "0"

echo "-- le panneau applique le pare-feu UNE seule fois"
# appliquer_acces, cote Python, applique lui-meme une seule fois pour tout un lot : sa
# docstring explique pourquoi (« le second instantane ne contiendrait plus l etat d avant,
# mais l etat intermediaire »). Depuis que la CLI applique apres chaque ecriture, une
# regle posee depuis le navigateur etait appliquee DEUX fois, et l instantane de secours
# pris APRES que la regle etait en vigueur.
{ echo "V|1"; echo "MODE|filtre"; echo "GROUP|g|G"; echo "MEMBER|telephone|g"; } > "$ACC"
eq "sans le drapeau, la CLI applique" "$(trace cmd_access allow g internet)" "applique --modifie"
tracesans() { ( export WGPI_SANS_APPLY=1; trace "$@" ); }
{ echo "V|1"; echo "MODE|filtre"; echo "GROUP|g|G"; echo "MEMBER|telephone|g"; } > "$ACC"
eq "avec le drapeau, elle laisse la main au panneau" "$(tracesans cmd_access allow g internet)" ""
# Mais elle ECRIT quand meme : c est seulement l application qui est deleguee.
eq "et la regle est bien enregistree" "$(rows | grep -c '^POLICY')" "1"

echo "-- upnp off ne supprime plus la redirection"
# « off » veut dire « ne la renouvelle plus tout seul », pas « coupe le VPN maintenant ».
# La branche faisait « upnpc -d », qui SUPPRIME la redirection : la commande censee rendre
# la main coupait l acces depuis l exterieur, sans le dire, et le README promet l inverse.
faux upnpc 0 "ok"
MOUCHARD_UPNP=$TMP/upnpc-appels
{ echo "#!/bin/sh"; echo "echo \"\$*\" >> \"$MOUCHARD_UPNP\""; echo "exit 0"; } > "$SBIN/upnpc"
chmod +x "$SBIN/upnpc"
: > "$MOUCHARD_UPNP"
# $SBIN en TETE du PATH reel, et non a la place : cmd_upnp passe par take_lock, donc par
# flock, qui n est pas dans la liste des faux outils. Le confiner entierement faisait mourir
# la commande avant d atteindre le code teste, et l assertion passait pour cette raison.
upnpoff() { ( source "$SRC"; TTY=""; AUTO=1; PATH=$SBIN:$PATH; cmd_upnp off ) 2>&1; }
# L ouverture doit etre DECLAREE automatique, sinon la commande sort sur « deja manuelle »
# et ne touche jamais au code teste.
sed -i "s/^UPNP=.*/UPNP=1/" "$TMP/etc/settings.conf"
SORTIE_UPNP=$(upnpoff)
eq "aucune suppression de redirection" "$(grep -c -- ' -d ' "$MOUCHARD_UPNP" 2>/dev/null; :)" "0"
eq "et le message le dit" "$(printf '%s' "$SORTIE_UPNP" | grep -c 'pas touchée')" "1"
eq "il annonce la desactivation" "$(printf '%s' "$SORTIE_UPNP" | grep -c 'Ouverture automatique désactivée')" "1"
eq "et le reglage est enregistre" "$(grep -c '^UPNP=0' "$TMP/etc/settings.conf")" "1"
sans upnpc

echo "-- une regle desactivee ne doit pas passer pour un acces"
# Le champ « actif » etait lu et jamais teste : une regle desactivee s affichait exactement
# comme un acces autorise. Le moteur, lui, ne la pose pas — l ecran annoncait donc un acces
# qui n existe pas.
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|g|Salon"; echo "MEMBER|telephone|g"
  echo "POLICY|p1|1|grp:g|internet|any||aller|Internet"
  echo "POLICY|p2|0|grp:g|maison|any||aller|La maison, desactivee"; } > "$ACC"
eq "la regle desactivee est marquee" "$(run access_show | grep -c 'DÉSACTIVÉE')" "1"
eq "et l active ne l est pas" "$(run access_show | grep -c 'Internet.*DÉSACTIVÉE')" "0"
eq "le moteur ne la pose pas" "$(run access_rules_plan B 1 | grep -c 'wgpi:pol:p2')" "0"

echo "-- supprimer un appareil emporte ses appartenances"
# access_save purge les references mortes, mais seulement a la PROCHAINE ecriture
# d acces : d ici la la ligne MEMBER survit, et « wg-pi add » sous le meme nom — un nom
# que l utilisateur choisit, donc qu il reemploie — rendait au nouvel appareil TOUS les
# acces de l ancien, sans un mot.
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|conf|Confiance"; echo "MEMBER|telephone|conf"
  echo "MEMBER|pc-salon|conf"; } > "$ACC"
eq "deux appartenances au depart" "$(rows | grep -c '^MEMBER')" "2"
silent cmd_remove telephone --yes
eq "celle de l appareil supprime est partie" "$(rows | grep -c '^MEMBER|telephone|')" "0"
eq "celle de l autre est intacte" "$(rows | grep -c '^MEMBER|pc-salon|')" "1"
eq "et le groupe existe toujours" "$(rows | grep -c '^GROUP|conf|')" "1"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
