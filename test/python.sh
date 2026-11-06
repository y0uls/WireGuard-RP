#!/usr/bin/env bash
# Tests du Python du panneau web, EXÉCUTÉ et non relu.
#
# `test/heredoc.sh` se contentait de le compiler : une fonction pouvait devenir muette, ou
# changer de réponse, sans qu'aucun test ne tombe. Or ce Python décide ce que l'utilisateur
# voit — un refus sans son explication, un avertissement jeté, une règle acceptée alors
# qu'elle est invalide.
#
# Le module s'importe sans aucun effet de bord : rien n'est lu, rien n'est écouté, aucun
# fichier n'est touché. Ses fonctions pures sont donc directement appelables.
#
# Usage : ./python.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "-- Python du panneau"
  echo "  --   python3 absent, tests ignorés"
  exit 0
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
if [[ $(tail -n1 "$SCRIPT") == 'main "$@"' ]]; then
  head -n -1 "$SCRIPT" > "$SRC"
else
  cp "$SCRIPT" "$SRC"
fi

# shellcheck source=/dev/null
( source "$SRC"; web_app_source ) > "$TMP/app.py" 2>"$TMP/err"
[[ -s $TMP/app.py ]] || { echo "Extraction du Python impossible : $(cat "$TMP/err")" >&2; exit 2; }

cat > "$TMP/essai.py" <<'PYEOF'
"""Exercice des fonctions pures du panneau. Rend un code non nul si une assertion échoue."""
import sys
import types

sys.argv = ["app.py"]
import app  # noqa: E402  (le chemin est posé par le lanceur)

reussis = 0
echoues = 0


def eq(nom, obtenu, attendu):
    global reussis, echoues
    if obtenu == attendu:
        print("  OK   " + nom)
        reussis += 1
    else:
        print("  KO   " + nom)
        print("       obtenu  : [" + repr(obtenu) + "]")
        print("       attendu : [" + repr(attendu) + "]")
        echoues += 1


# ---------------------------------------------------------------- avertissements
# Les « warn » du CLI sortent sur la sortie standard, mêlés aux succès. Les jeter laissait
# l'utilisateur découvrir seul qu'une ressource est hors du réseau, ou qu'une règle bloque
# le DNS de sa box. Rendre cette fonction muette ne faisait tomber aucun test.
print("-- avertissements : garder les lignes marquées, et rien d'autre")
eq("texte vide", app.avertissements(""), "")
eq("texte sans marqueur", app.avertissements("Regle enregistree\nTout va bien"), "")
eq("une ligne marquee est gardee",
   app.avertissements("Regle enregistree\n⚠  Sans Internet : « a »"),
   "Sans Internet : « a »")
eq("deux lignes sont jointes par une espace",
   app.avertissements("⚠ premier\nsucces\n⚠ second"),
   "premier second")
eq("les marqueurs en tete et les espaces sont retires",
   app.avertissements("⚠ ⚠ double marqueur"), "⚠ double marqueur")
eq("les codes de couleur sont retires",
   app.avertissements("\x1b[33m⚠ colore\x1b[0m"), "colore")
eq("une ligne de succes seule ne donne rien",
   app.avertissements("✔ Regle enregistree"), "")
# La troncature porte sur les CARACTÈRES et non sur les octets : couper au milieu d'un
# caractère accentué produirait un JSON invalide, donc un panneau entièrement blanc.
long_accentue = "⚠ " + ("é" * 500)
tronque = app.avertissements(long_accentue)
eq("la troncature tient 400 caracteres", len(tronque), 400)
eq("et ne coupe aucun caractere en deux", tronque, "é" * 400)
eq("le resultat reste encodable en UTF-8", tronque.encode("utf-8").decode("utf-8"), tronque)


# ---------------------------------------------------------------- message_erreur
# Le refus du CLI et son explication ne sortent pas au même endroit : « fail » sur la
# sortie d'erreur, « txt » sur la sortie standard. Ne lire que la première affichait le
# « non » sans le « comment faire ».
print("")
print("-- message_erreur : le refus ET son explication")


def faux_processus(sortie, erreur):
    return types.SimpleNamespace(stdout=sortie, stderr=erreur, returncode=1)


