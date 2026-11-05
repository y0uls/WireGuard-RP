#!/usr/bin/env bash
# Tests de la couche d'accès : lecture, requêtes, validation de saisie, et surtout la
# purge des références mortes et la stabilité du fichier écrit.
#
# STATE_DIR est redirigé vers un dossier temporaire et peers_table est remplacée par une
# liste d'appareils connue : rien ne touche /etc/wg-pi, ces tests sont donc sans danger
# sur un Pi en production.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./access.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
mkdir -p "$TMP/etc"

sed "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" "$SCRIPT" > "$TMP/full.sh"
grep -q "STATE_DIR='$TMP/etc'" "$TMP/full.sh" || { echo "Redirection de STATE_DIR echouee" >&2; exit 2; }
if [[ $(tail -n1 "$TMP/full.sh") == 'main "$@"' ]]; then
  head -n -1 "$TMP/full.sh" > "$SRC"
else
  cp "$TMP/full.sh" "$SRC"
fi

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

# Charge le script et remplace peers_table par une liste d'appareils fixe. Tout le reste
# du code exécuté est le vrai.
load() {
  # shellcheck source=/dev/null
  source "$SRC"
  peers_table() {
    echo "telephone 10.8.0.2 KEY1 on"
    echo "pc-salon 10.8.0.3 KEY2 on"
    echo "tablette 10.8.0.4 KEY3 off"
  }
  LAN_NET="192.168.1.0/24"
}

ACC=$TMP/etc/access.conf

echo "-- lecture par défaut (aucun fichier)"
rm -f "$ACC"
eq "contenu par défaut" "$(load; access_cat)" "V|1
MODE|ouvert"
eq "mode par défaut" "$(load; access_mode)" "ouvert"
eq "le groupe « tous » existe toujours" "$(load; access_group_exists tous && echo oui)" "oui"
eq "un groupe inconnu n existe pas" "$(load; access_group_exists inconnu || echo non)" "non"

echo "-- un fichier illisible ne doit jamais déclencher un filtrage"
: > "$ACC"
eq "fichier vide donne ouvert" "$(load; access_mode)" "ouvert"
echo "n importe quoi" > "$ACC"
eq "fichier incohérent donne ouvert" "$(load; access_mode)" "ouvert"
echo "MODE|FILTRE" > "$ACC"
eq "casse différente donne ouvert" "$(load; access_mode)" "ouvert"
echo "MODE|filtre" > "$ACC"
eq "mode filtre reconnu" "$(load; access_mode)" "filtre"

echo "-- requêtes"
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|confiance|Appareils de confiance"
  echo "GROUP|invites|Invités « amis »"
  echo "RES|nas|NAS de la maison|192.168.1.20"
  echo "MEMBER|telephone|confiance"
  echo "MEMBER|pc-salon|confiance"
  echo "MEMBER|tablette|invites"
} > "$ACC"

eq "lignes GROUP" "$(load; access_rows GROUP)" "confiance|Appareils de confiance
invites|Invités « amis »"
eq "libellé accentué préservé" "$(load; access_group_label invites)" "Invités « amis »"
eq "libellé du groupe virtuel" "$(load; access_group_label tous)" "Tous les appareils"
eq "libellé par défaut si inconnu" "$(load; access_group_label zzz)" "zzz"
eq "cible d une ressource" "$(load; access_res_target nas)" "192.168.1.20"
eq "appareils d un groupe" "$(load; access_group_devices confiance)" "pc-salon
telephone"
eq "appareils de tous" "$(load; access_group_devices tous)" "telephone
pc-salon
tablette"
eq "groupes d un appareil, tous compris" "$(load; access_device_groups telephone)" "confiance
tous"
eq "un appareil sans groupe reste dans tous" "$(load; access_device_groups inconnu)" "tous"

echo "-- libellés de destination"
eq "internet" "$(load; access_dest_label internet)" "Internet"
eq "maison avec le réseau réel" "$(load; access_dest_label maison)" "Le réseau de la maison (192.168.1.0/24)"
eq "ressource" "$(load; access_dest_label res:nas)" "NAS de la maison (192.168.1.20)"
eq "groupe" "$(load; access_dest_label grp:invites)" "Le groupe « Invités « amis » »"
eq "ports vides" "$(load; access_ports_label '')" "tous les ports"
eq "ports listés" "$(load; access_ports_label 445,5000-5001)" "445, 5000-5001"

