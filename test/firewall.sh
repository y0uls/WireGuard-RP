#!/usr/bin/env bash
# Tests du pare-feu généré par write_firewall_script, et de sa migration.
#
# Le script est recopié avec STATE_DIR redirigé vers un dossier temporaire : rien ne touche
# /etc/wg-pi, ces tests sont donc sans danger sur un Pi en production.
#
# Usage : ./firewall.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
mkdir -p "$TMP/etc"

# STATE_DIR redirigé, et le « main "$@" » final retiré pour pouvoir charger sans lancer.
sed "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" "$SCRIPT" > "$TMP/full.sh"
grep -q "STATE_DIR='$TMP/etc'" "$TMP/full.sh" || { echo "Redirection de STATE_DIR échouée" >&2; exit 2; }
if [[ $(tail -n1 "$TMP/full.sh") == 'main "$@"' ]]; then
  head -n -1 "$TMP/full.sh" > "$SRC"
else
  cp "$TMP/full.sh" "$SRC"
fi

pass=0 fail=0
ok()   { printf '  OK   %s\n' "$1"; pass=$((pass + 1)); }
ko()   { printf '  KO   %s\n' "$1"; fail=$((fail + 1)); }
check(){ if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1 (obtenu : $2 / attendu : $3)"; fi; }

# Le corps d une fonction du script genere, delimite par ses accolades.
#
# Les assertions decoupaient la fonction avec « grep -A8 », « -A16 », « -A3 » : un nombre de
# lignes fixe. Que la fonction grossisse d une ligne, et l assertion cesse de voir ce qu elle
# surveille — sans jamais echouer. On ne compare pas des chaines dans awk pour eviter toute
# echappement de motif.
corps() {   # <nom de la fonction>
  awk -v debut="$1() {" '
    index($0, debut) == 1 { dedans = 1 }
    dedans { print }
    dedans && $0 == "}" { exit }
  ' "$FW"
}

# Génère le pare-feu avec des réglages connus, puis rend le chemin du fichier produit.
generate() {  # $1 = IPV6_NAT
  (
    # shellcheck source=/dev/null
    source "$SRC"
    WG_PORT=51820 WG_NET4=10.8.0 WG_NET6=fd00:1234:5678:: IPV6_NAT=$1
    # Un reseau local renseigne : sans LAN_IF, arp_fige sort a la premiere ligne et la
    # repose des associations n est jamais exercee.
    LAN_IF=eth0 LAN_IP=192.168.1.50 LAN_GW=192.168.1.1 LAN_NET=192.168.1.0/24
    write_firewall_script
    printf '%s' "$FW_SCRIPT"
  )
}

echo "-- pare-feu généré"
FW=$(generate 0)
[[ -f $FW ]] || { echo "  KO   aucun fichier généré" >&2; exit 1; }

# Le script généré est en /bin/sh et n'était vérifié par rien : une erreur de syntaxe
# n'apparaissait qu'au montage du tunnel, chez l'utilisateur, après un curl | sudo bash.
if sh -n "$FW" 2>"$TMP/err"; then ok "syntaxe POSIX sh du script généré"; else ko "syntaxe du script généré : $(cat "$TMP/err")"; fi

# Le reveil a distance a travers le VPN tient a une association adresse → carte figee,
# perdue a chaque redemarrage. C est wg-quick qui rappelle ce script au demarrage, donc
# c est ici que la repose doit vivre — sinon le Wake-on-LAN ne marche qu une fois.
check "la repose ARP est definie" "$(grep -c '^arp_fige() {' "$FW")" "1"
check "et son retrait aussi" "$(grep -c '^arp_libere() {' "$FW")" "1"
# Corps complet de la fonction, et non une fenetre de N lignes : une fenetre fixe se
# decale au premier ajout et le test passe au vert en ne regardant plus rien.
check "base_up repose les associations" "$(awk '/^base_up()/,/^}/' "$FW" | grep -c 'arp_fige')" "1"
check "base_down les retire" "$(awk '/^base_down()/,/^}/' "$FW" | grep -c 'arp_libere')" "1"
# Sans l interface du reseau local, « ip neigh » ne saurait pas ou poser l association.
check "l interface du reseau local est transmise" "$(grep -c '^LAN_IF=' "$FW")" "1"
# Un reseau entier n a pas de carte : le figer n aurait aucun sens.
check "les reseaux sont ecartes" "$(grep -c 'case "$cible" in \*/\*)' "$FW")" "1"
# Le retrait doit porter sur ce que CE SCRIPT a pose, et sur rien d autre.
#
# Le deduire du fichier d acces laissait orpheline toute association dont l adresse avait
# change ou dont la ressource avait disparu : plus citee nulle part, donc plus jamais
# retiree. Or une entree permanente ne se reapprend jamais et detourne tout le trafic du Pi
# vers cette adresse. Mais balayer a l inverse TOUT ce que le noyau marque permanent
# effacait le durcissement ARP d un administrateur. D ou la liste tenue par arp_fige.
ARPF=$TMP/corps-arp-fige.txt ARPL=$TMP/corps-arp-libere.txt
awk '/^arp_fige/,/^}/'   "$FW" > "$ARPF"
awk '/^arp_libere/,/^}/' "$FW" > "$ARPL"
check "la liste des associations posees est transmise" "$(grep -c "^ARP_STATE=" "$FW")" "1"
# Nommer le geste plutot que compter les occurrences : la fonction cite la liste trois
# fois (creer son dossier, en fixer les droits, y ajouter une adresse).
check "la pose note ce qu elle fige" "$(grep -c 'echo "$cible" >> "$ARP_STATE"' "$ARPF")" "1"
# L assertion qui manquait : rien ne verifiait que le retrait RETIRE. Remplacer la ligne
# « ip neigh del » par une instruction vide laissait la suite entierement verte.
check "le retrait retire vraiment" "$(grep -c 'ip neigh del' "$ARPL")" "1"
# Compter les occurrences passerait pour la mauvaise raison : on nomme les deux gestes.
check "et le fait depuis sa propre liste" "$(grep -c 'done < \"$ARP_STATE\"' "$ARPL")" "1"
check "puis vide la liste" "$(grep -c 'rm -f \"$ARP_STATE\"' "$ARPL")" "1"
check "il ne balaie plus tout le noyau" "$(grep -c 'ip neigh show' "$ARPL")" "0"
check "et ne relit pas le fichier d acces" "$(grep -c ACCESS_FILE "$ARPL")" "0"
# Les champs sont ceux du FICHIER : RES|<id>|<libelle>|<cible>|<mac>, donc $4 et $5. Un
# decalage d un seul champ figerait le libelle comme adresse, ou rien du tout.
check "la cible et la MAC sont lues aux bons champs" \
      "$(grep -c 'RES" && \$5 != "" { print \$4 " " \$5 }' "$ARPF")" "1"
# Dernier rempart pour un fichier edite a la main : figer une MAC fausse sur la box
# couperait le reseau du Pi definitivement, sans reparation possible a distance.
check "la box est epargnee" "$(grep -c LAN_GW "$ARPF")" "1"
check "le Pi lui-meme aussi" "$(grep -c LAN_IP "$ARPF")" "1"
# Les compter ne suffit pas : des gardes places APRES la pose ne gardent rien, et aucune
# assertion ne bronchait si on les deplacait.
LGW=$(grep -n LAN_GW "$ARPF" | head -n1 | cut -d: -f1)
LIP=$(grep -n LAN_IP "$ARPF" | head -n1 | cut -d: -f1)
LPOSE=$(grep -n 'ip neigh replace' "$ARPF" | head -n1 | cut -d: -f1)
check "la garde sur la box precede la pose" \
      "$([[ ${LGW:-999} -lt ${LPOSE:-0} ]] && echo oui || echo non)" "oui"
check "la garde sur le Pi precede la pose" \
      "$([[ ${LIP:-999} -lt ${LPOSE:-0} ]] && echo oui || echo non)" "oui"
check "les deux adresses sont transmises" "$(grep -cE "^LAN_(GW|IP)=" "$FW")" "2"
# Sans ce verbe, la pose n avait lieu qu au montage suivant du tunnel : « resource add »
# annoncait un succes que le noyau ignorait.
check "le verbe arp existe" "$(grep -c "^  arp)" "$FW")" "1"
# Son existence ne disait rien de ce qu il fait : lui retirer la liberation ne cassait rien.
# Les deux comptent, et dans cet ordre — liberer d abord, sinon une association dont
# l adresse vient de changer reste en place a cote de la nouvelle.
check "et il libere avant de reposer" \
      "$(grep '^  arp)' "$FW" | grep -c 'arp_libere; *arp_fige')" "1"
