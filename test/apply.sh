#!/usr/bin/env bash
# Tests de l'applicateur : lecture de l'état dans le noyau, ordre de la bascule, démontage.
#
# iptables est remplacé par un faux exécutable qui journalise ses appels et dont on pilote
# les réponses. On vérifie donc la logique d'enchaînement — notamment « insérer le nouveau
# saut avant de retirer l'ancien » — sans aucun privilège et sans toucher au pare-feu.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./apply.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh BIN=$TMP/bin
mkdir -p "$TMP/etc" "$TMP/wg" "$BIN"
echo "Port 22" > "$TMP/sshd_config"

sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" \
    -e "s|^readonly WG_DIR=.*|readonly WG_DIR='$TMP/wg'|" \
    -e "s|^readonly LOCK_FILE=.*|readonly LOCK_FILE='$TMP/lock'|" \
    -e "s|^readonly LOG_FILE=.*|readonly LOG_FILE='$TMP/log'|" \
    -e "s|^readonly SSHD_CONFIG=.*|readonly SSHD_CONFIG='$TMP/sshd_config'|" \
    -e "s|^readonly ACCESS_SNAP=.*|readonly ACCESS_SNAP='$TMP/snap'|" \
    "$SCRIPT" > "$TMP/full.sh"
grep -q "ACCESS_SNAP='$TMP/snap'" "$TMP/full.sh" || { echo "Redirection ACCESS_SNAP echouee" >&2; exit 2; }
head -n -1 "$TMP/full.sh" > "$SRC"

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
DDNS=none
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
WGC

# --- faux iptables ----------------------------------------------------------
# Journalise chaque invocation. Pour « -C » il cherche la regle dans un fichier d etat,
# pour « -S » il rend un contenu fourni, et il echoue si ses arguments contiennent un
# motif place dans ipt.fail.
cat > "$BIN/iptables" <<'FAKE'
#!/bin/sh
log=$IPT_DIR/ipt.log
echo "$*" >> "$log"
# Echec provoque
if [ -s "$IPT_DIR/ipt.fail" ]; then
  while IFS= read -r motif; do
    [ -n "$motif" ] || continue
    case "$*" in *"$motif"*) exit 1 ;; esac
  done < "$IPT_DIR/ipt.fail"
fi
# On ignore le -w present en tete
args=$*
case "$args" in "-w "*) args=${args#-w } ;; esac
case "$args" in
  -C*)
    regle=${args#-C }
    [ -s "$IPT_DIR/ipt.exists" ] || exit 1
    grep -qxF -- "$regle" "$IPT_DIR/ipt.exists" || exit 1
    exit 0
    ;;
  -S)
    [ -r "$IPT_DIR/ipt.S" ] && cat "$IPT_DIR/ipt.S"
    exit 0
    ;;
  -S*)
    chaine=${args#-S }
    [ -r "$IPT_DIR/ipt.S.$chaine" ] && cat "$IPT_DIR/ipt.S.$chaine"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$BIN/iptables"
# systemd-run et systemctl sont absents du conteneur, et sans eux l application REFUSE de
# s appliquer (c est voulu). On les simule pour pouvoir tester le reste du chemin.
cat > "$BIN/systemd-run" <<'SDR'
#!/bin/sh
echo "systemd-run $*" >> "$IPT_DIR/ipt.log"
exit 0
SDR
cat > "$BIN/systemctl" <<'SCTL'
#!/bin/sh
echo "systemctl $*" >> "$IPT_DIR/ipt.log"
# « is-active » doit echouer : sinon access_ssh_ports croirait que sshd tourne et
# rendrait 22 par defaut, ce qui rendrait intestable le refus en cas de port inconnu.
case "$*" in *is-active*) exit 1 ;; esac
exit 0
SCTL
chmod +x "$BIN/systemd-run" "$BIN/systemctl"
# iptables-save doit rendre quelque chose : un instantane vide fait echouer la prise
# d instantane, et l application refuse alors d armer son filet de securite. Un Pi qui
# fonctionne rend toujours au moins les chaines par defaut.
cat > "$BIN/iptables-save" <<'SAVE'
#!/bin/sh
echo "save $*" >> "$IPT_DIR/ipt.log"
# Echec provoque, pour verifier le refus d armer un filet inexistant.
[ -f "$IPT_DIR/save.fail" ] && exit 1
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' ':FORWARD ACCEPT [0:0]' ':OUTPUT ACCEPT [0:0]' 'COMMIT'
SAVE
chmod +x "$BIN/iptables-save"
# ip6tables se NOMME dans le journal : sans cela ses appels seraient indistinguables de
# ceux d iptables, et aucune assertion ne pourrait porter sur la famille IPv6.
#
# Son « -C » ECHOUE toujours : aucune regle ip6 n est en place dans ce bac a sable, et
# repondre 0 ferait court-circuiter le « -I » qui suit — le code teste ne serait jamais
# atteint, et l assertion passerait pour la mauvaise raison.
{ echo "#!/bin/sh"
  echo 'echo "ip6tables $*" >> "$IPT_DIR/ipt.log"'
  echo 'case "$*" in *" -C "*) exit 1 ;; esac'
  echo "exit 0"
} > "$BIN/ip6tables"
chmod +x "$BIN/ip6tables"
cp "$BIN/iptables" "$BIN/iptables-restore"
export IPT_DIR=$TMP
export PATH="$BIN:$PATH"

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi
}
reset() { : > "$TMP/ipt.log"; : > "$TMP/ipt.exists"; : > "$TMP/ipt.fail"; rm -f "$TMP/ipt.S" "$TMP"/ipt.S.*; }
# access_local_nets est STUBEE : la lire par « ip » ferait dependre le garde-fou DNS et la
# chaine WGPI-INET des interfaces de la machine qui lance les tests. Deux reseaux locaux,
# dont un pont Docker — la configuration meme qui a revele le defaut.
load() { source "$SRC"; LAN_IF=eth0; LAN_IP=192.168.1.50; LAN_NET=192.168.1.0/24
         WG_PORT=51820; IPV6_NAT=0
         access_local_nets() { echo 192.168.1.0/24; echo 172.18.0.0/16; }; }
