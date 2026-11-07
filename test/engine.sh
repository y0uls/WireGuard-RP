#!/usr/bin/env bash
# Tests du générateur de règles (access_rules_plan).
#
# C'est une fonction pure : elle écrit le texte du plan, elle ne touche jamais au noyau.
# Toute la correction du moteur est donc vérifiable ici, sans root, sans iptables et sans
# Raspberry Pi. Ce qui reste non vérifié est l'application réelle des règles.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./engine.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
mkdir -p "$TMP/etc" "$TMP/wg"
echo "Port 2222" > "$TMP/sshd_config"

sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" \
    -e "s|^readonly WG_DIR=.*|readonly WG_DIR='$TMP/wg'|" \
    -e "s|^readonly LOCK_FILE=.*|readonly LOCK_FILE='$TMP/lock'|" \
    -e "s|^readonly LOG_FILE=.*|readonly LOG_FILE='$TMP/log'|" \
    -e "s|^readonly SSHD_CONFIG=.*|readonly SSHD_CONFIG='$TMP/sshd_config'|" \
    "$SCRIPT" > "$TMP/full.sh"
grep -q "SSHD_CONFIG='$TMP/sshd_config'" "$TMP/full.sh" || { echo "Redirection SSHD_CONFIG echouee" >&2; exit 2; }
if [[ $(tail -n1 "$TMP/full.sh") == 'main "$@"' ]]; then
  head -n -1 "$TMP/full.sh" > "$SRC"
else
  cp "$TMP/full.sh" "$SRC"
fi

cat > "$TMP/wg/wg0.conf" <<'WGC'
[Interface]
Address = 10.8.0.1/24

### Client: telephone
[Peer]
PublicKey = KEY1
AllowedIPs = 10.8.0.2/32

### Client: pc-salon
[Peer]
PublicKey = KEY2
AllowedIPs = 10.8.0.3/32

### Client: tablette-amis
[Peer]
PublicKey = KEY3
AllowedIPs = 10.8.0.4/32
WGC

cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|confiance|Appareils de confiance
GROUP|invites|Invites
RES|nas|NAS|192.168.1.20
MEMBER|telephone|confiance
MEMBER|pc-salon|confiance
MEMBER|tablette-amis|invites
POLICY|p1|1|grp:confiance|res:nas|tcp|445,5000-5001|aller|Partages du NAS
POLICY|p2|1|grp:invites|internet|any||aller|Invites : Internet seulement
POLICY|p3|1|grp:confiance|internet|any||aller|Confiance : Internet
POLICY|p4|1|grp:confiance|maison|any||aller|Confiance : la maison
POLICY|p5|1|grp:confiance|grp:confiance|any||deux|Mes appareils se voient
POLICY|p6|1|grp:confiance|pi|tcp|443|aller|Panneau web
POLICY|p7|0|grp:invites|res:nas|any||aller|Desactivee : ne doit rien produire
ACC

LAN=192.168.1.0/24
# Les reseaux locaux du Pi sont STUBES : les lire par « ip » ferait dependre le plan des
# interfaces de la machine qui lance les tests. Deux reseaux au lieu d un, dont un pont
# Docker : c est precisement la configuration que « internet » laissait joignable.
DOCKER=172.18.0.0/16
plan() { ( source "$SRC"; LAN_IF=eth0; LAN_NET="$LAN"; WG_PORT=51820
           access_local_nets() { echo "$LAN"; echo "$DOCKER"; }
           access_rules_plan "${1:-B}" "${2:-1}" ); }

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
# « eq » etait appele sans etre defini : la ligne sortait en « command not found » et son
# assertion ne comptait ni comme reussie ni comme echouee. Un test muet est pire qu absent.
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi; }
has() { if grep -qF -- "$2" "$TMP/plan"; then ok "$1"; else ko "$1"; echo "       absent : $2"; fi; }
hasnt() { if grep -qF -- "$2" "$TMP/plan"; then ko "$1"; echo "       present a tort : $2"; else ok "$1"; fi; }
cnt() { local n; n=$(grep -cF -- "$3" "$TMP/plan"); if [[ $n == "$2" ]]; then ok "$1"; else ko "$1 (compte $n, attendu $2)"; fi; }
# Numero de la premiere ligne contenant le motif, 0 si absent.
at() { grep -nF -- "$1" "$TMP/plan" | head -n1 | cut -d: -f1; }
before() { local a b; a=$(at "$2"); b=$(at "$3"); if [[ -n $a && -n $b ]] && (( a < b )); then ok "$1"; else ko "$1 (ligne $a vs $b)"; fi; }