check "et l aide le mentionne" "$(grep -c "up|down|reload|arp" "$FW")" "1"
# Le script genere pose des regles de pare-feu et porte les reglages du reseau : il ne doit
# etre lisible que par root. Aucun test ne le verifiait.
check "le script genere n est lisible que par root" "$(stat -c '%a' "$FW")" "700"

GEN=$(grep -c '^# wg-pi-fw-gen: ' "$FW")
check "marqueur de génération présent une seule fois" "$GEN" "1"
check "marqueur en ligne 2" "$(sed -n '2p' "$FW" | cut -d' ' -f2)" "wg-pi-fw-gen:"

# La fuite corrigée : sans « ! -i wg0 », un flux déjà établi entre deux appareils du VPN
# est accepté par la règle conntrack et contourne tout filtrage à venir.
if grep -q 'FORWARD -o "$WG_IF" ! -i "$WG_IF" -m conntrack' "$FW"; then
  ok 'regle conntrack restreinte par ! -i $WG_IF'
else
  ko 'regle conntrack SANS ! -i $WG_IF : le pair-a-pair etabli contourne les ACL'
fi

# Le verbe reload doit refaire le chemin COMPLET : socle ET règles d'accès. Un
# rechargement partiel rendrait fausse la remédiation que « wg-pi check » affiche.
for etape in access_down base_down base_up access_up; do
  if grep -q "reload).*$etape" "$FW"; then
    ok "verbe reload : $etape"
  else
    ko "verbe reload : $etape manquant"
  fi