# Numero de la premiere ligne du journal contenant le motif, vide si absent.
at() { grep -nF -- "$1" "$TMP/ipt.log" | head -n1 | cut -d: -f1; }
before() {
  local a b
  a=$(at "$2"); b=$(at "$3")
  if [[ -n $a && -n $b ]] && (( a < b )); then ok "$1"; else ko "$1 (positions [$a] et [$b])"; fi
}

echo "-- tampons"
eq "l autre tampon de A est B" "$(load; access_other_buffer A)" "B"
eq "l autre tampon de B est A" "$(load; access_other_buffer B)" "A"

echo "-- lecture de l etat dans le noyau"
# « iptables -S FORWARD » commence par « -P FORWARD <politique> ». access_switch insere le
# saut du moteur en POSITION 1, donc devant le socle conntrack pose a l installation : le
# saut est en LIGNE 2 de la sortie, ce que access_jump_first teste par « NR == 2 ».
forward_sain() {
  printf '%s\n' "-P FORWARD ACCEPT" \
    "-A FORWARD -i wg0 -j WGPI-FWD-B" \
    "-A FORWARD -o wg0 ! -i wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" > "$TMP/ipt.S.FORWARD"
}
# Ce que le demon Docker laisse apres un redemarrage : il reinstalle ses regles avec
# « -I FORWARD », donc DEVANT le saut du moteur, qui n est alors plus consulte.
forward_docker_devant() {
  printf '%s\n' "-P FORWARD DROP" \
    "-A FORWARD -j DOCKER-USER" \
    "-A FORWARD -j DOCKER-ISOLATION-STAGE-1" \
    "-A FORWARD -o docker0 -j DOCKER" \
    "-A FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.S.FORWARD"
}
reset
eq "aucun saut : inactif" "$(load; access_kernel_state)" "inactif"

reset
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -s 10.8.0.2 -j WGPI-S-tous-B" "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
forward_sain
eq "saut present, en tete, chaine complete : actif" "$(load; access_kernel_state)" "actif"

# LE cas que personne ne regardait : la chaine est toujours la, « iptables -C » reussit
# donc, mais le demon Docker a insere ses regles devant et le moteur n est plus consulte.
# access_jump_first existait, avec le bon commentaire, et n avait AUCUN appelant dans le
# produit : tout l affichage restait vert pendant que le cloisonnement ne s appliquait plus.
reset
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
forward_docker_devant
eq "saut relegue derriere Docker : incoherent" "$(load; access_kernel_state)" "incoherent"
eq "et access_jump_first le dit" "$(load; access_jump_first && echo oui || echo non)" "non"
# Le meme etat, remis en ordre : actif de nouveau.
forward_sain
eq "le saut remis en tete : actif" "$(load; access_kernel_state)" "actif"
eq "et access_jump_first le confirme" "$(load; access_jump_first && echo oui || echo non)" "oui"

# « access show » annoncait « Filtrage actif » sur la seule foi du fichier, alors que le
# projet se donne par ecrit la regle inverse. C est la commande que le menu met en avant.
printf '%s\n' "V|1" "MODE|filtre" "GROUP|g|G" "POLICY|p1|1|grp:g|internet|any||aller|Internet" > "$TMP/etc/access.conf"
forward_sain
eq "access show, noyau actif : il le dit" "$(load; access_show 2>&1 | grep -c 'Filtrage actif')" "1"
forward_docker_devant
eq "access show, noyau incoherent : il ne dit plus actif" \
   "$(load; access_show 2>&1 | grep -c 'Filtrage actif')" "0"
eq "il nomme le probleme" "$(load; access_show 2>&1 | grep -c 'ne l.applique pas')" "1"
eq "et la commande qui repare" "$(load; access_show 2>&1 | grep -c 'access-apply')" "1"
reset
eq "access show, aucune regle dans le noyau : il le dit" \
   "$(load; access_show 2>&1 | grep -c 'AUCUNE règle')" "1"
