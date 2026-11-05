#!/usr/bin/env bash
# Exécute le JavaScript du panneau web sous node, avec un DOM simulé.
#
# « node --check » ne fait que parser : une variable non déclarée ou un appel sur undefined
# passent au vert et ne cassent qu'au premier rafraîchissement, chez l'utilisateur, après
# un curl | sudo bash. Ce test fait TOURNER le rendu.
#
# Usage : ./ui.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

if ! command -v node >/dev/null 2>&1; then
  echo "-- interface web"
  echo "  --   node absent, exécution du JavaScript ignorée"
  exit 0
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
head -n -1 "$SCRIPT" > "$SRC"

echo "-- interface web (exécutée sous node)"

# Le source Python du panneau, puis le littéral APP_JS extrait par ast : aucune exécution
# du panneau, seulement une lecture de son code.
( source "$SRC"; web_app_source ) > "$TMP/app.py" 2>"$TMP/err" || {
  echo "  KO   extraction du panneau impossible : $(cat "$TMP/err")"; exit 1; }

python3 - "$TMP/app.py" "$TMP/app.js" <<'PYX'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding='utf-8').read())
for node in tree.body:
    if (isinstance(node, ast.Assign) and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'APP_JS'
            and isinstance(node.value, ast.Constant)):
        open(sys.argv[2], 'w', encoding='utf-8').write(node.value.value)
        sys.exit(0)
sys.exit("APP_JS introuvable dans le source du panneau")
PYX

[[ -s $TMP/app.js ]] || { echo "  KO   APP_JS vide"; exit 1; }
node lib/ui-run.js "$TMP/app.js"