plan B 1 > "$TMP/plan"
echo "-- invariant : aucun argument ne contient d espace superflu"
# Chaque ligne doit etre decoupable par mots sans quoting : aucun guillemet, aucune
# apostrophe, aucun caractere de controle.
if grep -q "[\"']" "$TMP/plan"; then
  ko "des guillemets subsistent dans le plan"
  grep -n "[\"']" "$TMP/plan" | head -3
else
  ok "aucun guillemet dans le plan"
fi

echo "-- creation des chaines"
has "chaine d entree FORWARD"        "-N WGPI-FWD-B"
has "chaine INPUT"                   "-N WGPI-IN-B"
has "chaine de refus"                "-N WGPI-DENY-B"
has "chaine du groupe confiance"     "-N WGPI-S-confiance-B"
has "chaine du groupe invites"       "-N WGPI-S-invites-B"
has "chaine du groupe automatique"   "-N WGPI-S-tous-B"

echo "-- chaine de refus : REJECT et non DROP"
has "journal limite en debit"        "-A WGPI-DENY-B -m limit --limit 2/min --limit-burst 5 -j LOG --log-prefix wg-pi-refus:"
has "refus TCP immediat"             "-A WGPI-DENY-B -p tcp -j REJECT --reject-with tcp-reset"
has "refus generique"                "-A WGPI-DENY-B -j REJECT --reject-with icmp-admin-prohibited"
hasnt "aucun DROP silencieux"        "-j DROP"

echo "-- chaine d entree FORWARD"
has "retour des flux pair-a-pair"    "-A WGPI-FWD-B -m conntrack --ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT"
has "aiguillage de telephone"        "-A WGPI-FWD-B -s 10.8.0.2 -m comment --comment wgpi:dev:telephone -j WGPI-S-confiance-B"
has "telephone passe aussi par tous" "-A WGPI-FWD-B -s 10.8.0.2 -m comment --comment wgpi:dev:telephone -j WGPI-S-tous-B"
has "aiguillage de tablette-amis"    "-A WGPI-FWD-B -s 10.8.0.4 -m comment --comment wgpi:dev:tablette-amis -j WGPI-S-invites-B"
has "refus en dernier recours"       "-A WGPI-FWD-B -j WGPI-DENY-B"
before "le retour est teste avant les aiguillages" "--ctdir REPLY" "-s 10.8.0.2"
before "le refus vient apres les aiguillages" "-s 10.8.0.4" "-A WGPI-FWD-B -j WGPI-DENY-B"

echo "-- traduction des destinations"
# L interface de sortie n est contrainte que la ou c est necessaire. Observe sur un vrai
# noyau : une ressource joignable autrement que par l interface de la box recevait une
# regle qui ne pouvait jamais correspondre.
has "internet exclut le tunnel"               "-A WGPI-S-invites-B ! -o wg0"
hasnt "et n exclut plus la maison a la main"   "! -d 192.168.1.0/24"
has "maison cible le reseau, sans contrainte d interface" "-A WGPI-S-confiance-B -d 192.168.1.0/24"
has "ressource ciblee par sa seule adresse"   "-A WGPI-S-confiance-B -d 192.168.1.20"
hasnt "aucune contrainte -o eth0"             "-o eth0"
has "groupe : une regle par appareil destinataire" "-A WGPI-S-confiance-B -o wg0 -d 10.8.0.2"
has "groupe : le second appareil aussi"            "-A WGPI-S-confiance-B -o wg0 -d 10.8.0.3"