eq "et il ne pretend pas filtrer" "$(load; access_show 2>&1 | grep -c 'Filtrage actif')" "0"
# Hors filtrage, le message reste celui du mode ouvert.
printf '%s\n' "V|1" "MODE|ouvert" "GROUP|g|G" > "$TMP/etc/access.conf"
eq "mode ouvert : aucun cloisonnement" "$(load; access_show 2>&1 | grep -c 'Aucun cloisonnement')" "1"
printf '%s\n' "V|1" "MODE|filtre" "GROUP|g|G" "POLICY|p1|1|grp:g|internet|any||aller|Internet" > "$TMP/etc/access.conf"

# Une chaine d entree qui ne finit pas par le saut vers le refus laisse passer tout ce qui
# n a pas correspondu : c est incoherent, pas actif.
reset
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -s 10.8.0.2 -j WGPI-S-tous-B" > "$TMP/ipt.S.WGPI-FWD-B"
eq "sans saut final vers le refus : incoherent" "$(load; access_kernel_state)" "incoherent"

# L acceptation generale encore presente court-circuite le moteur : les regles seraient
# sans effet alors que l interface annoncerait le contraire.
reset
printf '%s\n' "FORWARD -i wg0 -j WGPI-FWD-B" "FORWARD -i wg0 -j ACCEPT" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
eq "acceptation generale restee : incoherent" "$(load; access_kernel_state)" "incoherent"

echo "-- execution d un plan"
reset
eq "plan accepte" "$(load; printf '%s\n' '-N X' '-A X -j ACCEPT' | access_run_plan && echo oui)" "oui"
eq "deux commandes passees" "$(grep -c . "$TMP/ipt.log")" "2"

reset
echo "REFUSE" > "$TMP/ipt.fail"
eq "plan refuse : code non nul" "$(load; printf '%s\n' '-N X' '-A X -m REFUSE' '-A X -j ACCEPT' | access_run_plan >/dev/null 2>&1 || echo non)" "non"
# On s arrete a la premiere regle refusee, on ne continue pas a en poser.
eq "arret a la premiere regle refusee" "$(grep -c . "$TMP/ipt.log")" "2"

echo "-- bascule : inserer avant de retirer"
reset
( load; access_switch B A ) >/dev/null 2>&1
before "le nouveau saut FORWARD est insere avant le retrait de l ancien" "-I FORWARD 1 -i wg0 -j WGPI-FWD-B" "-D FORWARD -i wg0 -j WGPI-FWD-A"
before "le nouveau saut INPUT est insere avant le retrait de l ancien" "-I INPUT 1 -i wg0 -j WGPI-IN-B" "-D INPUT -i wg0 -j WGPI-IN-A"
if grep -qF -- "-D FORWARD -i wg0 -j ACCEPT" "$TMP/ipt.log"; then
  ok "l acceptation generale est retiree"
else
  ko "l acceptation generale n est pas retiree : le moteur serait court-circuite"
fi
before "le nouveau saut precede le retrait de l acceptation generale" "-I FORWARD 1 -i wg0 -j WGPI-FWD-B" "-D FORWARD -i wg0 -j ACCEPT"

echo "-- bascule sans ancien tampon"
reset
( load; access_switch B "" ) >/dev/null 2>&1
if grep -qE -- "-D (FORWARD|INPUT) -i wg0 -j WGPI-(FWD|IN)-" "$TMP/ipt.log"; then
  ko "un retrait de saut a ete tente alors qu il n y avait pas d ancien tampon"
else
  ok "aucun retrait inutile sans ancien tampon"
fi

echo "-- demontage complet"
reset
( load; access_unswitch ) >/dev/null 2>&1
for b in A B; do
  if grep -qF -- "-D FORWARD -i wg0 -j WGPI-FWD-$b" "$TMP/ipt.log"; then
    ok "retrait du saut FORWARD du tampon $b"
  else
    ko "saut FORWARD du tampon $b non retire"
  fi
done
if grep -qF -- "-I FORWARD 1 -i wg0 -j ACCEPT" "$TMP/ipt.log"; then
  ok "l acceptation generale est remise"
else
  ko "l acceptation generale n est pas remise : le VPN resterait coupe"
fi

# Si elle est deja la, on ne la remet pas en double.
reset
echo "FORWARD -i wg0 -j ACCEPT" > "$TMP/ipt.exists"
( load; access_unswitch ) >/dev/null 2>&1
eq "pas de doublon de l acceptation generale" "$(grep -cF -- '-I FORWARD 1 -i wg0 -j ACCEPT' "$TMP/ipt.log")" "0"

echo "-- refus d activation : les garde-fous"
reset
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|g|G
ACC
eq "aucune regle active : activation refusee" "$(load; cmd_access_on >/dev/null 2>&1 || echo refuse)" "refuse"
eq "le refus explique quoi faire" "$(load; cmd_access_on 2>&1 | grep -c 'access allow tous internet')" "1"
eq "le mode reste ouvert apres refus" "$(load; access_mode)" "ouvert"

cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC
# Le moteur ne filtre que l IPv4. Refuser d activer rendait le cloisonnement inaccessible
# a tout Pi ayant une IPv6 publique — c est-a-dire beaucoup. On coupe desormais l IPv6 du
# tunnel pendant le filtrage : les regles redeviennent incontournables, au prix annonce de
# l IPv6 a travers le VPN.
# Chaque appel repart d un mode « ouvert » : une activation reussie bascule le fichier en
# « filtre », et l appel suivant prendrait la branche « deja actif » sans jamais atteindre
# le code teste.
ouvert() {
  { echo "V|1"; echo "MODE|ouvert"; echo "GROUP|g|G"
    echo "POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert"; } > "$TMP/etc/access.conf"
  reset
}
ouvert
eq "IPv6 presente : l activation n est plus refusee" \
   "$(load; IPV6_ON=1; IPV6_NAT=1; cmd_access_on >/dev/null 2>&1 && echo ok || echo refuse)" "ok"
ouvert
eq "et elle annonce que l IPv6 ne passera pas" \
   "$(load; IPV6_ON=1; IPV6_NAT=1; cmd_access_on 2>&1 | grep -c 'ne traversera pas le VPN')" "1"
ouvert
eq "elle dit aussi comment revenir en arriere" \
   "$(load; IPV6_ON=1; IPV6_NAT=1; cmd_access_on 2>&1 | grep -c 'rétablit l.IPv6')" "1"
# Sans IPv6 dans le tunnel, rien a annoncer.
ouvert
eq "sans IPv6, aucun avertissement" \
   "$(load; IPV6_ON=0; IPV6_NAT=0; cmd_access_on 2>&1 | grep -c 'ne traversera pas le VPN')" "0"
ouvert

# Port SSH indeterminable : on refuse de filtrer plutot que de poser un secours sur le
# mauvais port.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC
# access_ssh_ports est neutralisee ici plutot que de compter sur l absence de sshd : sur
# un runner d integration continue il EST installe, donc la fonction retombe sur son
# defaut 22 et le refus ne se declencherait jamais. Un test ne doit pas dependre de ce
# qui est installe sur la machine qui l execute.
# Et « die » quitte le sous-shell : le « || » doit porter sur un sous-shell IMBRIQUE,
# sinon il ne s execute jamais et le test passerait a tort.
eq "port SSH inconnu : rien n est applique" \
   "$( ( load; access_ssh_ports() { :; }; cmd_access_apply ) >/dev/null 2>&1 || echo refuse )" "refuse"
eq "le refus parle du port SSH" \
   "$( ( load; access_ssh_ports() { :; }; cmd_access_apply ) 2>&1 | grep -c 'Port SSH' )" "1"

echo "-- essai a blanc"
reset
eq "le plan est affiche" "$(load; cmd_access_plan 2>&1 | grep -c 'iptables -N WGPI-FWD-T')" "1"
eq "l essai a blanc ne bascule rien" "$(grep -cE -- '-I (FORWARD|INPUT)' "$TMP/ipt.log")" "0"


echo "-- reparation d un filtrage demande mais absent du pare-feu"
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC
reset
# Mode « filtre » mais aucune chaine dans le noyau : c est l etat apres un « ufw reload »
# ou un redemarrage de Docker. « access on » doit REAPPLIQUER, pas sortir en annoncant
# que tout va bien — c est la commande que le depannage conseille dans ce cas precis.
( load; cmd_access_on ) >/dev/null 2>&1
if grep -qE -- "-I (FORWARD|INPUT) 1 -i wg0 -j WGPI-" "$TMP/ipt.log"; then
  ok "les regles sont reappliquees"
else
  ko "rien n a ete reapplique : le depannage conseillerait une commande inoperante"
fi
eq "le message explique l etat" "$(load; cmd_access_on 2>&1 | grep -c 'pas appliqué')" "1"

reset
# Deja actif : on ne refait rien.
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
forward_sain
( load; cmd_access_on ) >/dev/null 2>&1
eq "deja actif : aucune reapplication" "$(grep -cE -- '-I (FORWARD|INPUT) 1 -i wg0 -j WGPI-' "$TMP/ipt.log")" "0"
# En revanche, un saut relegue derriere Docker n est PAS « deja actif » : « access on »
# doit reappliquer, puisque c est la remediation que le diagnostic prescrit.
reset
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
forward_docker_devant
( load; cmd_access_on ) >/dev/null 2>&1
eq "saut relegue : access on reapplique" \
   "$([[ $(grep -cE -- '-I (FORWARD|INPUT) 1 -i wg0 -j WGPI-' "$TMP/ipt.log") -ge 1 ]] && echo oui || echo non)" "oui"
forward_sain

