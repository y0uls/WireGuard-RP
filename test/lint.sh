#!/usr/bin/env bash
# Reproduit les contrôles de la CI (.github/workflows/shellcheck.yml) sur le script.
# Usage : ./lint.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

rc=0
echo "── Contrôles de forme sur $SCRIPT"

if grep -q $'\r' "$SCRIPT"; then
  echo "  ✖ Le fichier contient des fins de ligne Windows (CRLF) : il ne s'exécutera pas sur le Pi."
  rc=1
else
  echo "  ✔ Fins de ligne Unix (LF)"
fi

if bash -n "$SCRIPT" 2>/dev/null; then
  echo "  ✔ Syntaxe bash"
else
  echo "  ✖ Syntaxe bash :"; bash -n "$SCRIPT"; rc=1
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$SCRIPT"; then
    echo "  ✔ ShellCheck (sévérité warning)"
  else
    echo "  ✖ ShellCheck"; rc=1
  fi
else
  echo "  ⚠ ShellCheck absent, contrôle ignoré (sudo apt install shellcheck)"
fi

exit $rc