echo "-- internet : les reseaux locaux du Pi sont ecartes dans WGPI-INET"
# Une seule option « ! -d » ne peut nommer qu un reseau. Le Pi en a souvent plusieurs :
# ponts Docker, seconde carte, VLAN. Ils sont donc ecartes dans une chaine a part.
has "la chaine existe"                      "-N WGPI-INET-B"
has "internet y saute"                      "-m comment --comment wgpi:pol:p2 -j WGPI-INET-B"
has "la maison est ecartee"                 "-A WGPI-INET-B -d 192.168.1.0/24 -m comment --comment wgpi:local -j RETURN"
has "le pont Docker aussi"                  "-A WGPI-INET-B -d 172.18.0.0/16 -m comment --comment wgpi:local -j RETURN"
has "et le reste passe"                     "-A WGPI-INET-B -j ACCEPT"
# RETURN et non REJECT : on revient dans la chaine du groupe, ou une regle « maison » ou
# « ressource » plus bas peut encore autoriser cette destination. Un refus ici retirerait
# au groupe des acces qu il a par ailleurs.
hasnt "aucun refus dans la chaine internet"  "-A WGPI-INET-B -j REJECT"
before "les reseaux locaux sont ecartes AVANT l acceptation" "wgpi:local" "-A WGPI-INET-B -j ACCEPT"
# Le groupe « confiance » a internet ET la maison : la maison doit rester joignable, donc
# la regle « maison » est toujours la, APRES le saut vers la chaine internet.
before "internet est teste avant la maison" "wgpi:pol:p3" "wgpi:pol:p4"

echo "-- protocoles et ports"
# La plage s ecrit avec un tiret cote utilisateur et deux-points cote iptables.
has "plage convertie en deux-points" "-p tcp -m multiport --dports 445,5000:5001"
hasnt "aucun tiret residuel dans les ports" "--dports 445,5000-5001"
has "protocole any sans port : aucun -p" "-A WGPI-S-invites-B ! -o wg0  -m comment --comment wgpi:pol:p2 -j WGPI-INET-B"

echo "-- ordre des regles : le trafic de masse en premier"
before "internet avant la maison"    "wgpi:pol:p3" "wgpi:pol:p4"
before "la maison avant le pair-a-pair" "wgpi:pol:p4" "wgpi:pol:p5"

echo "-- regles desactivees"
hasnt "une regle inactive ne produit rien" "wgpi:pol:p7"

echo "-- sens deux : le miroir est emis"
has "miroir du pair-a-pair"          "wgpi:pol:p5:retour"

echo "-- chaine INPUT : le garde-fou SSH d abord, RETURN a la fin"
# Le port attendu est celui que la fonction detecte, et non une valeur ecrite en dur :
# « sshd -T » est essaye en premier, donc sur une machine ou sshd tourne vraiment le port
# retenu peut differer du fichier de configuration simule.
# SSHD_CONFIG est deja redirige par le sed en tete de ce fichier, et il est « readonly » :
# le reassigner ferait sortir le sous-shell en erreur, et le port ressortirait vide.
PORT_SSH=$( ( source "$SRC"; access_ssh_ports ) 2>/dev/null | head -n1 )
eq "un port SSH est determine" "$([[ -n ${PORT_SSH:-} ]] && echo oui || echo non)" "oui"
has "SSH accepte inconditionnellement" "-A WGPI-IN-B -p tcp --dport $PORT_SSH -m comment --comment wgpi:secours:ssh -j ACCEPT"
has "le port du VPN reste joignable"   "-A WGPI-IN-B -p udp --dport 51820 -m comment --comment wgpi:secours:vpn -j ACCEPT"
has "le ping du Pi reste possible"     "-A WGPI-IN-B -p icmp -m comment --comment wgpi:secours:ping -j ACCEPT"
has "la regle pi va bien dans INPUT"   "-A WGPI-IN-B -s 10.8.0.2 -p tcp -m multiport --dports 443 -m comment --comment wgpi:pol:p6 -j ACCEPT"
before "SSH avant toute politique"     "wgpi:secours:ssh" "wgpi:pol:p6"
# Un ACCEPT terminal en INPUT court-circuiterait UFW et exposerait tous les services du
# Pi, conteneurs Docker publies sur 0.0.0.0 compris, a tous les appareils du VPN.
if [[ $(grep -c '^-A WGPI-IN-B' "$TMP/plan") -gt 0 ]] && [[ $(grep '^-A WGPI-IN-B' "$TMP/plan" | tail -n1) == "-A WGPI-IN-B -j RETURN" ]]; then
  ok "la chaine INPUT se termine par RETURN"