echo "-- un access on qui echoue ne laisse pas MODE|filtre"
# cmd_access_apply signale chacun de ses echecs par « die », et « die » fait « exit 1 ».
# Appelee directement, elle tuait le processus entier : le rattrapage qui remet le mode a
# « ouvert » n etait JAMAIS execute, et le filtrage se rallumait tout seul au montage
# suivant du tunnel — alors que l utilisateur venait de lire « le filtrage n est donc pas
# applique ». L appel passe desormais par un sous-shell.
reset
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|g|G"
  echo "POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert"; } > "$TMP/etc/access.conf"
# On fait echouer l application la ou elle « die » : le plan refuse par le noyau.
echo "-N WGPI-" > "$TMP/ipt.fail"
( load; cmd_access_on ) >/dev/null 2>&1
eq "le mode est remis a ouvert" "$(load; access_mode)" "ouvert"
eq "et le code de retour dit l echec" \
   "$(load; cmd_access_on >/dev/null 2>&1 && echo ok || echo echec)" "echec"
: > "$TMP/ipt.fail"
# Et une activation qui REUSSIT laisse bien le mode a filtre.
reset
{ echo "V|1"; echo "MODE|ouvert"; echo "GROUP|g|G"
  echo "POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert"; } > "$TMP/etc/access.conf"
( load; cmd_access_on ) >/dev/null 2>&1
eq "une activation reussie ecrit filtre" "$(load; access_mode)" "filtre"

echo "-- access off retablit les DEUX acceptations"
# base_up pose l acceptation sur les deux familles hors filtrage. access_unswitch, chemin
# de sortie a chaud, retirait bien la coupure IPv6 mais ne reposait que l IPv4 : sur un Pi
# a IPv6 publique derriere ufw, « access off » annoncait « tous vos appareils peuvent a
# nouveau tout joindre » et l IPv6 du VPN restait muette.
reset
( load; IPV6_NAT=1; access_unswitch ) >/dev/null 2>&1
eq "l acceptation IPv4 est reposee" \
   "$(grep -c -- '^-w -I FORWARD 1 -i wg0 -j ACCEPT' "$TMP/ipt.log")" "1"
eq "et l IPv6 aussi" \
   "$(grep -c -- '^ip6tables -w -I FORWARD 1 -i wg0 -j ACCEPT' "$TMP/ipt.log")" "1"
# Sans IPv6 routee, rien a reposer de ce cote : poser une regle ip6tables sur un Pi sans
# IPv6 serait du bruit, et le retrait de la coupure suffit.
reset
( load; IPV6_NAT=0; access_unswitch ) >/dev/null 2>&1
eq "sans IPv6 routee, aucune regle ip6 n est posee" \
   "$(grep -c -- '^ip6tables -w -I FORWARD 1' "$TMP/ipt.log")" "0"

echo "-- un reseau local apparu APRES la derniere application"
# La chaine « Internet seulement » est un instantane. Un pont cree depuis par un
# « docker compose up » est joignable depuis un groupe cense n avoir qu Internet, et rien
# ne provoque de reapplication : l etat lu dans le noyau reste « actif », puisque la
# topologie des sauts est intacte. Le diagnostic est le seul endroit ou l ecart se voit.
reset
{ echo "V|1"; echo "MODE|filtre"; echo "GROUP|g|G"
  echo "POLICY|p1|1|grp:tous|internet|any||aller|Internet"; } > "$TMP/etc/access.conf"
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
forward_sain
# La chaine posee ne connait que la maison ; load() en declare deux.
printf '%s\n' "-A WGPI-INET-B -d 192.168.1.0/24 -m comment --comment wgpi:local -j RETURN" \
  "-A WGPI-INET-B -j ACCEPT" > "$TMP/ipt.S.WGPI-INET-B"
eq "le reseau manquant est nomme" \
   "$(load; access_inet_stale_warn 2>&1 | grep -c '172.18.0.0/16')" "1"
eq "et la commande qui referme aussi" \
   "$(load; access_inet_stale_warn 2>&1 | grep -c 'access-apply')" "1"
eq "il rend non nul" "$(load; access_inet_stale_warn >/dev/null 2>&1 && echo oui || echo non)" "non"
eq "la version note avale le code" "$(load; access_inet_stale_note >/dev/null 2>&1 && echo oui || echo non)" "oui"
# La chaine a jour ne declenche rien.
printf '%s\n' "-A WGPI-INET-B -d 192.168.1.0/24 -m comment --comment wgpi:local -j RETURN" \
  "-A WGPI-INET-B -d 172.18.0.0/16 -m comment --comment wgpi:local -j RETURN" \
  "-A WGPI-INET-B -j ACCEPT" > "$TMP/ipt.S.WGPI-INET-B"
eq "une chaine a jour ne declenche rien" "$(load; access_inet_stale_warn 2>&1 | grep -c 'apparu')" "0"
eq "et elle rend 0" "$(load; access_inet_stale_warn >/dev/null 2>&1 && echo oui || echo non)" "oui"
# Hors filtrage, le sujet ne se pose pas.
{ echo "V|1"; echo "MODE|ouvert"; } > "$TMP/etc/access.conf"
eq "hors filtrage : rien a dire" "$(load; access_inet_stale_warn >/dev/null 2>&1 && echo oui || echo non)" "oui"
rm -f "$TMP/ipt.S.WGPI-INET-B"
# L etat ou la suite des tests l attend : mode filtre, une regle.
{ echo "V|1"; echo "MODE|filtre"; echo "GROUP|g|G"
  echo "POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert"; } > "$TMP/etc/access.conf"

