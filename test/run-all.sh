#!/usr/bin/env bash
# Lance toute la vérification. Renvoie un code de sortie non nul si une étape échoue,
# mais exécute toutes les étapes : on veut la liste complète des problèmes, pas le premier.
set -uo pipefail
cd "$(dirname "$0")"

rc=0
for t in lint helpers access cli-access engine apply json ui role detect-reachability firewall heredoc; do
  # Appel par « bash » et non « ./ » : ce depot est alimente par depot manuel, et
  # l upload web de GitHub ne conserve pas le bit executable. Ne rien en faire
  # dependre evite un echec en « Permission denied » des le premier envoi.
  bash "./$t.sh" "$@" || rc=1
  echo
done

if (( rc )); then
  echo "VÉRIFICATION : ÉCHEC"
else
  echo "VÉRIFICATION : tout est passé"
fi
exit $rc