eq("les deux sorties sont reunies, l erreur d abord",
   app.message_erreur(faux_processus("Posez une regle d abord.", "Aucune regle enregistree.")),
   "Aucune regle enregistree. Posez une regle d abord.")
eq("l explication seule suffit",
   app.message_erreur(faux_processus("Explication", "")), "Explication")
eq("les marqueurs sont retires",
   app.message_erreur(faux_processus("", "✖ Refuse")), "Refuse")
eq("deux sorties vides donnent un message par defaut",
   app.message_erreur(faux_processus("", "")), "Erreur inconnue.")
eq("une sortie absente ne fait pas planter",
   app.message_erreur(faux_processus(None, None)), "Erreur inconnue.")


# ---------------------------------------------------------------- valider_regle
# Contrôle de FORME d'une règle venue du panneau. C'est la seule barrière avant le CLI
# pour une requête forgée à la main : le panneau n'est pas la seule façon d'atteindre la
# route.
print("")
print("-- valider_regle : la forme d une regle")


def valide(**kw):
    base = {"source": "jeu", "destination": "internet"}
    base.update(kw)
    champs, err = app.valider_regle(base)
    return err


eq("une regle minimale est acceptee", valide(), None)
eq("et ses valeurs par defaut sont posees",
   app.valider_regle({"source": "jeu", "destination": "internet"})[0],
   {"src": "jeu", "dst": "internet", "proto": "any", "ports": "", "sens": "aller", "lib": ""})
# Les ports absents restent une chaîne VIDE et non None : la modification les passe toujours,
# même vides, car c'est le seul moyen d'annuler une restriction depuis le panneau.
eq("les ports absents sont une chaine vide",
   app.valider_regle({"source": "jeu", "destination": "internet"})[0]["ports"], "")

eq("un groupe source vide est refuse", valide(source=""), "Groupe source invalide.")
eq("un groupe source avec un tiret en tete est refuse", valide(source="-x"), "Groupe source invalide.")
eq("un groupe source trop long est refuse", valide(source="a" * 16), "Groupe source invalide.")
eq("un groupe source avec une espace est refuse", valide(source="a b"), "Groupe source invalide.")

for d in ("tout", "internet", "maison", "pi", "res:nas", "grp:jeu"):
    eq("destination " + d + " acceptee", valide(destination=d), None)
eq("une destination inventee est refusee", valide(destination="ailleurs"), "Destination invalide.")
eq("un prefixe sans nom est refuse", valide(destination="res:"), "Destination invalide.")
eq("un prefixe inconnu est refuse", valide(destination="svc:x"), "Destination invalide.")

for p in ("any", "tcp", "udp", "tcpudp", "icmp"):
    eq("protocole " + p + " accepte", valide(proto=p), None)
eq("un protocole inconnu est refuse", valide(proto="sctp"), "Protocole invalide.")
# tcpudp est nouveau : le refuser ici rendrait le modele « Jeu en reseau » du panneau
# inutilisable, et la commande documentee dans le README mourrait sur « Protocole invalide ».
eq("tcpudp accepte des ports", valide(proto="tcpudp", ports="27015,27036"), None)

eq("un port simple est accepte", valide(ports="445"), None)
eq("une plage est acceptee", valide(ports="5000-5001"), None)
eq("une liste melangee est acceptee", valide(ports="445,5000-5001,139"), None)
eq("une virgule en trop est refusee", valide(ports="445,"),
   "Liste de ports invalide. Exemples : 445 ou 445,5000-5001.")
eq("un port non numerique est refuse", valide(ports="http"),
   "Liste de ports invalide. Exemples : 445 ou 445,5000-5001.")
eq("une espace dans les ports est refusee", valide(ports="445, 139"),
   "Liste de ports invalide. Exemples : 445 ou 445,5000-5001.")

eq("le sens aller est accepte", valide(sens="aller"), None)
eq("le sens deux est accepte", valide(sens="deux"), None)
eq("un sens invente est refuse", valide(sens="retour"), "Sens invalide.")