echo "-- la confirmation survit au redemarrage"
CONF_FILE=$TMP/etc/access-confirme
rm -f "$CONF_FILE"
eq "non confirmee au depart" "$(load; access_confirmed && echo oui || echo non)" "non"
( load; access_set_confirmed 1 )
eq "confirmee apres marquage" "$(load; access_confirmed && echo oui || echo non)" "oui"
eq "le fichier est dans STATE_DIR, pas dans /run" "$([[ -f $CONF_FILE ]] && echo oui || echo non)" "oui"
eq "droits 600" "$(stat -c '%a' "$CONF_FILE")" "600"

# Au demarrage avec une configuration deja confirmee : pas de minuteur, MAIS la bascule
# doit avoir lieu. Sortir trop tot laisserait les chaines construites sans saut pour y
# mener, donc un filtrage annonce et inexistant.
reset
( load; cmd_access_apply --boot ) >/dev/null 2>&1
if grep -qE -- "-I FORWARD 1 -i wg0 -j WGPI-FWD-" "$TMP/ipt.log"; then
  ok "au demarrage, la bascule a bien lieu malgre l absence de minuteur"
else
  ko "la bascule est sautee : les chaines existeraient sans etre branchees"
fi

# Reappliquer une configuration deja confirmee ne doit PAS la deconfirmer.
eq "reappliquer une configuration confirmee ne la deconfirme pas" \
   "$(load; access_set_confirmed 1; cmd_access_on >/dev/null 2>&1; access_confirmed && echo oui || echo non)" "oui"

# Une NOUVELLE activation repart d une configuration non confirmee : le filet doit jouer
# pour la nouvelle configuration, pas heriter d une validation ancienne.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC
eq "une nouvelle activation remet a zero la confirmation" \
   "$(load; access_set_confirmed 1; cmd_access_on >/dev/null 2>&1; access_confirmed && echo oui || echo non)" "non"

echo "-- avertissement sur le DNS de la box"
# « Internet seulement » ecarte TOUS les reseaux locaux du Pi, donc la box. Si le DNS des
# appareils est dans l un de ces reseaux, plus aucun nom ne se resout : il faut le dire
# AVANT d appliquer.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
POLICY|p1|1|grp:invites|internet|any||aller|Internet seulement
ACC
# Le garde-fou raisonne par APPAREIL. Les appartenances CUMULENT les autorisations — le
# moteur pose un saut par couple (appareil, groupe) — et juger chaque groupe seul rendait
# l avertissement faux des que la couverture DNS etait posee sur un groupe et Internet sur
# un autre, ce qui faisait de surcroit sortir « access check » en erreur.
eq "l appareil est signale" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f1)" "telephone"
eq "et l adresse de son DNS avec" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f2)" "192.168.1.1"
eq "l avertissement donne la commande qui repare" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_warn 2>&1 | grep -c 'resource add dns 192.168.1.1')" "1"
# Le remede porte sur « tous », qui contient TOUJOURS tout le monde : la commande donnee
# ne peut donc pas tomber a cote, quels que soient les groupes de l appareil bloque.
eq "et il porte sur le groupe automatique" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_warn 2>&1 | grep -c 'access allow tous res:dns')" "2"
eq "il nomme l appareil bloque" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_warn 2>&1 | grep -c 'telephone')" "1"
# Le code de retour : « warn » rend non nul, « note » l avale. C est cette paire qui permet
# de le brancher sur les chemins d ECRITURE sans transformer un avertissement en echec.
eq "warn rend non nul quand il avertit" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_warn >/dev/null 2>&1 && echo oui || echo non)" "non"
eq "note avale le code" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_note >/dev/null 2>&1 && echo oui || echo non)" "oui"

# Un DNS public est deja sur Internet : rien a signaler.
eq "DNS public : aucun avertissement" "$(load; CLIENT_DNS=1.1.1.1; access_dns_blocked_devices | wc -l)" "0"
# Un DNS sur un AUTRE reseau local du Pi — Pi-hole en conteneur, pont Docker. Depuis que
# la chaine WGPI-INET ecarte tous les reseaux locaux, « internet » l exclut lui aussi ; le
# garde-fou ne cherchait son DNS que dans LAN_NET et se taisait completement.
eq "DNS sur un pont Docker : signale" \
   "$(load; CLIENT_DNS=172.18.0.2; access_dns_blocked_devices | cut -d'|' -f2)" "172.18.0.2"
