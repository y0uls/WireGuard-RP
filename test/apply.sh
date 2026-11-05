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
cp "$BIN/iptables" "$BIN/iptables-save"
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
load() { source "$SRC"; LAN_IF=eth0; LAN_NET=192.168.1.0/24; WG_PORT=51820; IPV6_NAT=0; }
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
reset
eq "aucun saut : inactif" "$(load; access_kernel_state)" "inactif"

reset
echo "FORWARD -i wg0 -j WGPI-FWD-B" > "$TMP/ipt.exists"
printf '%s\n' "-A WGPI-FWD-B -s 10.8.0.2 -j WGPI-S-tous-B" "-A WGPI-FWD-B -j WGPI-DENY-B" > "$TMP/ipt.S.WGPI-FWD-B"
eq "saut present et chaine complete : actif" "$(load; access_kernel_state)" "actif"

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
eq "IPv6 routee : activation refusee" "$(load; IPV6_NAT=1; cmd_access_on >/dev/null 2>&1 || echo refuse)" "refuse"
eq "le refus parle de contournement en IPv6" "$(load; IPV6_NAT=1; cmd_access_on 2>&1 | grep -c 'contournables en IPv6')" "1"

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
( load; cmd_access_on ) >/dev/null 2>&1
eq "deja actif : aucune reapplication" "$(grep -cE -- '-I (FORWARD|INPUT) 1 -i wg0 -j WGPI-' "$TMP/ipt.log")" "0"

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
# « Internet seulement » exclut le reseau de la maison, donc la box. Si le DNS des
# appareils EST la box, plus aucun nom ne se resout : il faut le dire AVANT d appliquer.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
POLICY|p1|1|grp:invites|internet|any||aller|Internet seulement
ACC
eq "le groupe est signale" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_groups | cut -d'|' -f1)" "invites"
eq "l avertissement donne la commande qui repare" \
   "$(load; CLIENT_DNS=192.168.1.1; access_dns_warn 2>&1 | grep -c 'resource add dns 192.168.1.1')" "1"
# Un DNS public est deja sur Internet : rien a signaler.
eq "DNS public : aucun avertissement" "$(load; CLIENT_DNS=1.1.1.1; access_dns_blocked_groups | wc -l)" "0"
# Et une regle qui couvre la maison resout le probleme.
cat > "$TMP/etc/access.conf" <<'ACC'
V|1
MODE|ouvert
GROUP|invites|Invites
POLICY|p1|1|grp:invites|internet|any||aller|Internet
POLICY|p2|1|grp:invites|maison|any||aller|La maison
ACC
eq "acces a la maison : aucun avertissement" "$(load; CLIENT_DNS=192.168.1.1; access_dns_blocked_groups | wc -l)" "0"
echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
