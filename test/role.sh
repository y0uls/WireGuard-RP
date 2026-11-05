#!/usr/bin/env bash
# Tests du rôle lecture seule : stockage du second mot de passe, calcul du rôle, et
# emplacement des gardes.
#
# Le calcul de rôle est testé pour de vrai : le panneau Python lit son fichier de
# configuration depuis WGPI_WEB_CONF, donc il suffit de rediriger cette variable.
#
# Ce fichier ne contient volontairement aucun backslash.
#
# Usage : ./role.sh [chemin/vers/wg-pi.sh]
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh
mkdir -p "$TMP/etc"

sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR='$TMP/etc'|" \
    -e "s|^readonly LOG_FILE=.*|readonly LOG_FILE='$TMP/log'|" \
    "$SCRIPT" > "$TMP/full.sh"
head -n -1 "$TMP/full.sh" > "$SRC"

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi
}

CONF=$TMP/etc/web.conf

echo "-- stockage dans web.conf"
( source "$SRC"; web_conf_set port 51821 )
( source "$SRC"; web_conf_set password "pbkdf2_sha256,admin" )
eq "lecture d une cle" "$(source "$SRC"; web_conf_get port)" "51821"
( source "$SRC"; web_conf_set password_ro "pbkdf2_sha256,ro" )
eq "trois cles presentes" "$(grep -c '=' "$CONF")" "3"
( source "$SRC"; web_conf_del password_ro )
eq "la cle supprimee a disparu" "$(source "$SRC"; web_conf_get password_ro)" ""
eq "les autres cles sont intactes" "$(source "$SRC"; web_conf_get port)" "51821"
eq "droits 600 conserves" "$(stat -c '%a' "$CONF")" "600"
( source "$SRC"; web_conf_del inexistante )
eq "supprimer une cle absente est sans effet" "$(grep -c '=' "$CONF")" "2"

echo "-- verification d un mot de passe contre une empreinte"
ADMIN=$(printf '%s' "motdepasse-admin" | ( source "$SRC"; web_hash_password ))
case $ADMIN in pbkdf2_sha256*) ok "empreinte produite" ;; *) ko "empreinte invalide : $ADMIN" ;; esac
if printf '%s' "motdepasse-admin" | ( source "$SRC"; web_password_matches "$ADMIN" ); then
  ok "le bon mot de passe correspond"
else
  ko "le bon mot de passe ne correspond pas"
fi
if printf '%s' "autre-chose" | ( source "$SRC"; web_password_matches "$ADMIN" ) 2>/dev/null; then
  ko "un mauvais mot de passe correspond"
else
  ok "un mauvais mot de passe ne correspond pas"
fi
if printf '%s' "x" | ( source "$SRC"; web_password_matches "" ) 2>/dev/null; then
  ko "une empreinte vide correspond"
else
  ok "une empreinte vide ne correspond jamais"
fi
if printf '%s' "x" | ( source "$SRC"; web_password_matches "n-importe-quoi" ) 2>/dev/null; then
  ko "une empreinte illisible correspond"
else
  ok "une empreinte illisible ne correspond jamais"
fi

echo "-- calcul du role par le panneau"
RO=$(printf '%s' "motdepasse-consultation" | ( source "$SRC"; web_hash_password ))
{
  echo "enabled=1"
  echo "port=51821"
  echo "password=$ADMIN"
  echo "password_ro=$RO"
} > "$CONF"

( source "$SRC"; web_app_source ) > "$TMP/app.py" 2>/dev/null || { ko "extraction du panneau impossible"; }
role() {
  WGPI_WEB_CONF="$CONF" python3 -c "
import sys
sys.path.insert(0, '$TMP')
import app
r = app.check_password_role(sys.argv[1])
print('' if r is None else r, end='')
" "$1" 2>/dev/null
}
eq "mot de passe administrateur" "$(role motdepasse-admin)" "admin"
eq "mot de passe de consultation" "$(role motdepasse-consultation)" "lecture"
eq "mot de passe inconnu" "$(role nimportequoi)" ""
eq "mot de passe vide" "$(role '')" ""

