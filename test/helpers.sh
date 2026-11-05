#!/usr/bin/env bash
# Tests des fonctions utilitaires : json_esc et atomic_write.
#
# json_esc est vérifié en construisant un vrai document JSON et en le faisant analyser par
# python3 : c'est la seule preuve qui compte, les échappements de bash étant faciles à
# écrire de travers sans que rien ne le signale.
#
# Ce fichier ne contient volontairement aucun backslash : les caractères délicats sont
# fabriqués à l'exécution par awk, pour qu'aucun outil d'édition ne puisse les altérer.
#
# Usage : ./helpers.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
if [[ $(tail -n1 "$SCRIPT") == 'main "$@"' ]]; then
  head -n -1 "$SCRIPT" > "$SRC"
else
  cp "$SCRIPT" "$SRC"
fi

BS=$(awk 'BEGIN{ printf "%c", 92 }')   # un backslash
DQ=$(awk 'BEGIN{ printf "%c", 34 }')   # un guillemet double
TAB=$(awk 'BEGIN{ printf "%c", 9 }')   # une tabulation

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }

echo "-- json_esc"

# Chaque cas produit {"x":"<valeur échappée>"} et doit être analysable par json.loads,
# en rendant exactement la valeur de départ.
jtest() {  # jtest <libellé> <valeur brute> [valeur attendue après analyse]
  local nom=$1 brut=$2 attendu=${3-$2} esc got
  esc=$(
    # shellcheck source=/dev/null
    source "$SRC"
    json_esc "$brut"
  )
  if ! got=$(printf '{"x":"%s"}' "$esc" |
      python3 -c "import json,sys; print(json.load(sys.stdin)['x'], end='')" 2>/dev/null); then
    ko "$nom : JSON invalide (échappé : $esc)"
    return 0
  fi
  if [[ $got == "$attendu" ]]; then ok "$nom"; else ko "$nom (rendu : $got / attendu : $attendu)"; fi
}

jtest "texte simple avec accents"     "Invités de passage"
jtest "guillemets"                    "Invités ${DQ}amis${DQ}"
jtest "backslash"                     "C:${BS}chemin"
jtest "backslash puis guillemet"      "a${BS}${DQ}b"
jtest "deux backslashes"              "a${BS}${BS}b"
jtest "backslash final"               "fin${BS}"
jtest "tabulation remplacée"          "a${TAB}b"                "a b"
jtest "chaîne vide"                   ""

echo "-- atomic_write"
DEST=$TMP/cible
echo avant > "$DEST"
chmod 600 "$DEST"

if echo apres | ( source "$SRC"; atomic_write "$DEST" ); then
  if [[ $(cat "$DEST") == apres ]]; then ok "écriture remplacée"; else ko "contenu non remplacé"; fi
else
  ko "atomic_write a échoué sur une écriture valide"
fi

MODE=$(stat -c '%a' "$DEST")
if [[ $MODE == 600 ]]; then ok "droits conservés ($MODE)"; else ko "droits perdus : $MODE"; fi

# Un générateur qui ne produit rien ne doit jamais installer un fichier vide : sans ce
# garde-fou, un awk en échec effacerait wg0.conf, donc la clé du serveur et les appareils.
if printf '' | ( source "$SRC"; atomic_write "$DEST" ) 2>/dev/null; then
  ko "entrée vide acceptée : la cible aurait été vidée"
else
  if [[ $(cat "$DEST") == apres ]]; then ok "entrée vide refusée, cible intacte"; else ko "cible abîmée"; fi
fi

# Avec des droits explicites, atomic_write doit les imposer et non conserver ceux du
# fichier existant : un fichier cree a la main en 644 doit etre remis en 600.
chmod 644 "$DEST"
if echo encore | ( source "$SRC"; atomic_write "$DEST" 600 ); then
  MODE2=$(stat -c '%a' "$DEST")
  if [[ $MODE2 == 600 ]]; then ok "droits imposes (644 ramene a 600)"; else ko "droits non imposes : $MODE2"; fi
else
  ko "atomic_write a echoue avec des droits explicites"
fi

LEFT=$(find "$TMP" -maxdepth 1 -name '.cible.*' | wc -l)
if [[ $LEFT -eq 0 ]]; then ok "aucun fichier temporaire laissé"; else ko "$LEFT fichier(s) temporaire(s)"; fi

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