else
  ko "la chaine INPUT ne se termine pas par RETURN"
  grep '^-A WGPI-IN-B' "$TMP/plan" | tail -n1
fi
hasnt "aucun ACCEPT terminal en INPUT" "-A WGPI-IN-B -j ACCEPT"

echo "-- destination pi : jamais dans FORWARD"
if grep '^-A WGPI-S-' "$TMP/plan" | grep -q 'wgpi:pol:p6'; then
  ko "la regle vers le Pi a fuite dans une chaine FORWARD"
else
  ok "la regle vers le Pi reste hors de FORWARD"
fi

echo "-- repli sans --ctdir"
plan B 0 > "$TMP/plan"
has "repli conntrack sans ctdir"     "-A WGPI-FWD-B -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
hasnt "plus de --ctdir"              "--ctdir"

echo "-- double tampon : les noms de chaines changent"
plan A 1 > "$TMP/plan"
has "tampon A"                       "-N WGPI-FWD-A"
hasnt "aucune chaine du tampon B"    "WGPI-FWD-B"
# Limite de 28 caracteres des noms de chaines iptables.
LONG=$(grep -oE 'WGPI-[A-Za-z0-9_-]+' "$TMP/plan" | sort -u | awk '{ if (length($0) > 28) print }')
if [[ -z $LONG ]]; then ok "tous les noms de chaines tiennent en 28 caracteres"; else ko "noms trop longs : $LONG"; fi

echo "-- destination tout"
# Donner tous les droits a un groupe d administration demandait quatre regles — internet,
# maison, pi, et une par groupe — qu il aurait fallu completer a chaque nouveau groupe.
# « tout » les remplace par une seule, qui ne contraint ni la destination ni l interface.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|admin|Administration
GROUP|invites|Invites
MEMBER|telephone|admin
MEMBER|tablette-amis|invites
POLICY|t1|1|grp:admin|tout|any||aller|Administration : tout
POLICY|t2|1|grp:invites|maison|any||aller|Invites : la maison
ACC
plan B 1 > "$TMP/plan"
has "tout : aucune contrainte de destination" "-A WGPI-S-admin-B -d 0.0.0.0/0"
hasnt "tout : aucune contrainte d interface"  "-A WGPI-S-admin-B -o wg0"
hasnt "tout : aucune exclusion"               "-A WGPI-S-admin-B !"
# « Tout » doit inclure le Pi lui-meme : SSH et le panneau web sont la premiere chose
# que l on verifie, et les trouver fermes ferait mentir le mot.
has "tout ouvre aussi le Pi"                  "-A WGPI-IN-B -s 10.8.0.2"
# Le trafic de masse en premier : la regle large doit preceder les regles etroites.
before "tout precede les regles plus precises" "-d 0.0.0.0/0" "-A WGPI-S-invites-B -d 192.168.1.0/24"
# Et il ne deborde pas sur les autres groupes.
hasnt "les invites ne recoivent pas tout"     "-A WGPI-S-invites-B -d 0.0.0.0/0"

echo
echo "-- une seule regle, les deux protocoles"
# Une ligne iptables ne porte qu un protocole. « tcpudp » en pose donc DEUX, sous le MEME
# identifiant de regle : sans cela il faudrait tenir deux regles jumelles a jour en
# parallele, ce qui est la facon la plus sure de les voir diverger.
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|jeu|Jeu"
  echo "MEMBER|telephone|jeu"
  echo "RES|nas|Le NAS|192.168.1.20"
  echo "POLICY|p1|1|grp:jeu|res:nas|tcpudp|27015,27036|aller|Jeu en reseau"
  echo "POLICY|p2|1|grp:jeu|pi|tcpudp|8080|aller|Vers le Pi"
  echo "POLICY|p3|1|grp:jeu|grp:jeu|tcpudp|7777|deux|Entre eux"
} > "$TMP/etc/access.conf"
plan B 1 > "$TMP/plan"

