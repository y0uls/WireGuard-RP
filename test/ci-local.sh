#!/usr/bin/env bash
# Rejoue, étape par étape, ce que fait .github/workflows/shellcheck.yml.
#
# Pourquoi un script et pas une commande dans un README : la version en une ligne a été
# fausse DEUX fois. Elle oubliait `nodejs`, si bien que les tests du panneau sautaient en
# silence et que tout paraissait vert ; puis son contrôle des fins de ligne recevait `\r`
# littéral après trois couches de guillemets, et signalait donc TOUS les fichiers. Une
# logique qu'on ne peut pas exécuter pour la vérifier finit toujours par mentir.
#
# Ce fichier n'est PAS lancé par run-all.sh : il le lance.
#
# Usage : bash test/ci-local.sh        (depuis la racine du dépôt, ou depuis test/)
set -uo pipefail
cd "$(dirname "$0")/.."

rc=0
echo "── Outils requis"
# Exigés, pas espérés : sans node, ui.sh et heredoc.sh ne TOMBENT pas, ils SAUTENT et
# rendent 0. Mesuré en retirant node : la suite annonce « tout est passé » avec 257
# assertions évaporées. Une CI verte qui n'a rien vérifié du panneau est le pire résultat.
for o in bash node python3 shellcheck; do
  if command -v "$o" >/dev/null 2>&1; then
    printf '  ✔ %-11s %s\n' "$o" "$("$o" --version 2>&1 | head -n1)"
  else
    echo "  ✖ $o est absent : des tests seraient silencieusement sautés."
    rc=1
  fi
done

echo "── Fins de ligne Unix (LF)"
# La liste vient de git, comme dans le workflow : ce sont les fichiers DÉPOSÉS qui comptent,
# et non ce qui traîne dans l'arbre de travail. Sans dépôt git, on retombe sur les chemins
# connus — et on le dit, pour que personne ne prenne ce repli pour le vrai contrôle.
fichiers=$(git ls-files '*.sh' '*.js' '*.md' '*.yml' 2>/dev/null || true)
if [[ -z $fichiers ]]; then
  echo "  ⚠ pas de dépôt git ici : repli sur les chemins connus (la CI, elle, lit git)."
  fichiers=$(find . wg-pi.sh -maxdepth 3 \( -name '*.sh' -o -name '*.js' -o -name '*.md' -o -name '*.yml' \) \
             -not -path './.git/*' -not -path './.claude/*' 2>/dev/null | sort -u)
fi
crlf=0
while IFS= read -r f; do
  [[ -n $f && -f $f ]] || continue
  # Un vrai retour chariot, produit par printf : écrit « \r » à la main dans un motif, il
  # est lu comme la lettre « r » en expression rationnelle de base — et tout fichier
  # contenant un « r » est alors signalé. C'est exactement ce qui est arrivé.
  if grep -q "$(printf '\r')" "$f"; then
    echo "  ✖ $f : fins de ligne Windows (CRLF)"
    crlf=1
  fi
done <<<"$fichiers"
(( crlf )) && rc=1
(( crlf )) || echo "  ✔ toutes en LF ($(printf '%s\n' "$fichiers" | grep -c .) fichiers)"

echo "── Syntaxe bash"
if bash -n wg-pi.sh 2>/dev/null; then echo "  ✔ wg-pi.sh"; else echo "  ✖ wg-pi.sh :"; bash -n wg-pi.sh; rc=1; fi

echo "── ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning wg-pi.sh; then echo "  ✔ sévérité warning"; else rc=1; fi
fi

echo "── Suite de tests"
bash ./test/run-all.sh || rc=1

echo
if (( rc )); then echo "CI LOCALE : ÉCHEC"; else echo "CI LOCALE : tout est passé"; fi
exit $rc
