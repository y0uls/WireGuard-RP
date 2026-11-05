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

# Génère le pare-feu avec des réglages connus, puis rend le chemin du fichier produit.
generate() {  # $1 = IPV6_NAT
  (
    # shellcheck source=/dev/null
    source "$SRC"
    WG_PORT=51820 WG_NET4=10.8.0 WG_NET6=fd00:1234:5678:: IPV6_NAT=$1
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
if grep -A16 '^base_up()' "$FW" | grep -q 'if ! filtering'; then
  ok "acceptation générale posée seulement hors filtrage"
else
  ko "acceptation générale posée sans condition : le moteur serait court-circuité"
fi
if grep -q '^blanket_del()' "$FW" && grep -A3 '^base_down()' "$FW" | grep -q 'blanket_del'; then
  ok "acceptation générale retirée sans condition de mode"
else
  ko "le retrait de l acceptation générale dépend du mode : elle survivrait à une désinstallation"
fi
if grep -q 'FORWARD -i "$WG_IF" -j ACCEPT' "$FW"; then
  if grep -A8 '^rules()' "$FW" | grep -q 'j ACCEPT.*WG_IF' ; then
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

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