# Dans la chaine du groupe : deux lignes, une par protocole, meme identifiant de regle.
cnt "la regle pose deux lignes" "2" "wgpi:pol:p1"
has "une ligne TCP"  "-p tcp -m multiport --dports 27015,27036"
has "une ligne UDP"  "-p udp -m multiport --dports 27015,27036"
# Et jamais le mot lui-meme : iptables ne connait pas de protocole « tcpudp ».
hasnt "aucun protocole invente ne sort du moteur" "-p tcpudp"

# Dans la chaine INPUT, ou les regles qui visent le Pi sont traitees a part.
cnt "le Pi recoit aussi les deux" "2" "wgpi:pol:p2"

# Et dans le sens retour, ou un acces entre groupes pose son miroir.
cnt "le sens retour aussi" "2" "wgpi:pol:p3:retour"

# Les protocoles existants ne doivent surtout pas avoir change de comportement : « any »
# sans ports ne contraint RIEN, et faire boucler l appelant sur une sortie vide aurait
# fait disparaitre la regle au lieu de la poser sans contrainte.
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|jeu|Jeu"
  echo "MEMBER|telephone|jeu"
  echo "POLICY|p1|1|grp:jeu|maison|any||aller|Tout vers la maison"
  echo "POLICY|p2|1|grp:jeu|internet|tcp|443|aller|Le web"
  echo "POLICY|p3|1|grp:jeu|maison|icmp||aller|Le ping"
} > "$TMP/etc/access.conf"
plan B 1 > "$TMP/plan"
cnt "any sans ports pose toujours une ligne" "1" "wgpi:pol:p1"
cnt "tcp pose toujours une ligne" "1" "wgpi:pol:p2"
has "et garde ses ports" "-p tcp -m multiport --dports 443"
cnt "icmp pose toujours une ligne" "1" "wgpi:pol:p3"
has "et reste de l icmp" "-p icmp"

echo
echo "-- internet : la chaine suit la liste des reseaux locaux"
# Un Pi sans Docker ni seconde carte ne doit pas payer de regle inutile, et un Pi qui en a
# dix doit toutes les voir. La chaine est donc une fonction de la liste, pas une constante.
{
  echo "V|1"
  echo "MODE|filtre"
  echo "GROUP|invites|Invites"
  echo "MEMBER|telephone|invites"
  echo "POLICY|p1|1|grp:invites|internet|any||aller|Internet seulement"
} > "$TMP/etc/access.conf"
( source "$SRC"; LAN_IF=eth0; LAN_NET="$LAN"; WG_PORT=51820
  access_local_nets() { echo "$LAN"; }
  access_rules_plan B 1 ) > "$TMP/plan"
cnt "un seul reseau local : un seul RETURN" "1" "wgpi:local"
hasnt "et pas de pont Docker invente" "172.18.0.0/16"
( source "$SRC"; LAN_IF=eth0; LAN_NET="$LAN"; WG_PORT=51820
  access_local_nets() { echo "$LAN"; echo 172.17.0.0/16; echo 172.18.0.0/16; echo 10.10.0.0/16; }
  access_rules_plan B 1 ) > "$TMP/plan"
cnt "quatre reseaux locaux : quatre RETURN" "4" "wgpi:local"
has "le VLAN est ecarte lui aussi" "-A WGPI-INET-B -d 10.10.0.0/16 -m comment --comment wgpi:local -j RETURN"
# Sans aucun reseau local connu, « internet » resterait un ACCEPT nu : la chaine doit
# quand meme exister, sinon le saut emis designerait une chaine absente et iptables
# refuserait TOUT le plan.
( source "$SRC"; LAN_IF=eth0; LAN_NET="$LAN"; WG_PORT=51820
  access_local_nets() { :; }
  access_rules_plan B 1 ) > "$TMP/plan"
has "la chaine existe meme sans reseau local" "-N WGPI-INET-B"
cnt "et elle ne porte alors aucun RETURN" "0" "wgpi:local"
has "mais toujours son acceptation" "-A WGPI-INET-B -j ACCEPT"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