done
if grep -q 'up).*base_up.*access_up' "$FW"; then ok "verbe up applique aussi les accès"; else ko "verbe up n applique pas les accès"; fi
if grep -q 'down).*access_down.*base_down' "$FW"; then ok "verbe down retire les accès avant le socle"; else ko "verbe down dans le mauvais ordre"; fi

# Le mode est lu dans le fichier d'accès, et l'acceptation générale du trafic venant du
# VPN n'est posée QUE hors filtrage : sinon elle accepterait tout avant le moteur, et les
# règles seraient sans effet alors que l'interface annoncerait le contraire.
if grep -q '^filtering()' "$FW"; then ok "fonction filtering() présente"; else ko "fonction filtering() absente"; fi
if grep -q 'MODE.*print \$2' "$FW"; then ok "le mode est lu dans le fichier d accès"; else ko "lecture du mode absente"; fi
# L acceptation generale est POSEE sous condition du mode, mais RETIREE sans condition.
# Sans cette asymetrie, elle survivait a une desinstallation faite pendant que le filtrage
# etait actif : access_unswitch la remet pour rouvrir, et base_down refusait de l enlever.
if corps base_up | grep -q 'if ! filtering'; then
  ok "acceptation générale posée seulement hors filtrage"
else
  ko "acceptation générale posée sans condition : le moteur serait court-circuité"
fi
if grep -q '^blanket_del()' "$FW" && corps base_down | grep -q 'blanket_del'; then
  ok "acceptation générale retirée sans condition de mode"
else
  ko "le retrait de l acceptation générale dépend du mode : elle survivrait à une désinstallation"
fi
if grep -q 'FORWARD -i "$WG_IF" -j ACCEPT' "$FW"; then
  if corps rules | grep -q 'j ACCEPT.*WG_IF' ; then
    ko "l acceptation générale est restée dans rules(), donc son retrait dépend du mode"
  else
    ok "l acceptation générale est sortie de rules()"
  fi
fi
if grep -q 'legacy_down()' "$FW"; then ok "retrait des regles de generation precedente"; else ko "legacy_down absent"; fi
if grep -q 'usage : $0 up|down|reload' "$FW"; then ok "message d'usage a jour"; else ko "message d'usage non mis a jour"; fi

echo "-- migration (fw_installed_gen / fw_sync)"
read -r GEN_SCRIPT GEN_FILE < <(
  # shellcheck source=/dev/null
  source "$SRC"; printf '%s %s\n' "$FW_GEN" "$(fw_installed_gen)"
)
check "generation lue dans le fichier = FW_GEN" "$GEN_FILE" "$GEN_SCRIPT"