echo "-- validation de saisie"
v() { if ( load; "$1" "$2" ) 2>/dev/null; then echo oui; else echo non; fi; }
eq "port simple valide"          "$(v access_valid_ports 445)" oui
eq "liste et plage valides"      "$(v access_valid_ports 445,5000-5001)" oui
eq "liste vide valide"           "$(v access_valid_ports '')" oui
eq "port 0 refusé"               "$(v access_valid_ports 0)" non
eq "port 70000 refusé"           "$(v access_valid_ports 70000)" non
eq "plage inversée refusée"      "$(v access_valid_ports 9000-8000)" non
eq "texte refusé"                "$(v access_valid_ports abc)" non
eq "budget multiport 15 accepté" "$(v access_valid_ports 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)" oui
eq "budget multiport 16 refusé"  "$(v access_valid_ports 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)" non
eq "7 plages font 14, accepté"   "$(v access_valid_ports 1-2,3-4,5-6,7-8,9-10,11-12,13-14)" oui
eq "8 plages font 16, refusé"    "$(v access_valid_ports 1-2,3-4,5-6,7-8,9-10,11-12,13-14,15-16)" non
eq "proto tcp"                   "$(v access_valid_proto tcp)" oui
eq "proto inconnu refusé"        "$(v access_valid_proto sctp)" non
eq "sens aller"                  "$(v access_valid_dir aller)" oui
eq "sens inconnu refusé"         "$(v access_valid_dir retour)" non
eq "cible ip"                    "$(v access_valid_target 192.168.1.20)" oui
eq "cible cidr"                  "$(v access_valid_target 192.168.1.0/24)" oui
eq "cidr aberrant refusé"        "$(v access_valid_target 192.168.1.0/33)" non
eq "cible texte refusée"         "$(v access_valid_target nas)" non
eq "destination internet"        "$(v access_valid_dest internet)" oui
eq "destination ressource"       "$(v access_valid_dest res:nas)" oui
eq "destination inconnue"        "$(v access_valid_dest ailleurs)" non

echo "-- écriture : purge des références mortes"
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|confiance|Appareils de confiance"
  echo "GROUP|tous|Tentative de redéfinir le groupe virtuel"
  echo "RES|nas|NAS|192.168.1.20"
  echo "MEMBER|telephone|confiance"
  echo "MEMBER|telephone|confiance"
  echo "MEMBER|disparu|confiance"
  echo "MEMBER|pc-salon|groupe-supprime"
  echo "POLICY|p1|1|grp:confiance|res:nas|tcp|445|aller|Partages"
  echo "POLICY|p2|1|grp:confiance|res:supprimee|any||aller|Ressource disparue"
  echo "POLICY|p3|1|grp:disparu|internet|any||aller|Groupe disparu"
  echo "POLICY|p4|1|grp:tous|internet|any||aller|Depuis le groupe virtuel"
} | ( load; access_save )

eq "fichier écrit, ordonné et purgé" "$(grep -v '^#' "$ACC")" "V|1
MODE|ouvert
GROUP|confiance|Appareils de confiance
RES|nas|NAS|192.168.1.20
MEMBER|telephone|confiance
POLICY|p1|1|grp:confiance|res:nas|tcp|445|aller|Partages
POLICY|p4|1|grp:tous|internet|any||aller|Depuis le groupe virtuel"

echo "-- écriture : idempotence et droits"
cp "$ACC" "$TMP/avant"
( load; access_cat | access_save )
if cmp -s "$TMP/avant" "$ACC"; then
  ok "réécrire le fichier ne le change pas"
else
  ko "le fichier change à chaque écriture"
  diff "$TMP/avant" "$ACC" | head -5
fi
MODE=$(stat -c '%a' "$ACC")
if [[ $MODE == 600 ]]; then ok "droits 600"; else ko "droits $MODE au lieu de 600"; fi

echo "-- un champ vide ne décale pas les suivants"
# C est la raison du séparateur « | » plutôt que la tabulation : une règle sans port doit
# garder « aller » dans le champ sens, et pas dans le champ ports.
{
  echo "V|1"
  echo "MODE|ouvert"
  echo "GROUP|g|G"
  echo "POLICY|px|1|grp:g|internet|any||aller|Sans port"
} | ( load; access_save )
eq "le sens reste dans son champ" "$(load; access_rows POLICY | awk -F'|' '{ print $7 }')" "aller"
eq "le champ ports reste vide" "$(load; access_rows POLICY | awk -F'|' '{ print "[" $6 "]" }')" "[]"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