eq("un libelle accentue est accepte", valide(libelle="Règle « spéciale »"), None)
eq("un libelle de 60 caracteres est accepte", valide(libelle="a" * 60), None)
eq("un libelle de 61 caracteres est refuse", valide(libelle="a" * 61),
   "Libellé invalide : au plus 60 caractères, sans barre verticale.")
# La barre verticale est le séparateur d'access.conf : la laisser passer couperait la ligne
# en deux et le fichier deviendrait illisible.
eq("une barre verticale est refusee", valide(libelle="a|b"),
   "Libellé invalide : au plus 60 caractères, sans barre verticale.")
eq("un caractere de controle est refuse", valide(libelle="a\tb"),
   "Libellé invalide : au plus 60 caractères, sans barre verticale.")
eq("un saut de ligne est refuse", valide(libelle="a\nb"),
   "Libellé invalide : au plus 60 caractères, sans barre verticale.")

# Un corps qui n'est pas ce qu'on attend : une requête forgée peut envoyer n'importe quoi,
# et le panneau n'est pas la seule façon d'atteindre la route.
eq("un corps vide est refuse", app.valider_regle({})[1], "Groupe source invalide.")
eq("une liste a la place d un nom est refusee",
   app.valider_regle({"source": ["a"], "destination": "internet"})[1], "Groupe source invalide.")
# Ces deux-là PASSENT le contrôle de forme, et c'est voulu : str() en fait « 12 » et
# « None », deux noms de groupe syntaxiquement valides. C'est le CLI qui refuse ensuite,
# parce que lui seul sait quels groupes existent. On le constate ici pour que personne ne
# croie cette barrière plus forte qu'elle n'est, et pour que le jour où l'on voudrait
# resserrer la forme, le changement soit visible.
eq("un nombre devient un nom de groupe, refuse plus loin par le CLI",
   app.valider_regle({"source": 12, "destination": "internet"})[0]["src"], "12")
eq("et null devient le nom « None », de meme",
   app.valider_regle({"source": None, "destination": "internet"})[0]["src"], "None")


# ---------------------------------------------------------------- les motifs
print("")
print("-- les motifs de validation")
eq("un nom d appareil ordinaire passe", bool(app.NAME_RE.fullmatch("pc-salon")), True)
eq("un nom avec un point est refuse", bool(app.NAME_RE.fullmatch("pc.salon")), False)
# NEW_NAME_RE refuse le tiret en tête : un nom pris pour une option par le CLI.
eq("un nom neuf ne commence pas par un tiret", bool(app.NEW_NAME_RE.fullmatch("-x")), False)
eq("mais peut en contenir un", bool(app.NEW_NAME_RE.fullmatch("pc-salon")), True)
eq("une MAC a deux-points passe", bool(app.MAC_RE.fullmatch("aa:bb:cc:dd:ee:ff")), True)
eq("une MAC a tirets passe", bool(app.MAC_RE.fullmatch("aa-bb-cc-dd-ee-ff")), True)
eq("une MAC de cinq groupes est refusee", bool(app.MAC_RE.fullmatch("aa:bb:cc:dd:ee")), False)
eq("une adresse IP n est pas une MAC", bool(app.MAC_RE.fullmatch("192.168.1.20")), False)
eq("une cible IPv4 passe", bool(app.CIBLE_RE.fullmatch("192.168.1.20")), True)
eq("une cible en reseau passe", bool(app.CIBLE_RE.fullmatch("192.168.1.0/24")), True)
eq("un nom d hote n est pas une cible", bool(app.CIBLE_RE.fullmatch("nas.local")), False)

# Le panneau ne doit jamais charger de ressource externe : une page qui dépend d'un CDN
# cesse de fonctionner le jour où le Pi n'a plus Internet — justement quand on en a besoin.
print("")
print("-- la politique de securite du contenu")
eq("aucune source externe n est permise", "default-src 'none'" in app.CSP, True)
eq("les scripts viennent du Pi seul", "script-src 'self'" in app.CSP, True)
eq("la page ne peut pas etre encadree", "frame-ancestors 'none'" in app.CSP, True)

print("")
print("  %d réussi(s), %d échoué(s)" % (reussis, echoues))
sys.exit(1 if echoues else 0)
PYEOF

echo "-- Python du panneau, execute"
( cd "$TMP" && python3 essai.py )
