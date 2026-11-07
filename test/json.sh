#!/usr/bin/env bash
# Tests de la sortie JSON de « wg-pi json », qui alimente le panneau web.
#
# Le JSON est validé par python3, pas par inspection visuelle : un libellé contenant un
# guillemet rendrait /api/state invalide, donc le panneau entier blanc — et pas seulement
# la vue concernée.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./json.sh [chemin/vers/wg-pi.sh]
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
    -e "s|^readonly REBOOT_FILE=.*|readonly REBOOT_FILE='$TMP/reboot-required'|" \
    "$SCRIPT" > "$TMP/full.sh"
head -n -1 "$TMP/full.sh" > "$SRC"

cat > "$TMP/etc/settings.conf" <<'SET'
WG_PORT=51820
WG_NET4=10.8.0
WG_NET6=fd00:1234:5678::
IPV6_ON=1
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

### Client: telephone
[Peer]
PublicKey = KEY1
AllowedIPs = 10.8.0.2/32

### Client: tablette
[Peer]
PublicKey = KEY2
AllowedIPs = 10.8.0.3/32
WGC

DQ=$(awk 'BEGIN{ printf "%c", 34 }')
BS=$(awk 'BEGIN{ printf "%c", 92 }')

# Des libelles volontairement hostiles : guillemets, backslash, accents, chevrons.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|confiance|Appareils ${DQ}de confiance${DQ}"
  echo "GROUP|invites|Invites C:${BS}partage"
  echo "RES|nas|NAS ${DQ}maison${DQ}|192.168.1.20"
  echo "MEMBER|telephone|confiance"
  echo "MEMBER|tablette|invites"
  echo "POLICY|p1|1|grp:confiance|res:nas|tcp|445,5000-5001|aller|Partages du NAS"
  echo "POLICY|p2|1|grp:invites|internet|any||aller|Invites ${DQ}Internet seulement${DQ}"
  echo "POLICY|p3|0|grp:tous|pi|tcp|443|aller|Desactivee"
} > "$TMP/etc/access.conf"

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi
}

( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>"$TMP/err" || true

echo "-- validite du document"
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/out.json" 2>"$TMP/jerr"; then
  ok "le JSON est valide malgré des libellés hostiles"
else
  ko "JSON invalide : $(cat "$TMP/jerr")"
  head -c 400 "$TMP/out.json"
  echo
  echo "  (stderr de la commande : $(head -c 200 "$TMP/err"))"
fi

# Interroge le document avec une expression python ; rend une chaine vide en cas d erreur.
q() { python3 -c "
import json, sys
d = json.load(open('$TMP/out.json'))
try:
    v = eval(sys.argv[1], {}, {'d': d})
except Exception:
    v = ''
print('' if v is None else v, end='')
" "$1" 2>/dev/null; }

echo "-- les libellés traversent intacts"
eq "guillemets dans un libellé de groupe" \
   "$(q "[g['libelle'] for g in d['acces']['groupes'] if g['id']=='confiance'][0]")" \
   "Appareils \"de confiance\""
eq "backslash dans un libellé" \
   "$(q "[g['libelle'] for g in d['acces']['groupes'] if g['id']=='invites'][0]")" \
   "Invites C:\partage"
eq "guillemets dans un libellé de ressource" \
   "$(q "d['acces']['ressources'][0]['libelle']")" \
   "NAS \"maison\""
eq "guillemets dans un titre de règle" \
   "$(q "[f['titre'] for g in d['acces']['groupes'] for f in g['flux'] if f['id']=='p2'][0]")" \
   "Invites \"Internet seulement\""

echo "-- structure de la vue d accès"
eq "mode publié"                  "$(q "d['acces']['mode']")" "ouvert"
# « inconnu » et surtout pas « inactif » quand le noyau n est pas interrogeable : affirmer
# une absence de filtrage non vérifiée serait un mensonge.
eq "état du noyau non vérifiable" "$(q "d['acces']['noyau']")" "inconnu"
eq "trois groupes dont le virtuel" "$(q "len(d['acces']['groupes'])")" "3"
eq "le groupe automatique est marqué" \
   "$(q "[g['auto'] for g in d['acces']['groupes'] if g['id']=='tous'][0]")" "True"
eq "appareils du groupe confiance"  "$(q "[g['appareils'] for g in d['acces']['groupes'] if g['id']=='confiance'][0][0]")" "telephone"
eq "le groupe automatique contient tout le monde" \
   "$(q "len([g for g in d['acces']['groupes'] if g['id']=='tous'][0]['appareils'])")" "2"

echo "-- les règles résolues"
eq "destination résolue en libellé lisible" \
   "$(q "[f['label'] for g in d['acces']['groupes'] for f in g['flux'] if f['id']=='p1'][0]")" \
   "NAS \"maison\" (192.168.1.20)"
eq "ports conservés tels que saisis" \
   "$(q "[f['ports'] for g in d['acces']['groupes'] for f in g['flux'] if f['id']=='p1'][0]")" \
   "445,5000-5001"
# Une regle desactivee ne doit pas apparaitre : le panneau afficherait un acces qui n existe pas.
eq "une règle désactivée n apparaît pas" \
   "$(q "len([f for g in d['acces']['groupes'] for f in g['flux'] if f['id']=='p3'])")" "0"

echo "-- chaque appareil porte ses groupes"
eq "groupes de telephone" \
   "$(q "','.join(sorted([p['groupes'] for p in d['peers'] if p['name']=='telephone'][0]))")" \
   "confiance,tous"
eq "un appareil sans groupe nommé reste dans tous" \
   "$(q "','.join(sorted([p['groupes'] for p in d['peers'] if p['name']=='tablette'][0]))")" \
   "invites,tous"

echo
echo "-- l adresse MAC et les avertissements publies"
# Deux parties du document que rien ne verifiait. Le panneau lit « mac » pour afficher le
# reveil a distance, et « avertissements » pour la pastille « sans Internet ». Un champ
# decale dans la boucle des ressources mettrait le libelle a la place de la cible sans
# qu aucun test ne bronche, et le panneau afficherait une adresse qui n existe pas.
mkdir -p "$TMP/etc/clients"
# Un appareil qui envoie TOUT son trafic par le tunnel : c est la condition de
# l avertissement de contradiction.
{ echo "[Interface]"; echo "AllowedIPs = 0.0.0.0/0, ::/0"; } > "$TMP/etc/clients/telephone.conf"
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|adm|Administration"
  echo "MEMBER|telephone|adm"
  echo "RES|pcjeu|Le PC de jeu|192.168.1.18|aa:bb:cc:dd:ee:ff"
  echo "RES|nas|NAS ${DQ}maison${DQ}|192.168.1.20"
  echo "POLICY|p1|1|grp:adm|maison|any||aller|Vers la maison"
} > "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/out.json" 2>/dev/null; then
  ok "le JSON reste valide avec une MAC et un avertissement"
else
  ko "JSON invalide avec une MAC et un avertissement"
fi
# Chaque champ verifie SEPAREMENT : un decalage d un seul cran serait invisible si on ne
# comparait que le nombre de ressources.
eq "la ressource porte son identifiant"  "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}pcjeu${DQ}][0][${DQ}id${DQ}]")" "pcjeu"
eq "son libelle"                         "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}pcjeu${DQ}][0][${DQ}libelle${DQ}]")" "Le PC de jeu"
eq "sa cible"                            "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}pcjeu${DQ}][0][${DQ}cible${DQ}]")" "192.168.1.18"
eq "et son adresse MAC"                  "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}pcjeu${DQ}][0][${DQ}mac${DQ}]")" "aa:bb:cc:dd:ee:ff"
# Une ressource sans MAC publie une chaine VIDE, et non la cible du voisin ni un « null » :
# le panneau teste la verite du champ pour decider d afficher le reveil a distance.
eq "une ressource sans MAC publie une MAC vide" "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}nas${DQ}][0][${DQ}mac${DQ}]")" ""
eq "et garde sa propre cible"                   "$(q "[r for r in d[${DQ}acces${DQ}][${DQ}ressources${DQ}] if r[${DQ}id${DQ}]==${DQ}nas${DQ}][0][${DQ}cible${DQ}]")" "192.168.1.20"
# L avertissement : un appareil qui envoie tout par le tunnel dans un groupe sans Internet.
eq "un appareil contradictoire est signale" "$(q "len(d[${DQ}acces${DQ}][${DQ}avertissements${DQ}])")" "1"
eq "par son nom"                            "$(q "d[${DQ}acces${DQ}][${DQ}avertissements${DQ}][0][${DQ}appareil${DQ}]")" "telephone"
eq "et par le groupe en cause"              "$(q "d[${DQ}acces${DQ}][${DQ}avertissements${DQ}][0][${DQ}groupes${DQ}] != ${DQ}${DQ}")" "True"
# Et il se TAIT des que le groupe a Internet : sinon la pastille devient du bruit que
# personne ne lit plus.
{
  echo "V|1"; echo "MODE|filtre"; echo "GROUP|adm|Administration"
  echo "MEMBER|telephone|adm"
  echo "POLICY|p1|1|grp:adm|internet|any||aller|Internet"
} > "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "aucun avertissement quand le groupe a Internet" "$(q "len(d[${DQ}acces${DQ}][${DQ}avertissements${DQ}])")" "0"
# Hors filtrage non plus : rien n est encore applique, l avertissement serait premature.
{
  echo "V|1"; echo "MODE|ouvert"; echo "GROUP|adm|Administration"
  echo "MEMBER|telephone|adm"
  echo "POLICY|p1|1|grp:adm|maison|any||aller|Vers la maison"
} > "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "ni hors filtrage" "$(q "len(d[${DQ}acces${DQ}][${DQ}avertissements${DQ}])")" "0"
rm -rf "$TMP/etc/clients"