# Le DNS qui est le Pi LUI-MEME passe par INPUT et non par FORWARD : il arrive toujours.
# Avertir etait faux, et le remede dicte posait une regle dans une chaine de FORWARD ou un
# tel paquet ne passe jamais — apres quoi le garde-fou se taisait, pour une mauvaise raison.
eq "DNS = le Pi : rien a signaler" \
   "$(load; CLIENT_DNS=192.168.1.50; access_dns_blocked_devices | wc -l)" "0"
eq "DNS en boucle locale non plus" \
   "$(load; CLIENT_DNS=127.0.0.1; access_dns_blocked_devices | wc -l)" "0"
# Plusieurs DNS : le premier qui est derriere le filtre est celui qui compte.
eq "le premier DNS local est retenu" \
   "$(load; CLIENT_DNS=1.1.1.1,192.168.1.1; access_dns_blocked_devices | cut -d'|' -f2)" "192.168.1.1"

echo "-- le DNS couvert par un AUTRE groupe du meme appareil"
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
POLICY|p1|1|grp:tous|maison|any||aller|La maison, pour tous
POLICY|p2|1|grp:invites|internet|any||aller|Internet seulement
ACC
# Dans le noyau, l appareil saute dans WGPI-S-invites PUIS dans WGPI-S-tous : le paquet
# UDP/53 vers la box est accepte par la seconde. L avertissement serait donc faux.
eq "le cumul des groupes est pris en compte" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | wc -l)" "0"
# Et un appareil qui n est dans AUCUN groupe nomme depend des seules regles de « tous ».
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
POLICY|p1|1|grp:tous|internet|any||aller|Internet seulement
ACC
eq "le groupe automatique est traite comme les autres" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f1)" "telephone"
# Sans regle internet, le sujet ne se pose pas.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
POLICY|p1|1|grp:invites|maison|any||aller|La maison seulement
ACC
eq "sans regle internet : hors sujet" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | wc -l)" "0"

echo "-- couverture du DNS : la destination ne suffit pas, le port compte"
# Une regle « maison » restreinte au partage de fichiers comptait comme couverture du
# DNS : l avertissement se taisait sur une configuration ou aucun nom ne se resout.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|maison|tcp|445|aller|Le partage de fichiers
ACC
eq "la maison sur le mauvais port ne couvre pas le DNS" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f1)" "telephone"
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|maison|udp|53|aller|Le DNS
ACC
eq "la maison en UDP 53 couvre le DNS" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | wc -l)" "0"

# Une ressource RESEAU qui contient le DNS : « /32 » etait concatene sans regarder, donc
# la comparaison echouait sur « 192.168.1.0/24 » et une ressource qui couvre pourtant le
# DNS ne comptait pas — avertissement FAUX, compte comme un probleme par « wg-pi check ».
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
RES|lan|Le reseau de la maison|192.168.1.0/24
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|res:lan|any||aller|Le reseau
ACC
eq "une ressource reseau couvrant le DNS compte" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | wc -l)" "0"
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
RES|lan|Le reseau de la maison|192.168.1.0/24
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|res:lan|tcp|445|aller|Le partage
ACC
eq "la meme ressource sur le mauvais port ne couvre pas" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f1)" "telephone"
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
RES|nas|Le NAS|192.168.1.20
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|res:nas|udp|53|aller|Un DNS qui n existe pas la
ACC
eq "une autre machine, meme en UDP 53, ne couvre pas" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | cut -d'|' -f1)" "telephone"
# Et le remede que l avertissement propose lui-meme doit le faire taire : sinon il envoie
# l utilisateur dans le vide.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
MEMBER|telephone|invites
RES|dns|Le DNS de la box|192.168.1.1
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:tous|res:dns|udp|53|aller|Le DNS
ACC
eq "le remede propose fait taire l avertissement" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_devices | wc -l)" "0"

# La fonction de port, cas par cas.
eq "any sans ports couvre"      "$(load; access_dns_port_ok any "" && echo oui || echo non)" oui
eq "udp sans ports couvre"      "$(load; access_dns_port_ok udp "" && echo oui || echo non)" oui
eq "udp 53 couvre"              "$(load; access_dns_port_ok udp 53 && echo oui || echo non)" oui
eq "tcpudp 53 couvre"           "$(load; access_dns_port_ok tcpudp 53 && echo oui || echo non)" oui
eq "une plage contenant 53 couvre" "$(load; access_dns_port_ok udp 50-60 && echo oui || echo non)" oui
eq "53 dans une liste couvre"   "$(load; access_dns_port_ok udp 123,53,443 && echo oui || echo non)" oui
# Le TCP seul ne couvre pas : les resolveurs essaient l UDP d abord, et une resolution
# qui ne tient pas dans un paquet est l exception, pas la regle.
eq "tcp seul ne couvre pas"     "$(load; access_dns_port_ok tcp 53 && echo oui || echo non)" non
eq "icmp ne couvre pas"         "$(load; access_dns_port_ok icmp "" && echo oui || echo non)" non
eq "un autre port ne couvre pas" "$(load; access_dns_port_ok udp 443 && echo oui || echo non)" non
eq "une plage sans 53 ne couvre pas" "$(load; access_dns_port_ok udp 60-70 && echo oui || echo non)" non