mv "$FW" "$TMP/garde"
check "fichier absent => generation 0" "$(source "$SRC"; fw_installed_gen)" "0"

# Un pare-feu d'avant le marqueur doit etre vu comme obsolete, pas comme a jour.
grep -v '^# wg-pi-fw-gen: ' "$TMP/garde" > "$FW"
check "pare-feu sans marqueur => generation 0" "$(source "$SRC"; fw_installed_gen)" "0"

# fw_sync lui-meme n etait appele par AUCUN test de run-all.sh. C est pourtant le coeur de
# « wg-pi update » : il n etait exerce que par un test de bout en bout que run-all ne lance
# pas. Tunnel suppose a l arret, pour n avoir aucun rechargement a faire.
syncgen() {   # [--force] : lance fw_sync et rend la generation installee ensuite
  (
    # shellcheck source=/dev/null
    source "$SRC"
    WG_PORT=51820 WG_NET4=10.8.0 WG_NET6=fd00:1234:5678:: IPV6_NAT=0
    LAN_IF=eth0 LAN_IP=192.168.1.50 LAN_GW=192.168.1.1 LAN_NET=192.168.1.0/24
    WGPI_LOCKED=1
    wg_running() { return 1; }
    fw_sync ${1-} >/dev/null 2>&1
    fw_installed_gen
  )
}
check "fw_sync pose la generation courante" "$(syncgen)" "$GEN_SCRIPT"
check "et le fichier reste reserve a root" "$(stat -c '%a' "$FW")" "700"
# A generation egale, fw_sync sort aussitot. Un marqueur depose dans le fichier survit donc
# a un appel nu, et disparait avec « --force » : c est la preuve deterministe des deux
# comportements, la que comparer des dates de modification n aurait rien prouve a la seconde.
echo "# marqueur-de-test" >> "$FW"
syncgen >/dev/null
check "a generation egale, le fichier n est pas reecrit" "$(grep -c '^# marqueur-de-test' "$FW")" "1"
# « --force » regenere quand meme. Sans lui, un Pi passe du Wi-Fi a l Ethernet gardait
# l ancienne interface recopiee dans son pare-feu : le reveil a distance figeait les MAC sur
# une carte disparue, en silence, et les gardes-fous comparaient aux ANCIENNES adresses.
syncgen --force >/dev/null
check "--force regenere a generation egale" "$(grep -c '^# marqueur-de-test' "$FW")" "0"
check "et la generation est toujours la bonne" "$(source "$SRC"; fw_installed_gen)" "$GEN_SCRIPT"

echo
echo "-- IPv6 : coupee pendant le filtrage"
# Le moteur d acces ne filtre que l IPv4. Laisser passer l IPv6 rendrait ses regles
# contournables : deux appareils se joindraient par leur adresse IPv6 du tunnel sans que
# rien ne l examine. Tant que le filtrage est demande, l IPv6 ne traverse donc pas le VPN.
if grep -q "IPV6_ON=" "$FW"; then
  ok "le script genere connait l etat IPv6 du tunnel"
else
  ko "IPV6_ON absent : le script ne peut pas savoir si le tunnel porte de l IPv6"
fi
if grep -q "^v6_block_add()" "$FW" && grep -q "^v6_block_del()" "$FW"; then
  ok "pose et retrait de la coupure IPv6 definis"
else
  ko "la coupure IPv6 n est pas definie"
fi
# Posee SOUS condition du mode...
if corps base_up | grep -q "elif.*IPV6_ON"; then
  ok "coupure posee seulement quand le filtrage est demande"
else
  ko "la coupure IPv6 est posee sans condition de mode"
fi
# ...et retiree SANS condition, comme l acceptation generale : sinon elle survivrait a une
# desinstallation faite pendant que le filtrage etait actif, et couperait l IPv6 d un Pi
# qui n a plus de VPN du tout.
if corps base_down | grep -q "v6_block_del"; then
  ok "coupure IPv6 retiree sans condition de mode"
else
  ko "le retrait de la coupure IPv6 depend du mode : elle survivrait a une desinstallation"
fi
if grep -q -- "-j REJECT --reject-with icmp6-adm-prohibited" "$FW"; then
  ok "le refus IPv6 est un REJECT, pas un DROP"
