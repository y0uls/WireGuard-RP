#!/usr/bin/env bash
# Vérifie le code embarqué dans le heredoc de l'interface web : ~1000 lignes de Python et
# ~450 de JavaScript que « bash -n » et « shellcheck » ne voient pas du tout — pour eux,
# c'est un littéral opaque. Une accolade non fermée passait donc la CI en vert et ne
# cassait qu'au démarrage du panneau, chez l'utilisateur.
#
# Usage : ./heredoc.sh [chemin/vers/wg-pi.sh]
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

pass=0 fail=0
ok() { printf '  OK   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  KO   %s\n' "$1"; fail=$((fail + 1)); }

echo "-- code embarqué dans le heredoc"

# web_app_source écrit le source Python du panneau sur la sortie standard.
( source "$SRC"; web_app_source ) > "$TMP/app.py" 2>"$TMP/err" || { ko "web_app_source a échoué : $(cat "$TMP/err")"; }
if [[ -s $TMP/app.py ]]; then
  ok "extraction du Python ($(wc -l <"$TMP/app.py") lignes)"
else
  ko "extraction du Python vide"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -m py_compile "$TMP/app.py" 2>"$TMP/err"; then
    ok "python3 -m py_compile"
  else
    ko "python3 -m py_compile :"; sed 's/^/       /' "$TMP/err"
  fi
else
  echo "  --   python3 absent, compilation ignorée"
fi

# Les chaînes APP_JS, THEME_JS et CSS sont des littéraux Python : on les extrait par ast,
# sans exécuter le panneau.
njs=0
if command -v python3 >/dev/null 2>&1; then
  njs=$(python3 - "$TMP/app.py" "$TMP" <<'PYX'
import ast, sys, os
src, out = sys.argv[1], sys.argv[2]
tree = ast.parse(open(src, encoding='utf-8').read())
found = {}
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1:
        t = node.targets[0]
        if isinstance(t, ast.Name) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            found[t.id] = node.value.value
for name in ('APP_JS', 'THEME_JS'):
    if name in found:
        open(os.path.join(out, name + '.js'), 'w', encoding='utf-8').write(found[name])
print(len([1 for n in ('APP_JS', 'THEME_JS') if n in found]))
PYX
  )
  if [[ ${njs:-0} -gt 0 ]]; then
    ok "extraction de $njs littéral(aux) JavaScript"
  else
    ko "aucun littéral JavaScript extrait du Python"
  fi
fi

if command -v node >/dev/null 2>&1; then
  for js in "$TMP"/*.js; do
    [[ -f $js ]] || continue
    if node --check "$js" 2>"$TMP/err"; then
      ok "node --check $(basename "$js")"
    else
      ko "node --check $(basename "$js") :"; sed 's/^/       /' "$TMP/err"
    fi
  done

  # Deux fonctions de meme nom dans la meme portee : la seconde ecrase la premiere, en
  # silence. « node --check » ne voit rien, et les appels ecrits pour la premiere partent
  # avec la mauvaise signature.
  if node ./lib/doublons.js "$TMP"/*.js >"$TMP/dbl" 2>&1; then
    ok "aucune fonction déclarée deux fois dans la même portée"
  else
    ko "fonction déclarée deux fois (la seconde écrase la première) :"
    sed "s/^/       /" "$TMP/dbl"
  fi
else
  echo "  --   node absent, vérification du JavaScript ignorée"
fi

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