echo "-- un octet de controle dans un libelle ne doit pas vider la page"
# json_esc ne neutralisait que la tabulation et les fins de ligne. Un seul autre octet de
# controle rend le document invalide, « json.loads » leve cote panneau, et c est la page
# ENTIERE qui devient blanche — pour un caractere invisible. access_valid_label les refuse
# a la saisie, mais le README presente access.conf comme modifiable a la main.
CTRL=$(awk 'BEGIN{ printf "%c%c%c", 1, 11, 127 }')
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|g|Salon${CTRL}bis"; } > "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "le document reste valide" \
   "$(python3 -c "import json,sys; json.load(open(sys.argv[1])); print('oui')" "$TMP/out.json" 2>/dev/null)" "oui"
eq "et le libelle reste lisible" \
   "$(q "[g['libelle'] for g in d['acces']['groupes'] if g['id']=='g'][0]")" "Salon   bis"

echo "-- la cible d une ressource publiee au panneau"
# Trois lecteurs lisaient encore le champ brut : access_json, « resource list » et donc la
# tuile du panneau. Resultat sur un fichier migre : le libelle de la regle et le pare-feu
# disaient 192.168.7.0/24, la tuile disait 192.168.7.9/24 — une machine unique — et le
# panneau est la seule interface du public vise.
{
  echo "V|1"; echo "MODE|filtre"
  echo "RES|large|Tout le reseau|192.168.7.9/24"
  echo "RES|seule|Une machine|192.168.7.20"
} > "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "la cible publiee est celle du noyau" \
   "$(q "[r['cible'] for r in d['acces']['ressources'] if r['id']=='large'][0]")" "192.168.7.0/24"
eq "une cible saine sort telle quelle" \
   "$(q "[r['cible'] for r in d['acces']['ressources'] if r['id']=='seule'][0]")" "192.168.7.20"
eq "le document reste valide" \
   "$(python3 -c "import json,sys; json.load(open(sys.argv[1])); print('oui')" "$TMP/out.json" 2>/dev/null)" "oui"

echo "-- le redemarrage demande voyage avec l etat"
# Il ne se voyait que dans la fenetre « Mises a jour », qu il faut ouvrir expres, et qui
# servait de surcroit un cache de quinze minutes. Signale depuis l usage reel : deux mises
# a jour installees, le panneau continuait de les annoncer, et le redemarrage necessaire
# n etait dit nulle part. Ici c est un simple test de fichier, donc gratuit : il part avec
# l etat que le panneau releve toutes les deux secondes.
eq "sans le fichier : faux" "$(q "d['reboot']")" "False"
: > "$TMP/reboot-required"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "avec le fichier : vrai" "$(q "d['reboot']")" "True"
# Un booleen JSON, pas une chaine : le panneau teste la valeur directement.
eq "c est bien un booleen" "$(q "type(d['reboot']).__name__")" "bool"
eq "le document reste valide" "$(python3 -c "import json,sys; json.load(open(sys.argv[1])); print('oui')" "$TMP/out.json" 2>/dev/null)" "oui"
rm -f "$TMP/reboot-required"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
eq "le fichier retire : faux de nouveau" "$(q "d['reboot']")" "False"

echo "-- compatibilité : aucun fichier d accès"
rm -f "$TMP/etc/access.conf"
( source "$SRC"; cmd_json ) > "$TMP/out.json" 2>/dev/null || true
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/out.json" 2>/dev/null; then
  ok "le JSON reste valide sans fichier d accès"
else
  ko "JSON invalide sans fichier d accès"
fi
eq "mode ouvert par défaut"        "$(q "d['acces']['mode']")" "ouvert"
eq "seul le groupe automatique"    "$(q "len(d['acces']['groupes'])")" "1"
eq "aucune ressource"              "$(q "len(d['acces']['ressources'])")" "0"
eq "tout appareil est dans tous"   "$(q "[p['groupes'] for p in d['peers'] if p['name']=='telephone'][0][0]")" "tous"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