else
  ko "le refus IPv6 n est pas un REJECT"
fi
# Les deux sens : un paquet entre deux appareils entre ET sort par wg0, mais un paquet
# venu de la maison vers un appareil ne fait que sortir.
for sens in -i -o; do
  if grep -q -- "ip6tables -w -I FORWARD 1 $sens" "$FW"; then
    ok "IPv6 coupee dans le sens $sens"
  else
    ko "IPv6 non coupee dans le sens $sens"
  fi
done

echo
echo "-- le pare-feu genere, EXECUTE sous des commandes simulees"
# Tout ce qui precede verifie le script en le LISANT. Lire ne dit pas ce qu il FAIT : une
# fenetre « grep -A8 » laissait revenir la regression qu elle surveillait, et rien ne
# verifiait ce que « filtering() » REPOND. On l execute donc pour de vrai, avec iptables,
# ip et les autres remplaces par des mouchards, et on regarde les commandes emises.
#
# La liste des associations ARP est detournee : sans cela ce test ecrirait dans le VRAI
# /run/wg-pi de la machine, et son retrait effacerait les entrees d un wg-pi en service.
FWX=$TMP/fw-exec.sh
cp "$FW" "$FWX"
sed -i "s|^ARP_STATE=.*|ARP_STATE='$TMP/arp-figees'|" "$FWX"
grep -q "ARP_STATE='$TMP/arp-figees'" "$FWX" || { echo "  KO   detournement de la liste ARP" >&2; exit 2; }

STUB=$TMP/stub
mkdir -p "$STUB"
for c in iptables ip6tables ip sysctl systemctl conntrack modprobe logger; do
  { echo "#!/bin/sh"
    echo "echo \"\$(basename \"\$0\") \$*\" >> \"\$CMDS\""
    echo "exit 0"
  } > "$STUB/$c"
  chmod +x "$STUB/$c"
done
export CMDS=$TMP/cmds

# lance <verbe> [mode] [ligne du fichier d acces] : mode vide = pas de fichier du tout.
lance() {
  : > "$CMDS"
  rm -f "$TMP/etc/access.conf"
  if [[ -n ${2-} ]]; then
    { echo "V|1"; echo "MODE|$2"; [[ -n ${3-} ]] && echo "$3"; } > "$TMP/etc/access.conf"
  fi
  PATH="$STUB:$PATH" sh "$FWX" "$1" >/dev/null 2>&1
  cat "$CMDS"
}

# L acceptation generale du trafic venant du VPN court-circuiterait le moteur d acces :
# elle ne doit etre POSEE que hors filtrage. C est « -I », l insertion, qui compte — les
# nombreux « -D » sont la boucle de nettoyage qui precede toute pose.
check "hors filtrage, l acceptation generale est posee" \
      "$(lance up ouvert | grep -c -- "-I FORWARD 1 -i wg0 -j ACCEPT")" "1"
check "sous filtrage, elle ne l est PAS" \
      "$(lance up filtre | grep -c -- "-I FORWARD 1 -i wg0 -j ACCEPT")" "0"
# Fichier d acces absent ou abime : on laisse passer plutot que de tout couper.
check "sans fichier d acces, elle est posee" \
      "$(lance up | grep -c -- "-I FORWARD 1 -i wg0 -j ACCEPT")" "1"
# Un mode inconnu n est pas « filtre » : meme prudence.
check "mode inconnu : elle est posee" \
      "$(lance up nimporte | grep -c -- "-I FORWARD 1 -i wg0 -j ACCEPT")" "1"
# Et le retrait est INCONDITIONNEL : sinon elle survivait a une desinstallation faite
# pendant que le filtrage etait actif.
check "le retrait a lieu hors filtrage" \
      "$([[ $(lance down ouvert | grep -c -- "-D FORWARD -i wg0 -j ACCEPT") -ge 1 ]] && echo oui || echo non)" "oui"
check "et sous filtrage aussi" \
      "$([[ $(lance down filtre | grep -c -- "-D FORWARD -i wg0 -j ACCEPT") -ge 1 ]] && echo oui || echo non)" "oui"