# Compatibilite : check_password doit continuer de rendre un booleen pour les deux roles.
boolean() {
  WGPI_WEB_CONF="$CONF" python3 -c "
import sys
sys.path.insert(0, '$TMP')
import app
print('oui' if app.check_password(sys.argv[1]) else 'non', end='')
" "$1" 2>/dev/null
}
eq "check_password accepte l administrateur" "$(boolean motdepasse-admin)" "oui"
eq "check_password accepte la consultation" "$(boolean motdepasse-consultation)" "oui"
eq "check_password refuse le reste" "$(boolean autre)" "non"

# Sans second mot de passe, rien ne change pour les installations existantes.
grep -v '^password_ro=' "$CONF" > "$TMP/c2" && mv "$TMP/c2" "$CONF"
eq "sans compte de consultation : admin inchange" "$(role motdepasse-admin)" "admin"
eq "sans compte de consultation : l ancien mot de passe de consultation est refuse" "$(role motdepasse-consultation)" ""

echo "-- emplacement des gardes dans le source"
# Ces assertions sont structurelles : elles vérifient qu'il existe UN SEUL point
# d'application pour les mutations, et qu'il est au bon endroit. C'est l'invariant qui
# compte — une vérification par route finirait par en oublier une.
APP=$TMP/app.py
lineno() { grep -n -- "$1" "$APP" | head -n1 | cut -d: -f1; }
L_CSRF=$(lineno 'Jeton de sécurité invalide')
L_ROLE=$(lineno 'Compte de consultation : modification impossible')
L_BODY=$(lineno 'body = json.loads(raw) if raw else {}')
if [[ -n $L_CSRF && -n $L_ROLE && -n $L_BODY ]] && (( L_CSRF < L_ROLE && L_ROLE < L_BODY )); then
  ok "la garde de rôle est après le contrôle CSRF et avant la lecture du corps"
else
  ko "garde de rôle mal placée (csrf $L_CSRF, role $L_ROLE, corps $L_BODY)"
fi
eq "une seule garde de mutation" "$(grep -c 'Compte de consultation : modification impossible' "$APP")" "1"
if grep -q 'path != "/api/logout"' "$APP"; then
  ok "la déconnexion reste permise en consultation"
else
  ko "la déconnexion serait refusée au compte de consultation"
fi

# Le .conf et le QR code contiennent la cle privee de l appareil : ce sont les deux seuls
# GET a proteger. /api/state, lui, convient aux deux roles.
L_DEV=$(lineno 'cette configuration contient une clé privée')
L_GROUPS=$(lineno 'name, kind = m.groups()')
if [[ -n $L_DEV && -n $L_GROUPS ]] && (( L_DEV < L_GROUPS )); then
  ok "le .conf et le QR code sont refusés avant tout traitement"
else
  ko "garde des téléchargements mal placée (garde $L_DEV, traitement $L_GROUPS)"
fi
if grep -A3 'if path == "/api/state"' "$APP" | grep -q 'Compte de consultation'; then
  ko "/api/state est refusé à la consultation : le panneau serait vide"
else
  ok "/api/state reste accessible aux deux rôles"
fi

# Une session sans role explicite ne doit pas donner les pleins pouvoirs.
if grep -q 's.get("role", "lecture")' "$APP"; then
  ok "une session sans rôle retombe sur « lecture », pas « admin »"
else
  ko "une session sans rôle pourrait valoir « admin »"
fi

# Et l empreinte de consultation n est calculee que dans le chemin d echec : PBKDF2 a
# 200 000 tours coute environ une seconde sur un Pi en ARMv6, en calculer deux
# systematiquement doublerait le temps de connexion pour tout le monde.
if grep -A2 'if _verify(conf.get("password", ""), password):' "$APP" | grep -q 'return "admin"'; then
  ok "l empreinte administrateur est testée en premier et sort aussitôt"
else
  ko "l ordre de vérification des empreintes n est pas celui attendu"
fi

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
