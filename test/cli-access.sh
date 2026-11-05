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
    "$SCRIPT" > "$TMP/full.sh"
for marqueur in "STATE_DIR='$TMP/etc'" "WG_DIR='$TMP/wg'" "LOCK_FILE='$TMP/lock'"; do
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
eq "check signale une cible decalee par un libelle" \
   "$(run cmd_access check | grep -c "ni une adresse IP ni un réseau")" "1"
eq "check refuse alors de se declarer satisfait" "$(runok cmd_access check)" non

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
eq "suppression acceptee avec le filtrage actif" "$(runok cmd_access rm p1)" oui
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
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