# La repose ARP, de bout en bout : le fichier dit une MAC, le noyau doit la recevoir.
MAC_LIGNE="RES|nas|Le NAS|192.168.1.20|aa:bb:cc:dd:ee:ff"
check "la MAC du fichier atteint ip neigh" \
      "$(lance up filtre "$MAC_LIGNE" | grep -c "ip neigh replace 192.168.1.20 lladdr aa:bb:cc:dd:ee:ff dev eth0 nud permanent")" "1"
check "et la liste note ce qui a ete fige" "$(cat "$TMP/arp-figees" 2>/dev/null)" "192.168.1.20"
# Le retrait : seulement ce que NOUS avons fige, et rien d autre. Une entree permanente
# posee par l administrateur contre l usurpation ARP ne doit pas disparaitre.
echo "192.168.1.99" >> "$TMP/arp-figees"
: > "$CMDS"
PATH="$STUB:$PATH" sh "$FWX" down >/dev/null 2>&1
check "le retrait porte sur les deux adresses de la liste" "$(grep -c "ip neigh del" "$CMDS")" "2"
check "et sur rien d autre : le noyau n est jamais interroge" "$(grep -c "ip neigh show" "$CMDS")" "0"
check "la liste est videe apres le retrait" \
      "$([[ -e $TMP/arp-figees ]] && echo reste || echo videe)" "videe"
# Une ressource sans MAC ne fige rien, et un reseau entier non plus : une plage n a pas
# de carte reseau.
check "une ressource sans MAC ne fige rien" \
      "$(lance up filtre "RES|nas|Le NAS|192.168.1.20" | grep -c "ip neigh replace")" "0"
check "un reseau entier ne fige rien" \
      "$(lance up filtre "RES|r|Le reseau|192.168.1.0/24|aa:bb:cc:dd:ee:ff" | grep -c "ip neigh replace")" "0"
# Les deux adresses qui briqueraient le Pi sont refusees a l execution aussi, pas seulement
# a la saisie : figer une MAC fausse sur la passerelle coupe le reseau sans retour.
check "la passerelle est refusee a l execution" \
      "$(lance up filtre "RES|box|La box|192.168.1.1|aa:bb:cc:dd:ee:ff" | grep -c "ip neigh replace")" "0"
check "le Pi lui-meme aussi" \
      "$(lance up filtre "RES|soi|Le Pi|192.168.1.50|aa:bb:cc:dd:ee:ff" | grep -c "ip neigh replace")" "0"

# La coupure IPv6 : posee seulement sous filtrage, et seulement si l IPv6 est active dans
# le noyau — d ou une copie dediee, le script de reference etant genere avec IPV6_ON vide.
FWV6=$TMP/fw-exec-v6.sh
cp "$FWX" "$FWV6"
sed -i "s|^IPV6_ON=.*|IPV6_ON='1'|" "$FWV6"
lance6() {
  : > "$CMDS"
  rm -f "$TMP/etc/access.conf"
  { echo "V|1"; echo "MODE|$1"; } > "$TMP/etc/access.conf"
  PATH="$STUB:$PATH" sh "$FWV6" up >/dev/null 2>&1
  cat "$CMDS"
}
# Les deux sens : un appareil ne doit ni joindre ni etre joint en IPv6 par le tunnel,
# sinon le moteur, qui ne filtre que l IPv4, serait contournable.
check "sous filtrage, l IPv6 est coupee dans le sens entrant" \
      "$(lance6 filtre | grep -c -- "ip6tables .*-I FORWARD 1 -i wg0 -j REJECT")" "1"
check "et dans le sens sortant" \
      "$(lance6 filtre | grep -c -- "ip6tables .*-I FORWARD 1 -o wg0 -j REJECT")" "1"
check "hors filtrage, elle ne l est pas" \
      "$(lance6 ouvert | grep -c -- "ip6tables .*-I FORWARD 1")" "0"

# Et le verbe arp : il libere puis repose, sans toucher au reste du pare-feu.
ARPSORTIE=$(lance arp filtre "$MAC_LIGNE")
check "le verbe arp repose l association" \
      "$(printf '%s' "$ARPSORTIE" | grep -c "ip neigh replace 192.168.1.20")" "1"
check "et ne touche pas aux regles de pare-feu" \
      "$(printf '%s' "$ARPSORTIE" | grep -c "^iptables")" "0"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