# Un zero en tete est refuse A LA SAISIE : iptables lit « 053 » comme de l OCTAL, donc 43.
# La regle ouvrait un autre port que celui affiche partout, et le garde-fou DNS — qui
# normalise en decimal — declarait couvert un DNS en realite ferme.
eq "053 est refuse"             "$(load; access_valid_ports 053 && echo oui || echo non)" non
eq "040-060 aussi"             "$(load; access_valid_ports 040-060 && echo oui || echo non)" non
eq "une liste qui en contient un" "$(load; access_valid_ports 53,080 && echo oui || echo non)" non
eq "la borne haute compte aussi" "$(load; access_valid_ports 40-060 && echo oui || echo non)" non
eq "53 reste accepte"           "$(load; access_valid_ports 53 && echo oui || echo non)" oui
eq "une plage normale aussi"    "$(load; access_valid_ports 5000-5001 && echo oui || echo non)" oui
eq "et le port 0 seul reste refuse" "$(load; access_valid_ports 0 && echo oui || echo non)" non
echo
echo "-- modification, reapplication, et coherence du filet"
# Le critere n est pas « on reapplique » mais « la configuration a-t-elle change ».
# Une reapplication a l identique ne doit rien redemander ; une modification, si.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC

reset
rm -f "$TMP/save.fail"
eq "--modifie retire la confirmation" \
   "$(load; access_set_confirmed 1; cmd_access_apply --modifie >/dev/null 2>&1; access_confirmed && echo oui || echo non)" "non"

reset
eq "une reapplication a l identique la conserve" \
   "$(load; access_set_confirmed 1; cmd_access_apply >/dev/null 2>&1; access_confirmed && echo oui || echo non)" "oui"

# INVARIANT : un minuteur arme implique une configuration non confirmee. Sans lui, le
# panneau web n afficherait pas son bandeau, personne ne confirmerait, et deux minutes
# plus tard tout le cloisonnement tomberait — pour une simple modification de regle.
reset
( load; access_set_confirmed 0; cmd_access_apply ) >/dev/null 2>&1
eq "minuteur arme : la configuration n est pas marquee confirmee" \
   "$(load; access_confirmed && echo oui || echo non)" "non"

# Sans instantane, le minuteur n aurait rien a restaurer : l armer donnerait un filet
# qui n existe pas, et « access-rollback » affirmerait plus tard une restauration qui
# n a pas eu lieu.
reset
: > "$TMP/save.fail"
eq "sans instantane, l application refuse" \
   "$(load; access_set_confirmed 0; cmd_access_apply 2>&1 | grep -c 'Instantané du pare-feu impossible')" "1"
eq "et elle indique comment passer outre" \
   "$(load; access_set_confirmed 0; cmd_access_apply 2>&1 | grep -c -- '--sans-filet')" "1"
eq "--sans-filet applique quand meme" \
   "$(load; access_set_confirmed 0; cmd_access_apply --sans-filet >/dev/null 2>&1; echo $?)" "0"
rm -f "$TMP/save.fail"

# « access on » refusait deja une configuration sans regle, mais il n est pas le seul
# chemin : le panneau web reapplique apres CHAQUE ecriture, et supprimer la derniere
# regle arrivait la sans garde-fou, coupant tous les appareils d un coup.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|g|G
ACC
reset
eq "aucune regle : l application refuse" \
   "$(load; cmd_access_apply 2>&1 | grep -c 'couperait tous vos appareils')" "1"
eq "et rien n a ete bascule" "$(grep -cE -- '-I (FORWARD|INPUT)' "$TMP/ipt.log")" "0"

# Un bandeau de confirmation que rien ne peut faire disparaitre serait pire qu absent :
# « confirm » rattrape un etat enregistre en retard sur la realite.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|filtre
GROUP|g|G
POLICY|p1|1|grp:tous|internet|any||aller|Tout ouvert
ACC
reset
rm -f "$TMP/snap"
eq "confirm rattrape un filtrage actif non marque" \
   "$(load; access_set_confirmed 0; cmd_access_confirm >/dev/null 2>&1; access_confirmed && echo oui || echo non)" "oui"

# atomic_write ne doit jamais laisser son temporaire : il sert aussi a ecrire wg0.conf,
# qui contient la cle privee du serveur.
( load; echo contenu | atomic_write "$TMP/etc/essai.txt" 600 )
eq "atomic_write ecrit le fichier" "$(cat "$TMP/etc/essai.txt" 2>/dev/null)" "contenu"
eq "et ne laisse aucun temporaire" "$(find "$TMP/etc" -maxdepth 1 -name '.essai.txt.*' | wc -l)" "0"
( load; echo contenu | atomic_write "$TMP/etc/sous-dossier-absent/x" 600 ) 2>/dev/null
eq "un chemin impossible ne laisse rien derriere" \
   "$(find "$TMP/etc" -maxdepth 1 -name '.x.*' | wc -l)" "0"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
