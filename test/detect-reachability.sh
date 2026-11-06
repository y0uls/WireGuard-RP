#!/usr/bin/env bash
# Tests unitaires de detect_reachability : « ma box peut-elle recevoir une connexion
# depuis Internet ? ». La fonction est testée telle quelle, en simulant les commandes
# dont elle dépend (upnpc, ping, ip) par de faux exécutables placés en tête de PATH.
#
# Usage : ./detect-reachability.sh [chemin/vers/wg-pi.sh]
# Ajouter VERBOSE=1 pour afficher aussi la phrase d'explication rendue à l'utilisateur.
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=${1:-../wg-pi.sh}
[[ -f $SCRIPT ]] || { echo "Script introuvable : $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=$TMP/wgpi.sh BIN=$TMP/bin
mkdir -p "$BIN"

# On retire le « main "$@" » final pour pouvoir charger le script sans le lancer.
if [[ $(tail -n1 "$SCRIPT") == 'main "$@"' ]]; then
  head -n -1 "$SCRIPT" > "$SRC"
else
  cp "$SCRIPT" "$SRC"
fi
export PATH="$BIN:$PATH"

# --- fausses commandes -------------------------------------------------------
# Un argument vide signifie que la commande n'est pas installée du tout.
mock_upnpc() {                     # $1 : adresse que la box annonce côté Internet
  rm -f "$BIN/upnpc"
  [[ -z ${1:-} ]] && return 0
  printf '#!/bin/sh\necho "ExternalIPAddress = %s"\n' "$1" > "$BIN/upnpc"
  chmod +x "$BIN/upnpc"
}

mock_ping() {                      # $1 : table de sauts, ex. "1=192.168.1.1 2=100.65.0.1"
  rm -f "$BIN/ping"
  [[ -z ${1:-} ]] && return 0
  cat > "$BIN/ping" <<PING_MOCK
#!/bin/sh
# Rend la réponse « Time to live exceeded » du saut correspondant au TTL demandé.
ttl=""
while [ \$# -gt 0 ]; do case "\$1" in -t) ttl="\$2"; shift ;; esac; shift; done
for e in $1; do
  k=\${e%%=*}; v=\${e#*=}
  if [ "\$k" = "\$ttl" ]; then echo "From \$v icmp_seq=1 Time to live exceeded"; exit 1; fi
done
exit 1
PING_MOCK
  chmod +x "$BIN/ping"
}

mock_ip() {                        # $1 : adresse du Pi, rendue par « ip route get »
  rm -f "$BIN/ip"
  [[ -z ${1:-} ]] && return 0
  printf '#!/bin/sh\necho "1.1.1.1 via 192.168.1.1 dev eth0 src %s uid 0"\n' "$1" > "$BIN/ip"
  chmod +x "$BIN/ip"
}

# --- confinement du PATH -----------------------------------------------------
# Retirer un faux executable ne desinstalle rien : la fonction trouve alors le VRAI ping de
# la machine qui lance les tests, sonde Internet pour de bon, et rend le verdict du reseau de
# cette machine. Les cas « commande absente » passaient donc dans un conteneur minimal, ou ni
# ping ni upnpc ne sont installes, et tombaient sur une Ubuntu ordinaire. On confine le PATH de
# la sonde a nos faux et aux seuls utilitaires dont elle a besoin : absent y veut dire absent,
# et la suite ne touche plus le reseau.
OUTILS=$TMP/outils
mkdir -p "$OUTILS"
for u in timeout sed awk head tr; do
  p=$(command -v "$u") || { echo "Utilitaire introuvable : $u" >&2; exit 2; }
  { echo "#!/bin/sh"; echo "exec '$p' " '"$@"'; } > "$OUTILS/$u"
  chmod +x "$OUTILS/$u"
done

# --- exécution d'un cas ------------------------------------------------------
pass=0 fail=0
t() {  # t <libellé> <attendu> <ext UPnP> <sauts ping> <IP publique> <passerelle> <adresse du Pi>
  local nom=$1 attendu=$2 ext=$3 hops=$4 pip=$5 gw=$6 self=$7 got why
  mock_upnpc "$ext"; mock_ping "$hops"; mock_ip "$self"
  read -r got why < <(
    # shellcheck source=/dev/null
    source "$SRC"
    LAN_IF=eth0; LAN_GW=$gw; PUBLIC_IP=$pip; LAN_IP=$self
    # Apres le chargement, et seulement pour la sonde : le script a besoin du vrai PATH
    # pour se charger, la sonde a besoin de ne voir que nos faux.
    PATH=$BIN:$OUTILS
    detect_reachability
    printf '%s %s\n' "$REACH" "$REACH_WHY"
  )
  if [[ $got == "$attendu" ]]; then
    printf '  OK   %-54s -> %s\n' "$nom" "$got"; (( pass++ ))
  else
    printf '  KO   %-54s -> %s (attendu : %s)\n' "$nom" "$got" "$attendu"; (( fail++ ))
  fi
  [[ -n ${VERBOSE:-} ]] && printf '      %s\n' "$why"
  return 0
}

echo "-- detect_reachability"
#  libellé                                            attendu  UPnP          sauts ping                     IP publique   passerelle   Pi
t "UPnP annonce une adresse privée"                   cgnat    192.168.100.1 ""                             "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP annonce du 100.64/10"                         cgnat    100.65.4.5    ""                             "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP publique mais différente de l'IP vue"         cgnat    81.9.9.9      ""                             "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP publique égale à l'IP vue"                    ok       86.1.2.3      ""                             "86.1.2.3"    192.168.1.1  192.168.1.50
t "sans UPnP, saut 2 en 100.64/10"                    cgnat    ""            "1=192.168.1.1 2=100.65.0.1"   "86.1.2.3"    192.168.1.1  192.168.1.50
t "sans UPnP, saut 2 privé (routeur en plus)"         cgnat    ""            "1=192.168.1.1 2=10.0.0.1"     "86.1.2.3"    192.168.1.1  192.168.1.50
t "sans UPnP, saut 2 public (ligne saine)"            unknown  ""            "1=192.168.1.1 2=81.253.1.1"   "86.1.2.3"    192.168.1.1  192.168.1.50
t "sans UPnP, sondes ICMP filtrées"                   unknown  ""            "9=1.1.1.1"                    "86.1.2.3"    192.168.1.1  192.168.1.50
t "ni upnpc ni ping installés"                        unknown  ""            ""                             "86.1.2.3"    192.168.1.1  192.168.1.50
t "saut 1 = la box : pas de faux positif"             unknown  ""            "1=192.168.1.1"                "86.1.2.3"    192.168.1.1  192.168.1.50
t "IP publique inconnue, UPnP privée"                 cgnat    192.168.100.1 ""                             ""            192.168.1.1  192.168.1.50

# Le verdict porte sur l'adresse DU PI, et non sur l'IP publique : les services du type
# api.ipify.org rapportent l'adresse qu'ils voient, donc celle du NAT de l'opérateur, qui
# est publique. Un test sur l'IP publique ne pouvait donc jamais se déclencher.
t "Pi en 100.64/10 (clé 4G branchée sur le Pi)"       cgnat    ""            ""                             "37.1.2.3"    100.70.0.1   100.70.1.2
t "Pi en 100.64/10, sondes muettes"                   cgnat    ""            "9=1.1.1.1"                    "37.1.2.3"    100.70.0.1   100.70.1.2
t "IP publique en 100.64/10 : plus de verdict"        unknown  ""            ""                             "100.70.1.2"  192.168.1.1  192.168.1.50

# Un verdict « ok » issu de l'UPnP n'est pas définitif : certaines box annoncent l'adresse
# publique vue depuis Internet alors qu'elles sont derrière le NAT de l'opérateur. Les indices
# suivants doivent pouvoir le contredire.
t "UPnP cohérente mais Pi en 100.64/10 : contredit"      cgnat    86.1.2.3      ""                             "86.1.2.3"    192.168.1.1  100.70.1.2
t "UPnP cohérente mais saut 2 en 100.64/10 : contredit"  cgnat    86.1.2.3      "1=192.168.1.1 2=100.65.0.1"   "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP cohérente et saut 2 public : confirmé"           ok       86.1.2.3      "1=192.168.1.1 2=81.253.1.1"   "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP cohérente et sondes muettes : reste ok"          ok       86.1.2.3      "9=1.1.1.1"                    "86.1.2.3"    192.168.1.1  192.168.1.50
t "UPnP cohérente et ping absent : reste ok"             ok       86.1.2.3      ""                             "86.1.2.3"    192.168.1.1  192.168.1.50

echo
echo "-- redirection lue sur la box"
# « Redirection introuvable » confondait deux situations : la box n en a aucune, ou elle
# en a une qui pointe ailleurs — typiquement l ancienne adresse du Pi apres un changement
# de bail DHCP. Le remede n est pas le meme, et le second cas a l air parfaitement normal
# dans l interface de la box.
liste_upnpc() {                    # $1 : contenu de la liste rendue par upnpc -l
  rm -f "$BIN/upnpc"
  { echo "#!/bin/sh"; echo "cat <<'FIN'"; printf '%s
' "$1"; echo "FIN"; } > "$BIN/upnpc"
  chmod +x "$BIN/upnpc"
}
cible() { ( source "$SRC"; LAN_IF=eth0; WG_PORT=51820; upnp_mapping_target ); }
eq() {
  if [[ $2 == "$3" ]]; then printf '  OK   %-54s -> %s
' "$1" "${2:-vide}"; (( pass++ ))
  else printf '  KO   %-54s -> %s (attendu : %s)
' "$1" "${2:-vide}" "${3:-vide}"; (( fail++ ))
  fi
  return 0
}

liste_upnpc " 0 UDP 51820->192.168.1.50:51820 (wg-pi) (empty) 0"
eq "la redirection attendue est lue" "$(cible)" "192.168.1.50"

liste_upnpc " 0 UDP 51820->192.168.1.42:51820 (wg-pi) (empty) 0"
eq "une redirection vers une autre adresse est vue" "$(cible)" "192.168.1.42"

liste_upnpc " 0 TCP 443->192.168.1.99:443 (web) (empty) 0"
eq "le TCP du meme numero ne compte pas" "$(cible)" ""

liste_upnpc " 0 UDP 5182->192.168.1.50:5182 (autre) (empty) 0"
eq "un port qui commence pareil ne compte pas" "$(cible)" ""

liste_upnpc ""
eq "aucune redirection : rien" "$(cible)" ""

echo
echo "-- trois etats de l UPnP, et non deux"
# « La box ne repond pas en UPnP » etait trompeur dans le cas le plus frequent : des
# appareils UPnP repondent bien — imprimante, TV, NAS — mais aucun n est une PASSERELLE.
# Sur Livebox cela veut dire que l option « UPnP IGD » est desactivee, alors que le
# partage multimedia UPnP/DLNA peut rester coche : l utilisateur voit « UPnP » actif.
brut_upnpc() {                     # $1 : sortie brute de upnpc -s
  rm -f "$BIN/upnpc"
  { echo "#!/bin/sh"; echo "cat <<'FIN'"; printf '%s
' "$1"; echo "FIN"; } > "$BIN/upnpc"
  chmod +x "$BIN/upnpc"
}
etat() { ( source "$SRC"; LAN_IF=eth0; upnp_etat ); }

brut_upnpc "ExternalIPAddress = 86.1.2.3"
eq "passerelle qui repond" "$(etat)" "ok"

# Sortie reelle d une Livebox dont l UPnP IGD est desactive : un appareil tiers repond.
brut_upnpc "List of UPNP devices found on the network :
 desc: http://192.168.1.14:8080/BasicDeviceDescription.xml
 st: upnp:rootdevice

UPnP device found. Is it an IGD ? : http://192.168.1.14:8080/
No valid UPNP Internet Gateway Device found."
eq "des appareils repondent, mais aucune passerelle" "$(etat)" "sans-passerelle"

brut_upnpc "No IGD UPnP Device found on the network !"
eq "rien ne repond du tout" "$(etat)" "absent"

rm -f "$BIN/upnpc"
eq "upnpc absent" "$(etat)" "absent"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
