#!/usr/bin/env bash
# =============================================================================
#  wg-pi — Serveur VPN WireGuard « clé en main » pour Raspberry Pi
#
#  Pour : Raspberry Pi OS / Debian 11, 12, 13 (et dérivés comme Ubuntu)
#  But  : tout installer et configurer avec des réglages sûrs, en guidant
#         pas à pas, y compris pour ouvrir le port sur la box.
#
#  Installation :  curl -fsSL https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh | sudo bash
#            ou :  sudo bash wg-pi.sh   (depuis le fichier téléchargé)
#  Ensuite      :  sudo wg-pi          (menu)
#                  sudo wg-pi help     (toutes les commandes)
#
#  Projet : https://github.com/y0uls/WireGuard-RP — Licence MIT
# =============================================================================

set -uo pipefail
umask 077

readonly WGPI_VERSION="1.3.0"
readonly WGPI_GH="y0uls/WireGuard-RP"
readonly WGPI_BRANCH="main"
readonly WGPI_REPO="https://github.com/$WGPI_GH"
readonly WGPI_DEFAULT_URL="https://raw.githubusercontent.com/$WGPI_GH/$WGPI_BRANCH/wg-pi.sh"
# Adresse de la dernière version (modifiable pour un fork : WGPI_URL=… sudo -E wg-pi update)
readonly WGPI_URL="${WGPI_URL:-$WGPI_DEFAULT_URL}"
# Fichier lancé, capturé hors de toute fonction : vide si le script arrive par un pipe
# (dans une fonction, BASH_SOURCE[0] vaudrait alors « main » et pourrait désigner un fichier ./main)
readonly WGPI_SELF="${BASH_SOURCE[0]:-}"
readonly WG_IF="wg0"
readonly WG_DIR="/etc/wireguard"
readonly WG_CONF="$WG_DIR/$WG_IF.conf"
readonly STATE_DIR="/etc/wg-pi"
readonly SETTINGS_FILE="$STATE_DIR/settings.conf"
readonly CLIENTS_DIR="$STATE_DIR/clients"
readonly FW_SCRIPT="$STATE_DIR/firewall.sh"
readonly DUCKDNS_FILE="$STATE_DIR/duckdns.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-wg-pi.conf"
readonly UNATTENDED_FILE="/etc/apt/apt.conf.d/51wg-pi-unattended"
readonly BIN_PATH="/usr/local/sbin/wg-pi"
readonly UNIT_DIR="/etc/systemd/system"
readonly LOG_FILE="/var/log/wg-pi.log"
readonly LOCK_FILE="/run/wg-pi.lock"
readonly MARK="### Client:"
readonly KEEPALIVE=25
readonly STEPS=7
# Interface web d'administration (sudo wg-pi web)
readonly WEB_CONF="$STATE_DIR/web.conf"
readonly WEB_DIR="$STATE_DIR/web"
readonly WEB_UNIT="wg-pi-web.service"
readonly WEB_DEFAULT_PORT=51821

# Réglages enregistrés dans $SETTINGS_FILE (valeurs par défaut ci-dessous)
WG_PORT=51820
WG_NET4=""            # 3 premiers octets du réseau VPN (/24), ex. 10.8.0
WG_NET6=""            # préfixe IPv6 privé (ULA, /64), ex. fd12:3456:789a::
IPV6_ON=0             # adresses IPv6 dans le tunnel
IPV6_NAT=0            # le Pi a une IPv6 publique : il relaie aussi l'IPv6
LAN_IF="" LAN_IP="" LAN_PREFIX="" LAN_GW="" LAN_NET="" LAN_MAC=""
ENDPOINT=""           # adresse publique (IP ou nom) contactée par les appareils
CLIENT_DNS=""
DEFAULT_ROUTE="full"  # full = tout le trafic par la maison, split = réseau maison seulement
SERVER_PUBKEY=""
DDNS="none"           # none | duckdns
UPNP=0
UNATTENDED=0
ISP=""
IP_MODE=""            # static | reserve | nm | later

# État pendant l'exécution
AUTO=0
TTY=""
PUBLIC_IP=""
UPNP_OK=0
DNS_LOCAL=0
LOCAL_DNS_ADDR="" LOCAL_DNS_NAME="" LOCAL_DNS_KNOWN=0
DUCKDNS_DOMAIN="" DUCKDNS_TOKEN=""
OPT_ENDPOINT="" OPT_PORT="" OPT_CLIENT=""
EXPORT_PATH=""
APT_UPDATED=0

# ----------------------------------------------------------------------------
# Affichage
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

info()  { printf '%s\n' "${CYAN}➜${RESET} $*"; }
ok()    { printf '%s\n' "${GREEN}✔${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}⚠  $*${RESET}"; }
fail()  { printf '%s\n' "${RED}✖ $*${RESET}" >&2; }
die()   { fail "$*"; exit 1; }
title() { printf '\n%s\n\n' "${BOLD}${CYAN}━━━━ $* ━━━━${RESET}"; }
txt()   { printf '%s\n' "$@"; }

# pad <texte> <largeur> : complète avec des espaces. Compte les caractères, pas les octets,
# quelle que soit la locale (les octets de suite UTF-8 0x80-0xBF ne sont pas comptés).
pad() {
  local LC_ALL=C s=${1//[$'\x80'-$'\xbf']/}
  printf '%s%*s' "$1" $(( $2 > ${#s} ? $2 - ${#s} : 0 )) ""
}
kv()  { printf '   %s %s\n' "$(pad "$1" 22)" "${BOLD}$2${RESET}"; }

# ----------------------------------------------------------------------------
# Questions (lues sur le terminal, même si le script arrive par un pipe)
# ----------------------------------------------------------------------------
init_input() {
  if [[ -t 0 ]]; then
    TTY=/dev/stdin
  elif (exec </dev/tty) 2>/dev/null; then
    TTY=/dev/tty
  else
    TTY=""
  fi
}

interactive() { (( ! AUTO )) && [[ -n $TTY ]]; }

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# ask <variable> <question> [défaut]
ask() {
  local _ask_var=$1 _ask_q=$2 _ask_def=${3-} _ask_ans=""
  if interactive; then
    printf '%s ' "${BOLD}?${RESET} ${_ask_q}${_ask_def:+ ${DIM}[${_ask_def}]${RESET}}"
    IFS= read -r _ask_ans <"$TTY" || _ask_ans=""
    _ask_ans=$(trim "$_ask_ans")
    _ask_ans=${_ask_ans:-$_ask_def}
  else
    _ask_ans=$_ask_def
    printf '%s\n' "${BOLD}?${RESET} ${_ask_q} ${DIM}→ ${_ask_def:-(vide)}${RESET}"
  fi
  printf -v "$_ask_var" '%s' "$_ask_ans"
}

# ask_yn <question> <o|n> : code retour 0 = oui
ask_yn() {
  local _q=$1 _def=${2:-o} _ans _hint="o/N"
  [[ $_def == o ]] && _hint="O/n"
  while true; do
    if interactive; then
      printf '%s ' "${BOLD}?${RESET} $_q ${DIM}[$_hint]${RESET}"
      IFS= read -r _ans <"$TTY" || _ans=""
      _ans=$(trim "$_ans")
      _ans=${_ans:-$_def}
    else
      _ans=$_def
      printf '%s\n' "${BOLD}?${RESET} $_q ${DIM}→ $([[ $_def == o ]] && echo oui || echo non)${RESET}"
    fi
    case ${_ans,,} in
      o|oui|y|yes) return 0 ;;
      n|non|no)    return 1 ;;
      *) warn "Répondez par o (oui) ou n (non)." ;;
    esac
  done
}

# choose <variable> <question> <n° par défaut> <choix 1> <choix 2> ...
choose() {
  local _var=$1 _q=$2 _def=$3 _i _ans
  shift 3
  printf '%s\n' "${BOLD}?${RESET} $_q"
  for (( _i = 1; _i <= $#; _i++ )); do
    printf '    %s %s\n' "${BOLD}${_i})${RESET}" "${!_i}"
  done
  while true; do
    ask _ans "  Votre choix" "$_def"
    if [[ $_ans =~ ^[0-9]+$ ]] && (( _ans >= 1 && _ans <= $# )); then
      printf -v "$_var" '%s' "$_ans"
      return 0
    fi
    warn "Tapez un numéro entre 1 et $#."
  done
}

pause() {
  interactive || return 0
  printf '%s ' "${DIM}${1:-Appuyez sur Entrée pour continuer…}${RESET}"
  IFS= read -r _ <"$TTY" || true
}

# ----------------------------------------------------------------------------
# Petits outils
# ----------------------------------------------------------------------------
# run <message> <commande...> : exécute en journalisant, affiche ok/échec
run() {
  local msg=$1
  shift
  printf '%s' "${CYAN}➜${RESET} $msg… "
  printf '\n[%s] %s\n$ %s\n' "$(date '+%F %T')" "$msg" "$*" >>"$LOG_FILE"
  # </dev/null : apt & co ne doivent ni attendre ni « manger » ce que l'utilisateur tape
  if "$@" </dev/null >>"$LOG_FILE" 2>&1; then
    printf '%s\n' "${GREEN}ok${RESET}"
    return 0
  fi
  printf '%s\n' "${RED}échec${RESET}"
  printf '%s\n' "${DIM}--- fin du journal $LOG_FILE ---${RESET}" >&2
  tail -n 15 "$LOG_FILE" >&2
  return 1
}

field_after() { awk -v k="$1" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }' <<<"$2"; }
os_field()    { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -n1 | tr -d '"'; }

is_ipv4() {
  local IFS=. o
  local -a parts
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -ra parts <<<"$1"
  for o in "${parts[@]}"; do (( 10#$o <= 255 )) || return 1; done
}

ip2int() {
  local IFS=.
  local -a o
  read -ra o <<<"$1"
  echo $(( (10#${o[0]} << 24) + (10#${o[1]} << 16) + (10#${o[2]} << 8) + 10#${o[3]} ))
}

int2ip()      { printf '%d.%d.%d.%d' $(( $1 >> 24 & 255 )) $(( $1 >> 16 & 255 )) $(( $1 >> 8 & 255 )) $(( $1 & 255 )); }
prefix_mask() { echo $(( $1 == 0 ? 0 : (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); }
network_of()  { echo "$(int2ip $(( $(ip2int "$1") & $(prefix_mask "$2") )))/$2"; }

# cidr_overlap <a/len> <b/len> : vrai si les deux réseaux se chevauchent
cidr_overlap() {
  local la=${1#*/} lb=${2#*/} l m
  l=$(( la < lb ? la : lb ))
  m=$(prefix_mask "$l")
  (( ($(ip2int "${1%/*}") & m) == ($(ip2int "${2%/*}") & m) ))
}

in_cidr()         { cidr_overlap "$1/32" "$2"; }
is_private_ipv4() { is_ipv4 "$1" && { in_cidr "$1" 10.0.0.0/8 || in_cidr "$1" 172.16.0.0/12 || in_cidr "$1" 192.168.0.0/16; }; }
is_cgnat()        { is_ipv4 "${1:-}" && in_cidr "$1" 100.64.0.0/10; }
is_hostname()     { [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
valid_port()      { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_name()      { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,14}$ ]]; }   # pas de « - » en tête (pris pour une option)
port_in_use()     { [[ -n $(ss -Hlun "sport = :$1" 2>/dev/null) ]]; }
is_installed()    { [[ -f $SETTINGS_FILE && -f $WG_CONF ]]; }
wg_running()      { systemctl is-active --quiet "wg-quick@$WG_IF"; }

human() { numfmt --to=iec --suffix=o "${1:-0}" 2>/dev/null || echo "${1:-0} o"; }

ago() {
  local s=$(( $(date +%s) - $1 ))
  if   (( s < 60 ));    then echo "il y a ${s} s"
  elif (( s < 3600 ));  then echo "il y a $(( s / 60 )) min"
  elif (( s < 86400 )); then echo "il y a $(( s / 3600 )) h"
  else                       echo "il y a $(( s / 86400 )) j"
  fi
}

endpoint_str() {
  if [[ $ENDPOINT == *:* ]]; then echo "[$ENDPOINT]:$WG_PORT"; else echo "$ENDPOINT:$WG_PORT"; fi
}

take_lock() {
  exec 9>"$LOCK_FILE"
  if interactive; then
    flock -n 9 || die "wg-pi est déjà en cours d'exécution dans un autre terminal."
  else
    # Sans terminal (interface web, scripts) : on attend son tour plutôt que d'échouer
    flock -w 30 9 || die "Une autre opération wg-pi est en cours, réessayez dans un instant."
  fi
}

# Chemin du fichier de ce script, vide s'il est lu depuis un pipe (curl … | sudo bash)
self_path() {
  local p=$WGPI_SELF
  [[ -n $p && -f $p ]] && grep -q '^readonly WGPI_VERSION=' "$p" 2>/dev/null && readlink -f -- "$p"
}

require_root() {
  (( EUID == 0 )) && return 0
  local self
  self=$(self_path)
  if [[ -n $self ]] && command -v sudo >/dev/null 2>&1; then
    exec sudo -- bash "$self" "$@"
  fi
  if [[ -n $self ]]; then die "Ce script doit être lancé en administrateur : sudo bash $self"; fi
  die "Ce script doit être lancé en administrateur : curl -fsSL $WGPI_URL | sudo bash"
}

# ----------------------------------------------------------------------------
# Paquets
# ----------------------------------------------------------------------------
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --no-install-recommends "$@"
}

ensure_packages() {
  local p
  local -a missing=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
  done
  (( ${#missing[@]} == 0 )) && return 0
  if (( ! APT_UPDATED )); then
    run "Mise à jour de la liste des paquets" apt-get -q -o DPkg::Lock::Timeout=300 update || return 1
    APT_UPDATED=1
  fi
  run "Installation de ${missing[*]}" apt_install "${missing[@]}"
}

check_wg_module() {
  modprobe wireguard >/dev/null 2>&1 || true
  if ip link add dev wgpitest type wireguard >/dev/null 2>&1; then
    ip link del dev wgpitest >/dev/null 2>&1
    return 0
  fi
  fail "Le noyau ($(uname -r)) ne sait pas créer d'interface WireGuard."
  txt "  Mettez le système à jour puis redémarrez, et relancez ce script :" \
      "    sudo apt update && sudo apt full-upgrade -y && sudo reboot"
  return 1
}

# ----------------------------------------------------------------------------
# Détection du réseau
# ----------------------------------------------------------------------------
detect_network() {
  local r
  r=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1)
  [[ -n $r ]] || die "Pas de route vers Internet : le Pi est-il bien connecté à la box ?"
  LAN_IF=$(field_after dev "$r")
  LAN_GW=$(field_after via "$r")
  LAN_IP=$(field_after src "$r")
  [[ -n $LAN_IF && -n $LAN_IP ]] || die "Impossible de détecter la configuration réseau."
  LAN_PREFIX=$(ip -4 -o addr show dev "$LAN_IF" | awk -v ip="$LAN_IP" '{ split($4, a, "/"); if (a[1] == ip) { print a[2]; exit } }')
  LAN_PREFIX=${LAN_PREFIX:-24}
  LAN_NET=$(network_of "$LAN_IP" "$LAN_PREFIX")
  LAN_MAC=$(cat "/sys/class/net/$LAN_IF/address" 2>/dev/null || echo "?")
}

current_lan_ip() { field_after src "$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1)"; }

iface_kind() { if [[ -d /sys/class/net/$1/wireless ]]; then echo "Wi-Fi"; else echo "Ethernet"; fi; }

detect_ipv6() {
  IPV6_ON=0 IPV6_NAT=0
  [[ -e /proc/net/if_inet6 ]] || return 0
  [[ $(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null) == 1 ]] && return 0
  IPV6_ON=1
  local r src
  r=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n1) || return 0
  src=$(field_after src "$r")
  [[ -n $src && $src != fe80:* && $src != f[cd]* ]] && IPV6_NAT=1
  return 0
}

get_public_ip() {
  local url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip; do
    ip=$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# Devine l'opérateur grâce au nom inverse (PTR) de l'IP publique
detect_isp() {
  local host
  [[ -n ${1:-} ]] || return 0
  host=$(getent hosts "$1" 2>/dev/null | awk '{ print tolower($2) }')
  case $host in
    *wanadoo.fr|*orange.fr|*orange-business.com) echo orange ;;
    *proxad.net|*free.fr|*freebox.fr)            echo free ;;
    *sfr.net|*sfr.fr|*numericable.fr|*neufcegetel.fr) echo sfr ;;
    *bbox.fr|*bouyguestelecom.fr|*bytel.fr)      echo bouygues ;;
    *) echo "" ;;
  esac
}

isp_label() {
  case ${1:-} in
    orange) echo "Orange / Sosh" ;;
    free) echo "Free" ;;
    sfr) echo "SFR / RED" ;;
    bouygues) echo "Bouygues Telecom" ;;
    *) echo "inconnu" ;;
  esac
}

# Un réseau /24 donné (ex. 10.8.0) chevauche-t-il un réseau déjà utilisé par le Pi ?
subnet_in_use() {
  local cand="$1.0/24" dst
  while read -r dst; do
    [[ $dst == default || -z $dst ]] && continue
    [[ $dst == */* ]] || dst="$dst/32"
    is_ipv4 "${dst%/*}" || continue
    cidr_overlap "$cand" "$dst" && return 0
  done < <(ip -4 route show table all 2>/dev/null |
           awk '{ print ($1 == "local" || $1 == "broadcast" || $1 == "unicast" || $1 == "unreachable") ? $2 : $1 }')
  return 1
}

pick_subnet() {
  local c
  for c in 10.8.0 10.9.0 10.66.66 10.77.0 10.99.0 172.30.0; do
    subnet_in_use "$c" || { echo "$c"; return 0; }
  done
  echo 10.8.0
}

random_ula() {
  local h
  h=$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')
  printf 'fd%s:%s:%s::' "${h:0:2}" "${h:2:4}" "${h:6:4}"
}

# Serveur DNS (Pi-hole, AdGuard Home…) déjà présent sur le Pi et joignable depuis le VPN ?
detect_local_dns() {
  local addrs
  addrs=$(ss -Hlnu 'sport = :53' 2>/dev/null | awk '{ print $4 }')
  if grep -qE '^(0\.0\.0\.0|\*|\[::\]):53$' <<<"$addrs"; then
    LOCAL_DNS_ADDR="wg"          # écoute partout : on utilisera l'adresse VPN du Pi
  elif grep -qxF "$LAN_IP:53" <<<"$addrs"; then
    LOCAL_DNS_ADDR=$LAN_IP
  else
    return 1
  fi
  LOCAL_DNS_KNOWN=1
  if command -v pihole >/dev/null 2>&1; then LOCAL_DNS_NAME="Pi-hole"
  elif [[ -x /opt/AdGuardHome/AdGuardHome ]] || systemctl list-unit-files 2>/dev/null | grep -qi '^adguardhome'; then LOCAL_DNS_NAME="AdGuard Home"
  else LOCAL_DNS_NAME="Le serveur DNS"; LOCAL_DNS_KNOWN=0
  fi
}

# ----------------------------------------------------------------------------
# Lecture / écriture des réglages
# ----------------------------------------------------------------------------
save_settings() {
  local v
  install -d -m 700 "$STATE_DIR"
  {
    echo "# Réglages wg-pi $WGPI_VERSION — mis à jour le $(date '+%F %T')"
    for v in WG_PORT WG_NET4 WG_NET6 IPV6_ON IPV6_NAT LAN_IF LAN_IP LAN_PREFIX LAN_GW LAN_NET LAN_MAC \
             ENDPOINT CLIENT_DNS DEFAULT_ROUTE SERVER_PUBKEY DDNS UPNP UNATTENDED ISP IP_MODE; do
      printf '%s=%q\n' "$v" "${!v-}"
    done
  } >"$SETTINGS_FILE"
  chmod 600 "$SETTINGS_FILE"
}

load_settings() {
  is_installed || die "wg-pi n'est pas encore installé sur ce Pi. Pour l'installer : curl -fsSL $WGPI_URL | sudo bash"
  # shellcheck source=/dev/null
  source "$SETTINGS_FILE"
}

save_duckdns() {
  printf 'DUCKDNS_DOMAIN=%q\nDUCKDNS_TOKEN=%q\n' "$DUCKDNS_DOMAIN" "$DUCKDNS_TOKEN" >"$DUCKDNS_FILE"
  chmod 600 "$DUCKDNS_FILE"
}

# ----------------------------------------------------------------------------
# Fichiers du serveur
# ----------------------------------------------------------------------------
write_server_conf() {
  local priv addr="$WG_NET4.1/24"
  priv=$(wg genkey) || return 1
  SERVER_PUBKEY=$(wg pubkey <<<"$priv")
  (( IPV6_ON )) && addr+=", ${WG_NET6}1/64"
  {
    echo "# Serveur WireGuard géré par wg-pi : utilisez « sudo wg-pi » pour gérer les appareils."
    echo "[Interface]"
    echo "Address = $addr"
    echo "ListenPort = $WG_PORT"
    echo "PrivateKey = $priv"
    echo "PostUp = $FW_SCRIPT up"
    echo "PostDown = $FW_SCRIPT down"
  } >"$WG_CONF"
  chmod 600 "$WG_CONF"
}

write_firewall_script() {
  {
    echo "#!/bin/sh"
    echo "# Généré par wg-pi : règles pare-feu et NAT du VPN, appliquées par wg-quick"
    echo "# (PostUp/PostDown de $WG_CONF). Usage : firewall.sh up|down"
    echo "WG_IF='$WG_IF'"
    echo "PORT='$WG_PORT'"
    echo "NET4='$WG_NET4.0/24'"
    echo "NET6='${WG_NET6}/64'"
    echo "IPV6_NAT='$IPV6_NAT'"
    cat <<'EOF'

rules() { # $1 = -I (ajout) ou -D (retrait), $2 = iptables ou ip6tables, $3 = réseau du VPN
  rc=0
  "$2" -w "$1" INPUT -p udp --dport "$PORT" -j ACCEPT || rc=1
  "$2" -w "$1" FORWARD -i "$WG_IF" -j ACCEPT || rc=1
  "$2" -w "$1" FORWARD -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || rc=1
  "$2" -w -t nat "$1" POSTROUTING -s "$3" ! -o "$WG_IF" -j MASQUERADE || rc=1
  return $rc
}

case "$1" in
  up)
    # Nettoie d'éventuels restes avant d'ajouter (évite les doublons)
    rules -D iptables "$NET4" 2>/dev/null
    rules -I iptables "$NET4" || exit 1
    if [ "$IPV6_NAT" = 1 ]; then
      rules -D ip6tables "$NET6" 2>/dev/null
      rules -I ip6tables "$NET6" || echo "wg-pi : règles IPv6 non appliquées (IPv6 ignoré)" >&2
    fi
    ;;
  down)
    rules -D iptables "$NET4" 2>/dev/null
    [ "$IPV6_NAT" = 1 ] && rules -D ip6tables "$NET6" 2>/dev/null
    ;;
  *)
    echo "usage : $0 up|down" >&2
    exit 2
    ;;
esac
exit 0
EOF
  } >"$FW_SCRIPT"
  chmod 700 "$FW_SCRIPT"
}

write_sysctl() {
  local ra
  {
    echo "# Généré par wg-pi : le Pi relaie le trafic des appareils connectés au VPN"
    echo "net.ipv4.ip_forward = 1"
    if (( IPV6_NAT )); then
      # Avec le routage IPv6 activé, le noyau ignore les annonces de la box (accept_ra=1)
      # et le Pi perdrait son IPv6 : accept_ra=2 les garde.
      ra=$(cat "/proc/sys/net/ipv6/conf/$LAN_IF/accept_ra" 2>/dev/null || echo 0)
      [[ $ra != 0 ]] && echo "net.ipv6.conf.$LAN_IF.accept_ra = 2"
      echo "net.ipv6.conf.all.forwarding = 1"
    fi
  } >"$SYSCTL_FILE"
  chmod 644 "$SYSCTL_FILE"
}

open_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active" || return 0
  run "Ouverture du port $WG_PORT/udp dans le pare-feu UFW" ufw allow "$WG_PORT/udp" comment "WireGuard (wg-pi)"
}

setup_unattended() {
  ensure_packages unattended-upgrades || return 1
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' \
    >/etc/apt/apt.conf.d/20auto-upgrades
  chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
  # Raspberry Pi OS : par défaut, unattended-upgrades ne connaît que les dépôts Debian
  local sources=(/etc/apt/sources.list /etc/apt/sources.list.d)
  if grep -rqsE 'raspbian\.raspberrypi\.(org|com)|archive\.raspberrypi\.(org|com)' "${sources[@]}"; then
    {
      echo '// Ajouté par wg-pi : mises à jour automatiques des dépôts Raspberry Pi OS'
      echo 'Unattended-Upgrade::Origins-Pattern {'
      grep -rqsE 'raspbian\.raspberrypi\.(org|com)' "${sources[@]}" &&
        echo '        "origin=Raspbian,codename=${distro_codename},label=Raspbian";'
      grep -rqsE 'archive\.raspberrypi\.(org|com)' "${sources[@]}" &&
        echo '        "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";'
      echo '};'
    } >"$UNATTENDED_FILE"
    chmod 644 "$UNATTENDED_FILE"
  fi
  ok "Mises à jour de sécurité automatiques activées"
}

# Adresse à télécharger. Le lien « main » de raw.githubusercontent.com reste en cache jusqu'à
# 5 minutes après un envoi : on demande donc le dernier commit à l'API GitHub et on télécharge
# par son identifiant (adresse jamais en cache). Si l'API ne répond pas, on garde le lien habituel.
latest_script_url() {
  local sha
  if [[ $WGPI_URL == "$WGPI_DEFAULT_URL" ]]; then
    sha=$(curl -fsSL --max-time 15 -H "Accept: application/vnd.github.sha" \
      "https://api.github.com/repos/$WGPI_GH/commits/$WGPI_BRANCH" 2>>"$LOG_FILE")
    if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
      echo "https://raw.githubusercontent.com/$WGPI_GH/$sha/wg-pi.sh"
      return 0
    fi
    echo "API GitHub indisponible, téléchargement via $WGPI_URL" >>"$LOG_FILE"
    warn "API GitHub injoignable : la version récupérée peut avoir jusqu'à 5 minutes de retard." >&2
  fi
  echo "$WGPI_URL"
}

# version_lt <a> <b> : vrai si la version a est strictement plus ancienne que b
version_lt() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]; }

# download_script <variable> : télécharge la dernière version dans un fichier temporaire
# et vérifie qu'il s'agit bien d'un script wg-pi valide
download_script() {
  local _f _url
  _f=$(mktemp) || return 1
  _url=$(latest_script_url)
  echo "Téléchargement de $_url" >>"$LOG_FILE"
  if ! curl -fsSL --max-time 60 "$_url" -o "$_f" 2>>"$LOG_FILE"; then
    rm -f "$_f"
    return 1
  fi
  sed -i 's/\r$//' "$_f"   # au cas où le fichier aurait été envoyé avec des fins de ligne Windows
  if ! head -n1 "$_f" | grep -q '^#!/usr/bin/env bash' || ! grep -q '^readonly WGPI_VERSION=' "$_f" ||
     ! bash -n "$_f" 2>>"$LOG_FILE"; then
    rm -f "$_f"
    return 1
  fi
  printf -v "$1" '%s' "$_f"
}

script_version() { sed -n 's/^readonly WGPI_VERSION="\(.*\)"$/\1/p' "$1" | head -n1; }

# put_bin <fichier> : remplace la commande wg-pi (renommage atomique, sans casser une exécution en cours)
put_bin() {
  install -m 755 "$1" "$BIN_PATH.new" && mv -f "$BIN_PATH.new" "$BIN_PATH"
}

# Installe la commande wg-pi : copie du fichier lancé, ou téléchargement depuis le dépôt
# si le script arrive par un pipe (curl … | sudo bash)
install_self() {
  local src tmp
  src=$(self_path)
  if [[ -n $src ]]; then
    [[ $src == "$BIN_PATH" ]] || put_bin "$src" || return 1
  else
    download_script tmp || return 1
    put_bin "$tmp"
    rm -f "$tmp"
  fi
  [[ -x $BIN_PATH ]]
}

write_unit() {
  local name=$1
  shift
  printf '%s\n' "$@" >"$UNIT_DIR/$name"
  chmod 644 "$UNIT_DIR/$name"
}

setup_timers() {
  if [[ $DDNS == duckdns ]]; then
    write_unit wg-pi-duckdns.service "[Unit]" "Description=wg-pi : mise à jour du nom DuckDNS" \
      "Wants=network-online.target" "After=network-online.target" "" \
      "[Service]" "Type=oneshot" "ExecStart=$BIN_PATH ddns-update"
    write_unit wg-pi-duckdns.timer "[Unit]" "Description=wg-pi : mise à jour DuckDNS toutes les 5 minutes" "" \
      "[Timer]" "OnBootSec=1min" "OnUnitActiveSec=5min" "" "[Install]" "WantedBy=timers.target"
  else
    systemctl disable --now wg-pi-duckdns.timer >/dev/null 2>&1
    rm -f "$UNIT_DIR"/wg-pi-duckdns.{service,timer} "$DUCKDNS_FILE"
  fi
  if (( UPNP )); then
    write_unit wg-pi-upnp.service "[Unit]" "Description=wg-pi : maintient l'ouverture du port sur la box (UPnP)" \
      "Wants=network-online.target" "After=network-online.target" "" \
      "[Service]" "Type=oneshot" "ExecStart=$BIN_PATH upnp-refresh"
    write_unit wg-pi-upnp.timer "[Unit]" "Description=wg-pi : vérifie l'ouverture du port toutes les 30 minutes" "" \
      "[Timer]" "OnBootSec=2min" "OnUnitActiveSec=30min" "" "[Install]" "WantedBy=timers.target"
  fi
  systemctl daemon-reload
  [[ $DDNS == duckdns ]] && { systemctl enable --now wg-pi-duckdns.timer >>"$LOG_FILE" 2>&1 || warn "Impossible d'activer la mise à jour DuckDNS."; }
  (( UPNP )) && { systemctl enable --now wg-pi-upnp.timer >>"$LOG_FILE" 2>&1 || warn "Impossible d'activer le maintien UPnP."; }
  return 0
}

start_wg() { systemctl enable "wg-quick@$WG_IF" && systemctl restart "wg-quick@$WG_IF"; }

reload_wg() {
  wg_running || return 0
  if ! wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>>"$LOG_FILE"; then
    systemctl restart "wg-quick@$WG_IF" || warn "Le rechargement de WireGuard a échoué : sudo systemctl restart wg-quick@$WG_IF"
  fi
}

# Partie commune à l'installation et à la restauration
apply_system() {
  write_firewall_script
  write_sysctl
  run "Activation du routage" sysctl -q -p "$SYSCTL_FILE" || return 1
  open_ufw
  (( UNATTENDED )) && setup_unattended
  install_self || warn "Impossible d'installer la commande wg-pi dans $BIN_PATH."
  setup_timers
  if ! run "Démarrage de WireGuard" start_wg; then
    journalctl -u "wg-quick@$WG_IF" -n 20 --no-pager >&2
    return 1
  fi
  (( UPNP )) && upnp_open
  return 0
}

# ----------------------------------------------------------------------------
# UPnP (ouverture automatique du port sur la box) et DuckDNS
# ----------------------------------------------------------------------------
upnp_has_mapping() { upnpc -m "$LAN_IF" -l 2>/dev/null | grep -Eq "UDP +$WG_PORT->$LAN_IP:$WG_PORT( |$)"; }

upnp_map() {
  upnp_has_mapping && return 0
  upnpc -m "$LAN_IF" -d "$WG_PORT" UDP >/dev/null 2>&1   # ancienne redirection vers une autre IP
  upnpc -m "$LAN_IF" -e "WireGuard (wg-pi)" -a "$LAN_IP" "$WG_PORT" "$WG_PORT" UDP >/dev/null 2>&1
  upnp_has_mapping && return 0
  # Certaines box refusent les redirections permanentes : bail de 24 h, renouvelé par le timer
  upnpc -m "$LAN_IF" -e "WireGuard (wg-pi)" -a "$LAN_IP" "$WG_PORT" "$WG_PORT" UDP 86400 >/dev/null 2>&1
  upnp_has_mapping
}

upnp_open() {
  UPNP_OK=0
  local out ext
  info "Ouverture automatique du port $WG_PORT/UDP sur la box (UPnP)…"
  out=$(upnpc -m "$LAN_IF" -s 2>&1)
  if ! grep -q "ExternalIPAddress" <<<"$out"; then
    warn "La box ne répond pas en UPnP (option désactivée ?) : ouvrez le port à la main (guide pas à pas : sudo wg-pi box)."
    return 1
  fi
  ext=$(sed -n 's/^ExternalIPAddress = //p' <<<"$out" | head -n1 | tr -d '[:space:]')
  if is_private_ipv4 "$ext" || is_cgnat "$ext"; then
    warn "Votre box n'a elle-même qu'une adresse privée ($ext) : il y a sans doute un autre routeur devant,"
    warn "ou votre opérateur partage son IP (CGNAT). La redirection devra aussi être faite sur l'autre routeur."
  fi
  if upnp_map; then
    UPNP_OK=1
    ok "Port $WG_PORT/UDP ouvert automatiquement sur la box"
    return 0
  fi
  warn "La box a refusé l'ouverture automatique : ouvrez le port à la main (guide pas à pas : sudo wg-pi box)."
  return 1
}

duckdns_call() {
  curl -fsS --max-time 20 -K - 2>/dev/null <<<"url = \"https://www.duckdns.org/update?domains=$1&token=$2&ip=\""
}

# ----------------------------------------------------------------------------
# Appareils (clients)
# ----------------------------------------------------------------------------
# Affiche « nom ip clé_publique état » (état : on, ou off si désactivé) pour chaque appareil de wg0.conf.
# Un appareil désactivé garde son bloc, commenté par « #~ ».
peers_table() {
  awk -v mark="$MARK" '
    index($0, mark " ") == 1 { name = substr($0, length(mark) + 2); state = "on"; next }
    name != "" {
      line = $0
      if (index(line, "#~ ") == 1) { line = substr(line, 4); state = "off" }
      split(line, f, " ")
      if (f[1] == "PublicKey") pub = f[3]
      if (f[1] == "AllowedIPs") { split(f[3], a, "/"); print name, a[1], pub, state; name = "" }
    }
  ' "$WG_CONF"
}

client_exists() { grep -qxF "$MARK $1" "$WG_CONF"; }
# (comparaisons forcées en texte : en awk, « 01 » et « 1 » seraient égaux en nombre)
client_pubkey() { peers_table | awk -v n="$1" '$1 "" == n "" { print $3 }'; }
client_names()  { peers_table | awk '{ print $1 }'; }
client_state()  { peers_table | awk -v n="$1" '$1 "" == n "" { print $4 }'; }

# set_client_state <nom> on|off : coupe ou rétablit l'accès d'un appareil sans le supprimer.
# Désactivé, son bloc [Peer] reste dans wg0.conf (il garde son IP) mais commenté : wg-quick l'ignore.
set_client_state() {
  local tmp
  tmp=$(mktemp) || return 1
  awk -v m="$MARK $1" -v p="$MARK " -v st="$2" '
    $0 == m { inblk = 1; print; next }
    inblk && index($0, p) == 1 { inblk = 0 }
    inblk && NF && st == "off" && index($0, "#~ ") != 1 { print "#~ " $0; next }
    inblk && st == "on" && index($0, "#~ ") == 1 { print substr($0, 4); next }
    { print }
  ' "$WG_CONF" >"$tmp" && cat "$tmp" >"$WG_CONF"
  rm -f "$tmp"
  reload_wg
}

next_free_ip() {
  local n
  local -A used=()
  while read -r _ ip _; do used[${ip##*.}]=1; done < <(peers_table)
  for (( n = 2; n <= 254; n++ )); do
    [[ -z ${used[$n]:-} ]] && { echo "$n"; return 0; }
  done
  return 1
}

# Copie la configuration dans ~/wireguard-clients de l'utilisateur (pour la récupérer facilement)
export_client() {
  local name=$1 user=${SUDO_USER:-} home group dir
  EXPORT_PATH=""
  [[ -n $user && $user != root ]] || return 0
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -d $home ]] || return 0
  group=$(id -gn "$user")
  dir="$home/wireguard-clients"
  install -d -m 700 -o "$user" -g "$group" "$dir" || return 0
  install -m 600 -o "$user" -g "$group" "$CLIENTS_DIR/$name.conf" "$dir/$name.conf" || return 0
  if qrencode -t png -s 8 -o "$dir/$name.png" <"$CLIENTS_DIR/$name.conf" 2>/dev/null; then
    chown "$user:$group" "$dir/$name.png"
    chmod 600 "$dir/$name.png"
  fi
  EXPORT_PATH="$dir/$name.conf"
}

# print_fetch_hint <chemin relatif au dossier personnel> : commande à taper sur l'ordinateur
# pour récupérer un fichier du Pi (destination explicite : pas de « . » final facile à oublier)
print_fetch_hint() {
  local src="$SUDO_USER@$LAN_IP:$1"
  txt "  Pour le récupérer, tapez sur l'ordinateur (pas sur le Pi) :" \
      "    Windows (PowerShell) : ${BOLD}scp $src \$HOME\\Downloads\\${RESET}" \
      "    Mac / Linux          : ${BOLD}scp $src ~/${RESET}" \
      "  ${DIM}La première fois, répondez « yes », puis tapez le mot de passe de « $SUDO_USER » sur le Pi.${RESET}"
}

show_client() {
  local name=$1
  echo
  qrencode -t ansiutf8 -m 2 <"$CLIENTS_DIR/$name.conf"
  txt "  ↑ QR code de « ${BOLD}$name${RESET} » : application WireGuard › ${BOLD}+${RESET} › ${BOLD}Scanner un code QR${RESET}"
  if [[ -n $EXPORT_PATH ]]; then
    txt "  Fichier pour un ordinateur : ${BOLD}$EXPORT_PATH${RESET} (+ image .png du QR code)"
    print_fetch_hint "wireguard-clients/$name.conf"
    txt "  Puis dans l'application WireGuard : ${BOLD}Importer un tunnel depuis un fichier${RESET}."
  else
    txt "  Fichier de configuration : ${BOLD}$CLIENTS_DIR/$name.conf${RESET}"
  fi
  echo
}

# add_client <nom> <full|split>
add_client() {
  local name=$1 route=${2:-$DEFAULT_ROUTE} n priv pub psk addr allowed dns_line=""
  valid_name "$name" || { fail "Nom invalide : 1 à 15 caractères parmi lettres, chiffres, - et _ (sans espace ni accent)."; return 1; }
  client_exists "$name" && { fail "Un appareil nommé « $name » existe déjà."; return 1; }
  n=$(next_free_ip) || { fail "Plus d'adresse libre dans le VPN (253 appareils maximum)."; return 1; }
  priv=$(wg genkey)
  pub=$(wg pubkey <<<"$priv")
  psk=$(wg genpsk)

  addr="$WG_NET4.$n/32"
  (( IPV6_ON )) && addr+=", ${WG_NET6}$n/128"
  if [[ $route == split ]]; then
    allowed="$WG_NET4.0/24, $LAN_NET"
    (( IPV6_ON )) && allowed+=", ${WG_NET6}/64"
  else
    # ::/0 même sans IPv6 : évite que le trafic IPv6 sorte hors du tunnel
    allowed="0.0.0.0/0, ::/0"
  fi
  [[ -n $CLIENT_DNS ]] && dns_line="DNS = $CLIENT_DNS"

  {
    echo
    echo "$MARK $name"
    echo "[Peer]"
    echo "PublicKey = $pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $addr"
  } >>"$WG_CONF"

  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $addr"
    [[ -n $dns_line ]] && echo "$dns_line"
    echo
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUBKEY"
    echo "PresharedKey = $psk"
    echo "Endpoint = $(endpoint_str)"
    echo "AllowedIPs = $allowed"
    echo "PersistentKeepalive = $KEEPALIVE"
  } >"$CLIENTS_DIR/$name.conf"
  chmod 600 "$CLIENTS_DIR/$name.conf"

  reload_wg
  export_client "$name"
  ok "Appareil « $name » créé (adresse VPN $WG_NET4.$n)"
  show_client "$name"
}

# Dossier ~/wireguard-clients de l'utilisateur qui a lancé sudo (vide si root direct)
user_export_dir() {
  local user=${SUDO_USER:-} home
  [[ -n $user && $user != root ]] || return 0
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -n $home ]] && echo "$home/wireguard-clients"
}

remove_client() {
  local name=$1 tmp dir
  client_exists "$name" || { fail "Aucun appareil nommé « $name »."; return 1; }
  tmp=$(mktemp)
  # Les lignes vides sont retenues puis écrites devant la ligne suivante : pas de ligne vide en trop
  awk -v m="$MARK $name" -v p="$MARK " '
    $0 == m { skip = 1; next }
    skip && index($0, p) == 1 { skip = 0 }
    skip { next }
    /^[[:space:]]*$/ { blank = blank $0 "\n"; next }
    { printf "%s", blank; blank = ""; print }
  ' "$WG_CONF" >"$tmp" && cat "$tmp" >"$WG_CONF"
  rm -f "$tmp" "$CLIENTS_DIR/$name.conf"
  dir=$(user_export_dir)
  if [[ -n $dir ]]; then
    rm -f "$dir/$name.conf" "$dir/$name.png"
  else
    # Lancé sans sudo (interface web) : on retire la copie où qu'elle soit
    for dir in /home/*/wireguard-clients; do
      [[ -d $dir ]] && rm -f "$dir/$name.conf" "$dir/$name.png"
    done
  fi
  reload_wg
  ok "Appareil « $name » supprimé : il ne peut plus se connecter."
}

# pick_client <variable> <question> : fait choisir un appareil dans la liste
pick_client() {
  local -a names
  local c
  mapfile -t names < <(client_names)
  (( ${#names[@]} )) || { info "Aucun appareil pour l'instant. Ajoutez-en un avec : sudo wg-pi add"; return 1; }
  interactive || { fail "Précisez le nom de l'appareil (appareils : ${names[*]})."; return 1; }
  choose c "$2" 1 "${names[@]}"
  printf -v "$1" '%s' "${names[c - 1]}"
}

latest_handshake() { wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }
peer_endpoint()    { wg show "$WG_IF" endpoints 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }

# wait_handshake <clé publique> <secondes> : 0 = connecté, 1 = délai dépassé, 2 = passé par l'utilisateur
wait_handshake() {
  local pub=$1 timeout=${2:-300} start now ts
  start=$(date +%s)
  info "J'attends la connexion de l'appareil… (appuyez sur Entrée pour passer ce test)"
  while true; do
    ts=$(latest_handshake "$pub")
    if [[ -n $ts && $ts != 0 ]]; then printf '\r\033[K'; return 0; fi
    now=$(date +%s)
    if (( now - start >= timeout )); then printf '\r\033[K'; return 1; fi
    printf '\r   ⏳ encore %3d s… ' $(( timeout - (now - start) ))
    if IFS= read -r -t 2 _ <"$TTY"; then printf '\r\033[K'; return 2; fi
  done
}

# ----------------------------------------------------------------------------
# Guides
# ----------------------------------------------------------------------------
# print_box_guide <redirection 0|1> <réservation DHCP 0|1>
print_box_guide() {
  local fwd=${1:-1} res=${2:-0} name url fwd_path res_path host
  local -a extra=()
  host=$(hostname)
  case ${ISP:-} in
    free)
      name="Freebox"; url="http://mafreebox.freebox.fr (ou l'application Freebox Connect)"
      fwd_path="Paramètres de la Freebox › Mode avancé › Gestion des ports › Ajouter une redirection"
      res_path="Paramètres de la Freebox › DHCP › Baux statiques › Ajouter un bail DHCP statique"
      extra=("Ligne Free récente ? L'IPv4 est peut-être « partagée » : seuls certains ports sont alors"
             "redirigeables. Demandez l'IP fixe V4 « full-stack » (gratuit) dans l'espace abonné :"
             "Ma Freebox › Demander une adresse IP fixe V4 full-stack, puis redémarrez la Freebox.") ;;
    orange)
      name="Livebox"; url="http://192.168.1.1 (identifiant « admin », mot de passe sur l'étiquette de la box)"
      fwd_path="Paramètres avancés › Réseau › NAT/PAT (règle personnalisée)"
      res_path="Paramètres avancés › Réseau › DHCP › Baux DHCP statiques" ;;
    sfr)
      name="box SFR"; url="http://192.168.1.1"
      fwd_path="Réseau v4 › NAT (translation de ports)"
      res_path="Réseau v4 › DHCP › Adresses statiques" ;;
    bouygues)
      name="Bbox"; url="https://mabbox.bytel.fr (ou http://192.168.1.254)"
      fwd_path="Services de la Bbox › Redirection de ports (NAT/PAT)"
      res_path="Réseau domestique › DHCP › Attribuer une adresse IP fixe" ;;
    *)
      name="box"; url="http://${LAN_GW:-192.168.1.1}"
      fwd_path="menu « Redirection de ports », « NAT/PAT », « Port forwarding » ou « Serveur virtuel »"
      res_path="menu « DHCP » › « Bail statique » ou « Réservation d'adresse »" ;;
  esac

  txt "Connectez-vous à votre ${BOLD}$name${RESET} depuis un appareil de la maison :" "   $url" ""
  if (( fwd )); then
    txt "${BOLD}① Ouvrir le port du VPN${RESET} — $fwd_path"
    kv "Nom / application" "WireGuard"
    kv "Protocole" "UDP (pas TCP)"
    kv "Port externe" "$WG_PORT"
    kv "Port interne" "$WG_PORT"
    kv "Appareil / IP" "$LAN_IP ($host)"
    echo
  fi
  if (( res )); then
    txt "${BOLD}$( (( fwd )) && echo ② || echo ①) Réserver l'adresse du Pi${RESET} — $res_path"
    kv "Appareil (adresse MAC)" "$LAN_MAC ($host)"
    kv "Adresse IP" "$LAN_IP"
    echo
  fi
  if (( ${#extra[@]} )); then
    warn "${extra[0]}"
    printf '   %s\n' "${extra[@]:1}"
    echo
  fi
  txt "${DIM}(Les noms des menus peuvent varier légèrement selon le modèle de box.)${RESET}"
}

print_troubleshooting() {
  txt "" "${BOLD}Pistes à vérifier :${RESET}" \
      "  • La redirection du port ${BOLD}$WG_PORT en UDP${RESET} vers ${BOLD}$LAN_IP${RESET} est-elle enregistrée sur la box ?" \
      "  • Le téléphone est-il bien en 4G/5G (Wi-Fi coupé) ?" \
      "  • Le tunnel est-il activé dans l'application WireGuard ?" \
      "  • L'adresse « $ENDPOINT » est-elle à jour ? (IP publique actuelle : ${PUBLIC_IP:-inconnue})"
  [[ $ISP == free ]] && txt "  • Free : votre IPv4 est peut-être partagée (voir « sudo wg-pi box »)."
  txt "  • Lancez ${BOLD}sudo wg-pi check${RESET} pour un diagnostic complet." ""
}

# ----------------------------------------------------------------------------
# Installation : étapes
# ----------------------------------------------------------------------------
banner() {
  printf '\n%s\n' "${BOLD}${CYAN}  ╔════════════════════════════════════════════════╗"
  printf '%s\n'   "  ║   wg-pi — votre VPN WireGuard à la maison      ║"
  printf '%s\n'   "  ╚════════════════════════════════════════════════╝${RESET}  ${DIM}v$WGPI_VERSION${RESET}"
  echo
}

step_intro() {
  banner
  txt "Ce script transforme ce Raspberry Pi en ${BOLD}serveur VPN WireGuard${RESET}." \
      "Vos appareils (téléphone, PC…) pourront se connecter à la maison depuis" \
      "n'importe où, de façon chiffrée : Wi-Fi public sécurisé, accès au NAS, etc." "" \
      "Je m'occupe de tout : installation, clés, pare-feu, QR codes…" \
      "Votre seule tâche : ${BOLD}ouvrir un port sur la box${RESET} (je vous guide, ou je le fais via UPnP)." "" \
      "${DIM}Astuce : appuyez sur Entrée pour accepter la réponse proposée entre [crochets].${RESET}" ""
  pause
}

step_system() {
  title "Étape 1/$STEPS — Vérification du système"
  [[ -r /etc/os-release ]] || die "Système non reconnu (/etc/os-release absent)."
  local id like ver pretty model
  id=$(os_field ID); like=$(os_field ID_LIKE); ver=$(os_field VERSION_ID); pretty=$(os_field PRETTY_NAME)
  model=""
  [[ -r /proc/device-tree/model ]] && model=$(tr -d '\0' </proc/device-tree/model)
  kv "Système" "${pretty:-?}"
  kv "Matériel" "${model:-$(uname -m)}"
  kv "Noyau" "$(uname -r)"
  echo
  [[ $id == debian || $id == raspbian || $like == *debian* ]] ||
    die "Ce script est prévu pour Raspberry Pi OS / Debian (système détecté : ${pretty:-inconnu})."
  if [[ $id == debian || $id == raspbian ]] && [[ $ver =~ ^[0-9]+$ ]] && (( ver < 11 )); then
    die "Debian $ver est trop ancien : il faut Debian 11 (Bullseye) ou plus récent."
  fi
  [[ -d /run/systemd/system ]] || die "systemd est nécessaire."
  command -v apt-get >/dev/null 2>&1 || die "apt-get est introuvable."

  if [[ -f $WG_CONF ]]; then
    warn "Une configuration WireGuard existe déjà ($WG_CONF), peut-être créée par PiVPN ou à la main."
    txt "   Je peux la mettre de côté (copie de sauvegarde) et la remplacer. L'ancien VPN sera arrêté."
    ask_yn "Remplacer l'ancienne configuration ?" n || die "Installation annulée : rien n'a été modifié."
    systemctl disable --now "wg-quick@$WG_IF" >>"$LOG_FILE" 2>&1
    mv "$WG_CONF" "$WG_CONF.avant-wg-pi.$(date +%Y%m%d-%H%M%S)" || die "Impossible de déplacer $WG_CONF."
    ok "Ancienne configuration mise de côté dans $WG_DIR"
  fi

  ensure_packages wireguard-tools qrencode iptables curl ca-certificates ||
    die "L'installation des paquets a échoué (connexion Internet ?)."
  check_wg_module || exit 1
  ok "Système compatible, WireGuard est disponible"
}

step_network() {
  title "Étape 2/$STEPS — Votre réseau local"
  detect_network
  kv "Connexion" "$LAN_IF ($(iface_kind "$LAN_IF"))"
  kv "Adresse du Pi" "$LAN_IP"
  kv "Box (passerelle)" "${LAN_GW:-?}"
  kv "Réseau local" "$LAN_NET"
  kv "Adresse MAC" "$LAN_MAC"
  echo
  [[ $(iface_kind "$LAN_IF") == Wi-Fi ]] && { warn "Le Pi est en Wi-Fi : ça marche, mais un câble Ethernet est plus fiable pour un serveur."; echo; }
  is_private_ipv4 "$LAN_IP" || warn "Le Pi a directement une adresse publique : aucune box à configurer, a priori."

  if ! ip -4 addr show dev "$LAN_IF" | grep -q "inet $LAN_IP/.* dynamic"; then
    IP_MODE="static"
    ok "Le Pi a déjà une adresse IP fixe"
    return 0
  fi

  txt "La box a prêté l'adresse ${BOLD}$LAN_IP${RESET} à ce Pi, mais elle peut la changer un jour" \
      "(après une coupure…). Or la box doit toujours envoyer le VPN vers la même adresse." ""
  local -a opts=("Je réserverai cette adresse dans ma box (recommandé, je vous montre où à la fin)")
  local nm=0 c
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager &&
     LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q "^$LAN_IF:connected"; then
    nm=1
    opts+=("Fixer l'adresse $LAN_IP directement sur le Pi (NetworkManager)")
  fi
  opts+=("Je verrai plus tard")
  choose c "Comment garder cette adresse ?" 1 "${opts[@]}"
  if (( c == 1 )); then IP_MODE="reserve"
  elif (( nm && c == 2 )); then IP_MODE="nm"
  else IP_MODE="later"
  fi
}

set_static_nm() {
  local con dns
  con=$(LC_ALL=C nmcli -g GENERAL.CONNECTION device show "$LAN_IF" 2>/dev/null | sed 's/\\:/:/g')
  [[ -n $con ]] || return 1
  dns=$(LC_ALL=C nmcli -g IP4.DNS device show "$LAN_IF" 2>/dev/null | tr '|' ',' | tr -d ' ')
  [[ -n $dns ]] || dns=$LAN_GW
  nmcli con mod "$con" ipv4.method manual ipv4.addresses "$LAN_IP/$LAN_PREFIX" \
    ipv4.gateway "$LAN_GW" ipv4.dns "$dns" &&
    nmcli device reapply "$LAN_IF"
}

ask_duckdns() {
  interactive || { warn "DuckDNS demande une saisie : relancez sans --yes."; return 1; }
  txt "" "${BOLD}Créer votre nom DuckDNS (gratuit, 2 minutes) :${RESET}" \
      "  1. Sur votre téléphone ou PC, ouvrez ${BOLD}https://www.duckdns.org${RESET}" \
      "  2. Connectez-vous (compte Google, GitHub, Reddit…)" \
      "  3. Choisissez un nom (ex. ${BOLD}chezmoi-vpn${RESET}) puis cliquez sur « add domain »" \
      "  4. Copiez le ${BOLD}token${RESET} affiché en haut de la page" ""
  local sub token resp
  while true; do
    ask sub "Nom DuckDNS choisi, sans .duckdns.org (vide = annuler)" ""
    sub=${sub,,}; sub=${sub#*://}; sub=${sub%%/*}; sub=${sub%.duckdns.org}
    [[ -z $sub ]] && return 1
    [[ $sub =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && break
    warn "Nom invalide : lettres minuscules, chiffres et tirets uniquement."
  done
  while true; do
    ask token "Token DuckDNS (vide = annuler)" ""
    [[ -z $token ]] && return 1
    if [[ ! $token =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      warn "Ce n'est pas un token DuckDNS (format attendu : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
      continue
    fi
    info "Vérification auprès de DuckDNS…"
    resp=$(duckdns_call "$sub" "$token")
    [[ $resp == OK* ]] && break
    warn "DuckDNS a refusé (réponse : ${resp:-aucune}). Vérifiez le nom et le token."
  done
  ok "$sub.duckdns.org pointe maintenant vers votre maison (mis à jour toutes les 5 minutes)"
  DUCKDNS_DOMAIN=$sub DUCKDNS_TOKEN=$token ENDPOINT="$sub.duckdns.org" DDNS=duckdns
}

ask_hostname() {
  local h r
  while true; do
    ask h "Votre nom de domaine (vide = annuler)" ""
    h=${h,,}; h=${h#*://}; h=${h%%/*}
    [[ -z $h ]] && return 1
    is_hostname "$h" || { warn "Nom de domaine invalide."; continue; }
    r=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR == 1 { print $1 }')
    if [[ -z $r ]]; then
      warn "Ce nom ne pointe vers aucune adresse pour l'instant."
      ask_yn "L'utiliser quand même ?" n || continue
    elif [[ -n $PUBLIC_IP && $r != "$PUBLIC_IP" ]]; then
      warn "$h pointe vers $r, mais votre IP publique est $PUBLIC_IP."
      ask_yn "L'utiliser quand même ?" n || continue
    else
      ok "$h pointe bien vers votre IP publique"
    fi
    ENDPOINT=$h DDNS=none
    return 0
  done
}

# Choix de l'adresse publique (utilisé à l'installation et par « wg-pi endpoint »)
choose_endpoint() {
  info "Recherche de votre adresse IP publique…"
  PUBLIC_IP=$(get_public_ip) || PUBLIC_IP=""
  ISP=$(detect_isp "$PUBLIC_IP")
  if [[ -n $PUBLIC_IP ]]; then
    kv "IP publique" "$PUBLIC_IP"
    kv "Opérateur" "$(isp_label "$ISP")"
  else
    warn "Impossible de trouver votre IP publique (pas d'accès Internet ?)."
  fi
  echo
  if is_cgnat "$PUBLIC_IP"; then
    warn "Votre IP publique ($PUBLIC_IP) est partagée avec d'autres clients (CGNAT) : la box ne peut pas"
    warn "recevoir de connexions. Demandez une IPv4 publique à votre opérateur (souvent gratuit)."
    echo
  fi

  if [[ -n $OPT_ENDPOINT ]]; then
    OPT_ENDPOINT=${OPT_ENDPOINT,,}
    is_ipv4 "$OPT_ENDPOINT" || is_hostname "$OPT_ENDPOINT" || die "Adresse --endpoint invalide : $OPT_ENDPOINT"
    ENDPOINT=$OPT_ENDPOINT DDNS=none
    ok "Adresse publique imposée : $ENDPOINT"
    [[ $ENDPOINT == *.duckdns.org ]] &&
      warn "Une adresse donnée directement n'est pas mise à jour automatiquement. Pour DuckDNS, utilisez le menu (sudo wg-pi endpoint, sans adresse)."
    return 0
  fi

  case $ISP in
    orange) txt "Chez Orange, l'IP publique change de temps en temps (redémarrage de la Livebox…)." \
                "→ Un nom gratuit DuckDNS évite que le VPN tombe en panne ce jour-là." ;;
    free)   txt "Chez Free, l'IP publique est fixe : vous pouvez l'utiliser directement." \
                "(Le nom xxxx.freeboxos.fr de votre Freebox fonctionne aussi.)" ;;
    *)      txt "Si votre IP publique change un jour (ça arrive chez certains opérateurs)," \
                "un nom gratuit DuckDNS garde le VPN joignable automatiquement." ;;
  esac
  echo

  local def=1 c
  [[ $ISP == orange ]] && def=2
  [[ -z $PUBLIC_IP ]] && def=3
  if ! interactive; then
    [[ -n $PUBLIC_IP ]] || die "IP publique introuvable : précisez-la avec --endpoint <adresse>."
    def=1
  fi
  while true; do
    choose c "Quelle adresse vos appareils doivent-ils utiliser pour joindre la maison ?" "$def" \
      "Mon IP publique (${PUBLIC_IP:-inconnue})" \
      "Un nom gratuit DuckDNS (xxx.duckdns.org) mis à jour automatiquement — je vous guide" \
      "J'ai déjà un nom de domaine / DynDNS (xxxx.freeboxos.fr, No-IP…)"
    case $c in
      1) if [[ -n $PUBLIC_IP ]]; then ENDPOINT=$PUBLIC_IP DDNS=none; return 0; fi
         warn "IP publique inconnue : choisissez une autre option." ;;
      2) ask_duckdns && return 0 ;;
      3) ask_hostname && return 0 ;;
    esac
  done
}

configure_dns() {
  local -a labels=() values=()
  local c def=1 v6cf="" v6q9=""
  if (( IPV6_NAT )); then v6cf=", 2606:4700:4700::1111"; v6q9=", 2620:fe::fe"; fi
  DNS_LOCAL=0
  if detect_local_dns; then
    labels+=("$LOCAL_DNS_NAME installé sur ce Pi (filtre aussi les pubs en déplacement)")
    values+=("local")
    (( LOCAL_DNS_KNOWN )) || def=2
  fi
  if [[ -n $LAN_GW ]]; then
    labels+=("Le DNS de votre box ($LAN_GW) — simple, comme à la maison"); values+=("$LAN_GW")
  fi
  labels+=("Cloudflare (1.1.1.1) — rapide")                   ; values+=("1.1.1.1, 1.0.0.1$v6cf")
  labels+=("Quad9 (9.9.9.9) — bloque les sites malveillants") ; values+=("9.9.9.9, 149.112.112.112$v6q9")
  labels+=("Autre (saisie manuelle)")                         ; values+=("custom")

  choose c "Quel serveur DNS vos appareils utiliseront-ils à travers le VPN ?" "$def" "${labels[@]}"
  CLIENT_DNS=${values[c - 1]}
  if [[ $CLIENT_DNS == local ]]; then
    DNS_LOCAL=1
  elif [[ $CLIENT_DNS == custom ]]; then
    local d ok_all x
    while true; do
      ask d "Adresse(s) IP du DNS, séparées par des virgules" "1.1.1.1"
      ok_all=1
      for x in ${d//,/ }; do is_ipv4 "$x" || [[ $x =~ ^[0-9a-fA-F:]+$ && $x == *:* ]] || ok_all=0; done
      (( ok_all )) && break
      warn "Adresse invalide."
    done
    CLIENT_DNS=$(sed 's/ *, */, /g' <<<"$d")
  fi
}

step_vpn() {
  title "Étape 4/$STEPS — Réglages du VPN"
  detect_ipv6
  WG_NET4=$(pick_subnet)
  WG_NET6=$(random_ula)
  if [[ -n $OPT_PORT ]]; then
    valid_port "$OPT_PORT" || die "Port --port invalide : $OPT_PORT"
    port_in_use "$OPT_PORT" && die "Le port UDP $OPT_PORT est déjà utilisé sur ce Pi."
    WG_PORT=$OPT_PORT
  else
    WG_PORT=51820
    while port_in_use "$WG_PORT"; do (( WG_PORT++ )); done
  fi

  configure_dns
  echo
  local c
  choose c "Quand le VPN est activé sur un appareil, que doit-il faire passer par la maison ?" 1 \
    "Tout le trafic (recommandé : sécurité sur les Wi-Fi publics, accès « depuis la France » à l'étranger)" \
    "Seulement l'accès au réseau de la maison (NAS, Home Assistant, imprimante…), le reste en direct"
  if (( c == 2 )); then DEFAULT_ROUTE="split"; else DEFAULT_ROUTE="full"; fi
  echo

  if ask_yn "Modifier les réglages avancés (port UDP $WG_PORT, réseau du VPN $WG_NET4.0/24) ?" n; then
    local p n
    while true; do
      ask p "Port UDP du VPN" "$WG_PORT"
      if ! valid_port "$p"; then warn "Port invalide (1 à 65535)."; continue; fi
      if port_in_use "$p"; then warn "Ce port est déjà utilisé sur le Pi."; continue; fi
      WG_PORT=$((10#$p)); break
    done
    while true; do
      ask n "Réseau du VPN (les 3 premiers nombres, ex. 10.8.0)" "$WG_NET4"
      [[ $n =~ ^([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?(/24)?$ ]] && n=${BASH_REMATCH[1]}
      if ! is_ipv4 "$n.1" || ! is_private_ipv4 "$n.1"; then warn "Il faut un réseau privé (10.x.x, 172.16-31.x, 192.168.x)."; continue; fi
      if subnet_in_use "$n"; then warn "Ce réseau est déjà utilisé sur le Pi ou sa box."; continue; fi
      WG_NET4=$n; break
    done
  fi
  if (( DNS_LOCAL )); then
    if [[ $LOCAL_DNS_ADDR == wg ]]; then CLIENT_DNS="$WG_NET4.1"; else CLIENT_DNS=$LOCAL_DNS_ADDR; fi
  fi
  echo

  txt "Pour que le VPN soit joignable depuis Internet, la box doit laisser passer le port ${BOLD}$WG_PORT (UDP)${RESET}."
  if ask_yn "Essayer de l'ouvrir automatiquement (UPnP) ? Sinon je vous guiderai pas à pas." o; then UPNP=1; else UPNP=0; fi
  if ask_yn "Activer les mises à jour de sécurité automatiques du Pi (recommandé) ?" o; then UNATTENDED=1; else UNATTENDED=0; fi
}

step_recap() {
  title "Récapitulatif"
  kv "Adresse publique" "$(endpoint_str) (UDP)"
  [[ $DDNS == duckdns ]] && kv "Nom DuckDNS" "mis à jour automatiquement"
  kv "Adresse du Pi" "$LAN_IP ($LAN_IF)"
  kv "Réseau du VPN" "$WG_NET4.0/24$( (( IPV6_ON )) && echo " + ${WG_NET6}/64")"
  kv "IPv6 vers Internet" "$( (( IPV6_NAT )) && echo oui || echo "non (pas d'IPv6 publique sur le Pi)")"
  kv "DNS des appareils" "${CLIENT_DNS:-aucun}"
  kv "Trafic" "$([[ $DEFAULT_ROUTE == full ]] && echo "tout passe par la maison" || echo "réseau de la maison seulement")"
  kv "Ouverture du port" "$( (( UPNP )) && echo "automatique (UPnP), sinon guidée" || echo "guidée (manuelle)")"
  kv "Mises à jour auto" "$( (( UNATTENDED )) && echo oui || echo non)"
  case $IP_MODE in
    nm)      kv "IP du Pi" "fixée sur le Pi" ;;
    reserve) kv "IP du Pi" "à réserver dans la box" ;;
  esac
  echo
  ask_yn "Tout est bon, on lance l'installation ?" o ||
    die "Installation annulée : seuls les paquets ont été installés, rien n'est configuré."
}

step_apply() {
  title "Étape 5/$STEPS — Installation"
  if [[ $IP_MODE == nm ]]; then
    run "Fixation de l'adresse IP $LAN_IP sur le Pi" set_static_nm ||
      { warn "Échec : faites plutôt la réservation dans la box."; IP_MODE="reserve"; }
  fi
  (( UPNP )) && { ensure_packages miniupnpc || { warn "UPnP indisponible."; UPNP=0; }; }

  install -d -m 700 "$WG_DIR" "$STATE_DIR" "$CLIENTS_DIR"
  run "Génération des clés et de la configuration du serveur" write_server_conf || die "Échec de la configuration."
  [[ $DDNS == duckdns ]] && save_duckdns
  save_settings
  apply_system || die "L'installation a échoué. Journal complet : $LOG_FILE"
  ok "Serveur WireGuard installé et démarré (il redémarrera tout seul avec le Pi)"
}

step_box() {
  title "Étape 6/$STEPS — Ouvrir le port sur votre box"
  local res=0
  [[ $IP_MODE == reserve || $IP_MODE == later ]] && res=1
  if (( UPNP_OK )); then
    ok "Le port $WG_PORT/UDP a été ouvert automatiquement : rien à faire de ce côté-là !"
    if (( res )); then
      echo
      txt "Il reste à réserver l'adresse du Pi dans la box :" ""
      print_box_guide 0 1
    fi
  else
    print_box_guide 1 "$res"
  fi
  echo
  pause "Quand c'est fait, appuyez sur Entrée pour créer votre premier appareil…"
}

step_first_client() {
  title "Étape 7/$STEPS — Votre premier appareil"
  local name pub rc
  while true; do
    ask name "Nom du premier appareil (ex. telephone, pc-portable)" "${OPT_CLIENT:-telephone}"
    valid_name "$name" && break
    warn "Nom invalide : 1 à 15 caractères parmi lettres, chiffres, - et _ (sans espace ni accent)."
    interactive || die "Nom d'appareil invalide : $name"
  done
  add_client "$name" "$DEFAULT_ROUTE" || return 1
  interactive || return 0

  txt "${BOLD}Testons tout de suite depuis votre téléphone :${RESET}" \
      "  1. Installez l'application ${BOLD}WireGuard${RESET} (App Store / Google Play)" \
      "  2. Appuyez sur ${BOLD}+${RESET} › ${BOLD}Scanner un code QR${RESET} et visez le QR code ci-dessus" \
      "  3. ${BOLD}Coupez le Wi-Fi${RESET} du téléphone (pour passer par la 4G/5G) puis activez le tunnel" ""
  pub=$(client_pubkey "$name")
  wait_handshake "$pub" 300
  rc=$?
  case $rc in
    0) ok "🎉 Ça marche ! « $name » est connecté (depuis $(peer_endpoint "$pub"))." ;;
    1) warn "Aucune connexion reçue pour l'instant."; print_troubleshooting ;;
    *) info "Test passé. Vous pourrez vérifier plus tard avec : sudo wg-pi list" ;;
  esac
}

step_done() {
  title "C'est terminé 🎉"
  txt "Votre serveur VPN tourne et redémarrera tout seul avec le Pi." "" \
      "${BOLD}Commandes utiles${RESET} (à taper sur le Pi) :" \
      "  ${BOLD}sudo wg-pi${RESET}               menu (ajouter / supprimer des appareils…)" \
      "  ${BOLD}sudo wg-pi add pc${RESET}        ajouter un appareil et afficher son QR code" \
      "  ${BOLD}sudo wg-pi list${RESET}          voir les appareils et qui est connecté" \
      "  ${BOLD}sudo wg-pi check${RESET}         diagnostic si quelque chose ne marche pas" \
      "  ${BOLD}sudo wg-pi backup${RESET}        sauvegarde (les cartes SD finissent par s'user !)" \
      "  ${BOLD}sudo wg-pi web${RESET}           gérer le VPN depuis un navigateur (QR codes, appareils…)" \
      "  ${BOLD}sudo wg-pi update${RESET}        mettre à jour wg-pi" \
      "  ${BOLD}sudo wg-pi help${RESET}          toutes les commandes" ""
  [[ -f /run/reboot-required ]] && warn "Le système demande un redémarrage (mises à jour en attente) : sudo reboot"
  return 0
}

cmd_install() {
  while (( $# )); do
    case $1 in
      --endpoint) OPT_ENDPOINT=${2:-}; shift ;;
      --port)     OPT_PORT=${2:-}; shift ;;
      --client)   OPT_CLIENT=${2:-}; shift ;;
      *) die "Option inconnue : $1 (voir : wg-pi help)" ;;
    esac
    shift
  done
  is_installed && die "wg-pi est déjà installé. Menu : sudo wg-pi — pour repartir de zéro : sudo wg-pi uninstall"
  take_lock
  step_intro
  step_system
  step_network
  title "Étape 3/$STEPS — Comment vos appareils trouveront votre maison"
  choose_endpoint
  step_vpn
  step_recap
  step_apply
  step_box
  step_first_client
  step_done
}

# ----------------------------------------------------------------------------
# Commandes de gestion
# ----------------------------------------------------------------------------
cmd_add() {
  load_settings
  take_lock
  local name="" route=$DEFAULT_ROUTE c a
  for a in "$@"; do
    case $a in
      --split) route="split" ;;
      --full)  route="full" ;;
      -*) die "Option inconnue : $a" ;;
      *) name=$a ;;
    esac
  done
  if [[ -z $name ]]; then
    while true; do
      ask name "Nom du nouvel appareil (ex. pc-portable, tablette)" ""
      valid_name "$name" && ! client_exists "$name" && break
      if client_exists "$name"; then warn "Ce nom est déjà pris."; else warn "Nom invalide : 1 à 15 caractères parmi lettres, chiffres, - et _."; fi
      interactive || exit 1
    done
    choose c "Que doit faire passer cet appareil par la maison ?" "$([[ $route == split ]] && echo 2 || echo 1)" \
      "Tout son trafic" "Seulement l'accès au réseau de la maison"
    if (( c == 2 )); then route="split"; else route="full"; fi
  fi
  add_client "$name" "$route"
}

cmd_remove() {
  load_settings
  take_lock
  local name=${1:-}
  [[ -n $name ]] || pick_client name "Quel appareil supprimer ?" || return 1
  client_exists "$name" || die "Aucun appareil nommé « $name »."
  if (( ! AUTO )); then
    ask_yn "Supprimer « $name » ? Il ne pourra plus se connecter." n || { info "Rien n'a été supprimé."; return 0; }
  fi
  remove_client "$name"
}

# cmd_set_state on|off [nom] : rétablit ou coupe l'accès d'un appareil (sans le supprimer)
cmd_set_state() {
  load_settings
  take_lock
  local want=$1 name=${2:-}
  [[ -n $name ]] || pick_client name "Quel appareil ?" || return 1
  client_exists "$name" || die "Aucun appareil nommé « $name »."
  if [[ $(client_state "$name") == "$want" ]]; then
    ok "« $name » est déjà $([[ $want == on ]] && echo activé || echo désactivé)."
    return 0
  fi
  set_client_state "$name" "$want" || die "Impossible de modifier « $name »."
  if [[ $want == off ]]; then
    ok "Accès de « $name » coupé : il ne peut plus se connecter (pour le rétablir : sudo wg-pi enable $name)."
  else
    ok "Accès de « $name » rétabli."
  fi
}

# Menu : bascule l'état d'un appareil
cmd_toggle() {
  load_settings
  local name
  pick_client name "Quel appareil ?" || return 1
  if [[ $(client_state "$name") == off ]]; then cmd_set_state on "$name"; else cmd_set_state off "$name"; fi
}

cmd_rename() {
  load_settings
  take_lock
  local old=${1:-} new=${2:-} tmp dir
  [[ -n $old ]] || pick_client old "Quel appareil renommer ?" || return 1
  client_exists "$old" || die "Aucun appareil nommé « $old »."
  [[ -n $new ]] || ask new "Nouveau nom pour « $old »" ""
  if ! valid_name "$new"; then
    die "Nom invalide : 1 à 15 caractères parmi lettres, chiffres, - et _ (sans espace ni accent)."
  fi
  [[ $new == "$old" ]] && { info "Le nom ne change pas."; return 0; }
  client_exists "$new" && die "Un appareil nommé « $new » existe déjà."
  tmp=$(mktemp) || die "Impossible de créer un fichier temporaire."
  awk -v o="$MARK $old" -v n="$MARK $new" '$0 == o { print n; next } { print }' "$WG_CONF" >"$tmp" &&
    cat "$tmp" >"$WG_CONF"
  rm -f "$tmp"
  mv -f "$CLIENTS_DIR/$old.conf" "$CLIENTS_DIR/$new.conf"
  for dir in /home/*/wireguard-clients; do
    [[ -f $dir/$old.conf ]] && mv -f "$dir/$old.conf" "$dir/$new.conf"
    [[ -f $dir/$old.png ]] && mv -f "$dir/$old.png" "$dir/$new.png"
  done
  ok "« $old » s'appelle maintenant « $new » (rien à changer sur l'appareil)."
}

cmd_qr() {
  load_settings
  local name=${1:-}
  [[ -n $name ]] || pick_client name "Quel appareil ?" || return 1
  [[ -f $CLIENTS_DIR/$name.conf ]] || die "Aucun appareil nommé « $name »."
  export_client "$name"
  show_client "$name"
}

cmd_list() {
  load_settings
  local -A hs=() rx=() tx=() ep=()
  local pub _psk endpoint _allowed latest r t _ka name ip state shown count=0 online=0 now
  if wg show "$WG_IF" >/dev/null 2>&1; then
    while IFS=$'\t' read -r pub _psk endpoint _allowed latest r t _ka; do
      hs["$pub"]=$latest rx["$pub"]=$r tx["$pub"]=$t ep["$pub"]=$endpoint
    done < <(wg show "$WG_IF" dump | tail -n +2)
  fi
  now=$(date +%s)
  echo
  if wg_running; then
    printf '  %s\n' "Serveur : ${GREEN}● actif${RESET} — $(endpoint_str) — réseau $WG_NET4.0/24"
  else
    printf '  %s\n' "Serveur : ${RED}● arrêté${RESET} (sudo systemctl restart wg-quick@$WG_IF)"
  fi
  echo
  printf '  %s %s %s %s  %s\n' "$(pad APPAREIL 16)" "$(pad "IP VPN" 13)" "$(pad REÇU 9)" "$(pad ENVOYÉ 9)" "DERNIÈRE CONNEXION"
  while read -r name ip pub state; do
    (( count++ ))
    latest=${hs["$pub"]:-0}
    if [[ $state == off ]]; then
      shown="${YELLOW}⏸ désactivé${RESET} ${DIM}(sudo wg-pi enable $name)${RESET}"
    elif (( latest == 0 )); then
      shown="${DIM}jamais${RESET}"
    elif (( now - latest < 180 )); then
      shown="${GREEN}● connecté${RESET} (${ep["$pub"]:-?})"
      (( online++ ))
    else
      shown=$(ago "$latest")
    fi
    printf '  %s %s %s %s  %s\n' "$(pad "$name" 16)" "$(pad "$ip" 13)" \
      "$(pad "$(human "${rx["$pub"]:-0}")" 9)" "$(pad "$(human "${tx["$pub"]:-0}")" 9)" "$shown"
  done < <(peers_table)
  echo
  if (( count )); then
    info "$count appareil(s), dont $online connecté(s) en ce moment."
  else
    info "Aucun appareil pour l'instant. Ajoutez-en un avec : sudo wg-pi add"
  fi
}

cmd_check() {
  load_settings
  title "Diagnostic wg-pi"
  local problems=0 cur r ts online=0 total=0 now
  if wg_running; then ok "Service WireGuard actif"
  else fail "Service WireGuard arrêté → sudo systemctl restart wg-quick@$WG_IF  (détails : journalctl -u wg-quick@$WG_IF)"; (( problems++ ))
  fi
  if port_in_use "$WG_PORT"; then ok "WireGuard écoute sur le port $WG_PORT/UDP"
  else fail "Personne n'écoute sur le port $WG_PORT/UDP"; (( problems++ ))
  fi
  if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]]; then ok "Routage IPv4 activé"
  else fail "Routage IPv4 désactivé → sudo sysctl -p $SYSCTL_FILE"; (( problems++ ))
  fi
  if iptables -w -t nat -C POSTROUTING -s "$WG_NET4.0/24" ! -o "$WG_IF" -j MASQUERADE 2>/dev/null; then ok "Partage de connexion (NAT) en place"
  else fail "Règle NAT absente → sudo systemctl restart wg-quick@$WG_IF"; (( problems++ ))
  fi

  cur=$(current_lan_ip)
  if [[ $cur == "$LAN_IP" ]]; then ok "Adresse du Pi inchangée ($LAN_IP)"
  else
    fail "L'adresse du Pi a changé : $LAN_IP → ${cur:-aucune}. La redirection de la box pointe vers l'ancienne adresse !"
    txt "   Corrigez la redirection (sudo wg-pi box) et réservez l'adresse dans la box."
    (( problems++ ))
  fi

  PUBLIC_IP=$(get_public_ip) || PUBLIC_IP=""
  if [[ -z $PUBLIC_IP ]]; then
    warn "Impossible de connaître l'IP publique (pas d'accès Internet ?)"; (( problems++ ))
  else
    if is_ipv4 "$ENDPOINT"; then r=$ENDPOINT; else r=$(getent ahostsv4 "$ENDPOINT" 2>/dev/null | awk 'NR == 1 { print $1 }'); fi
    if [[ $r == "$PUBLIC_IP" ]]; then ok "L'adresse des appareils ($ENDPOINT) correspond à l'IP publique ($PUBLIC_IP)"
    else
      fail "Les appareils contactent $ENDPOINT (${r:-introuvable}) mais l'IP publique est maintenant $PUBLIC_IP !"
      if [[ $DDNS == duckdns ]]; then txt "   La mise à jour DuckDNS va corriger ça (sinon : sudo systemctl start wg-pi-duckdns)."
      else txt "   Changez l'adresse avec : sudo wg-pi endpoint (DuckDNS recommandé pour ne plus y penser)."
      fi
      (( problems++ ))
    fi
    is_cgnat "$PUBLIC_IP" && { fail "IP publique partagée (CGNAT) : la box ne peut pas recevoir de connexion."; (( problems++ )); }
  fi

  if [[ $DDNS == duckdns ]]; then
    if systemctl is-active --quiet wg-pi-duckdns.timer; then ok "Mise à jour DuckDNS automatique active"
    else fail "Mise à jour DuckDNS inactive → sudo systemctl enable --now wg-pi-duckdns.timer"; (( problems++ ))
    fi
  fi
  if (( UPNP )); then
    if command -v upnpc >/dev/null 2>&1 && upnp_has_mapping; then ok "Port $WG_PORT/UDP ouvert sur la box (vérifié via UPnP)"
    else warn "Redirection UPnP introuvable sur la box (si vous l'avez faite à la main, ignorez ceci)"
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active"; then
    if LC_ALL=C ufw status | grep -qE "^$WG_PORT/udp +ALLOW"; then ok "Pare-feu UFW : port $WG_PORT/udp autorisé"
    else fail "Pare-feu UFW actif sans règle pour le VPN → sudo ufw allow $WG_PORT/udp"; (( problems++ ))
    fi
  fi

  if [[ -f $UNIT_DIR/$WEB_UNIT ]]; then
    local wport
    wport=$(web_conf_get port)
    if systemctl is-active --quiet "$WEB_UNIT" && tcp_port_in_use "$wport"; then
      ok "Interface web active : $(web_url "$LAN_IP" "$wport")"
    else
      fail "Interface web arrêtée → sudo wg-pi web  (journal : journalctl -u $WEB_UNIT)"; (( problems++ ))
    fi
  fi

  now=$(date +%s)
  local name state off_names=""
  while read -r name _ pub state; do
    (( total++ ))
    if [[ $state == off ]]; then off_names+=" $name"; continue; fi
    ts=$(latest_handshake "$pub")
    [[ -n $ts ]] && (( ts > 0 && now - ts < 180 )) && (( online++ ))
  done < <(peers_table)
  info "$total appareil(s) configuré(s), $online connecté(s) en ce moment"
  [[ -n $off_names ]] && warn "Accès coupé pour :$off_names (ils ne peuvent pas se connecter) → sudo wg-pi enable <nom>"
  [[ -f /run/reboot-required ]] && warn "Un redémarrage est demandé par les mises à jour : sudo reboot"

  echo
  if (( problems == 0 )); then
    ok "${BOLD}Tout est en ordre côté Pi.${RESET}"
    [[ -n $off_names ]] && txt "   Un appareil désactivé ne peut pas se connecter : vérifiez d'abord la liste ci-dessus."
    txt "   Si un appareil n'arrive pas à se connecter, c'est presque toujours la redirection du port" \
        "   $WG_PORT/UDP sur la box (sudo wg-pi box). Testez en 4G, pas sur le Wi-Fi de la maison."
  else
    warn "$problems problème(s) détecté(s), voir ci-dessus."
  fi
  echo
}

cmd_box() {
  load_settings
  local old_ip=$LAN_IP
  detect_network
  title "Configurer la box"
  if [[ $LAN_IP != "$old_ip" ]]; then
    warn "L'adresse du Pi a changé : $old_ip → $LAN_IP. La redirection de la box doit maintenant pointer vers $LAN_IP."
    if ask_yn "Enregistrer la nouvelle adresse du Pi ?" o; then
      take_lock
      save_settings
      if (( IPV6_NAT )); then write_sysctl; sysctl -q -p "$SYSCTL_FILE" >>"$LOG_FILE" 2>&1; fi
      ok "Nouvelle adresse enregistrée"
    fi
    echo
  fi
  print_box_guide 1 1
  echo
}

cmd_endpoint() {
  load_settings
  take_lock
  local f
  OPT_ENDPOINT=${1:-}
  if [[ $DDNS == duckdns && -n $OPT_ENDPOINT && ${OPT_ENDPOINT,,} == "$ENDPOINT" ]]; then
    ok "$ENDPOINT est déjà l'adresse utilisée, avec mise à jour DuckDNS automatique : rien à changer."
    return 0
  fi
  title "Changer l'adresse publique (actuellement : $ENDPOINT)"
  choose_endpoint
  for f in "$CLIENTS_DIR"/*.conf; do
    [[ -f $f ]] && sed -i "s|^Endpoint = .*|Endpoint = $(endpoint_str)|" "$f"
  done
  [[ $DDNS == duckdns ]] && save_duckdns
  save_settings
  install_self
  setup_timers
  for f in "$CLIENTS_DIR"/*.conf; do [[ -f $f ]] && export_client "$(basename "$f" .conf)"; done
  ok "Nouvelle adresse : $(endpoint_str)"
  warn "Les appareils déjà configurés doivent réimporter leur configuration : sudo wg-pi qr <nom>"
}

backup_dir() {
  local user=${SUDO_USER:-} home
  if [[ -n $user && $user != root ]]; then
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -d $home ]] && { echo "$home"; return; }
  fi
  echo /root
}

cmd_backup() {
  load_settings
  local f
  f="$(backup_dir)/wg-pi-sauvegarde-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$f" -C / "${WG_CONF#/}" "${STATE_DIR#/}" || die "La sauvegarde a échoué."
  chmod 600 "$f"
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && chown "$SUDO_USER:" "$f"
  ok "Sauvegarde créée : ${BOLD}$f${RESET}"
  warn "Elle contient les clés du VPN : gardez-la en lieu sûr (pas par e-mail)."
  # Copiée hors du Pi, elle survit à une carte SD morte
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && print_fetch_hint "$(basename "$f")"
  txt "  Restauration (ex. sur une nouvelle carte SD), depuis le dossier de la sauvegarde :" \
      "    curl -fsSL $WGPI_URL | sudo bash -s -- restore $(basename "$f")"
}

cmd_restore() {
  local file=${1:-} old_ip
  [[ -n $file ]] || die "Usage : sudo wg-pi restore <fichier.tar.gz>  (sur un Pi neuf : curl -fsSL $WGPI_URL | sudo bash -s -- restore <fichier.tar.gz>)"
  [[ -f $file ]] || die "Fichier introuvable : $file"
  tar -tzf "$file" 2>/dev/null | grep -qx "${SETTINGS_FILE#/}" || die "Ce fichier n'est pas une sauvegarde wg-pi."
  take_lock
  if is_installed || [[ -f $WG_CONF ]]; then
    ask_yn "Une configuration existe déjà ici. L'écraser avec la sauvegarde ?" n || die "Restauration annulée."
  fi
  title "Restauration de la sauvegarde"
  ensure_packages wireguard-tools qrencode iptables curl ca-certificates || die "L'installation des paquets a échoué."
  check_wg_module || exit 1
  systemctl stop "wg-quick@$WG_IF" >/dev/null 2>&1
  install -d -m 700 "$WG_DIR"
  run "Extraction de la sauvegarde" tar -xzf "$file" -C / "${WG_CONF#/}" "${STATE_DIR#/}" || die "Extraction impossible."
  load_settings
  old_ip=$LAN_IP
  detect_network
  [[ $old_ip != "$LAN_IP" ]] && warn "L'adresse du Pi a changé ($old_ip → $LAN_IP) : mettez à jour la redirection de port sur la box (sudo wg-pi box)."
  (( UPNP )) && { ensure_packages miniupnpc || UPNP=0; }
  save_settings
  apply_system || die "La restauration a échoué. Journal : $LOG_FILE"
  ok "Restauration terminée : vos appareils peuvent se reconnecter sans rien changer."
  # L'interface web était activée dans la sauvegarde : on la remet en route (pas si elle avait été coupée)
  if [[ $(web_conf_get enabled) == 1 && -n $(web_conf_get password) && -s $WEB_DIR/cert.pem ]] &&
     ensure_packages python3 openssl; then
    local wport
    wport=$(web_conf_get port)
    web_write_unit
    web_ufw allow "$wport"
    if web_start "$wport"; then ok "Interface web réactivée : $(web_url "$LAN_IP" "$wport")"
    else warn "Interface web non redémarrée : sudo wg-pi web"
    fi
  fi
}

cmd_uninstall() {
  load_settings
  take_lock
  warn "Cela supprime le serveur VPN et la configuration de tous les appareils."
  if (( ! AUTO )); then
    ask_yn "Désinstaller wg-pi ?" n || { info "Rien n'a été modifié."; return 0; }
  fi
  ask_yn "Faire une sauvegarde avant ?" o && cmd_backup
  systemctl disable --now "wg-quick@$WG_IF" >>"$LOG_FILE" 2>&1
  local t wport
  for t in wg-pi-duckdns wg-pi-upnp; do
    systemctl disable --now "$t.timer" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$t.service" "$UNIT_DIR/$t.timer"
  done
  if [[ -f $UNIT_DIR/$WEB_UNIT ]]; then
    wport=$(web_conf_get port)
    systemctl disable --now "$WEB_UNIT" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$WEB_UNIT"
    [[ -n $wport ]] && web_ufw delete "$wport"
  fi
  systemctl daemon-reload
  (( UPNP )) && command -v upnpc >/dev/null 2>&1 && upnpc -m "$LAN_IF" -d "$WG_PORT" UDP >/dev/null 2>&1
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw delete allow "$WG_PORT/udp" >/dev/null 2>&1
  fi
  # Copies des configurations dans ~/wireguard-clients (elles contiennent les clés des appareils)
  local dir name
  dir=$(user_export_dir)
  if [[ -n $dir && -d $dir ]]; then
    while read -r name; do rm -f "$dir/$name.conf" "$dir/$name.png"; done < <(client_names)
    rmdir "$dir" 2>/dev/null
  fi
  rm -f "$WG_CONF" "$SYSCTL_FILE" "$UNATTENDED_FILE"
  rm -rf "$STATE_DIR"
  rm -f "$BIN_PATH"
  ok "wg-pi est désinstallé."
  txt "   • Les paquets restent installés (pour les retirer : sudo apt remove wireguard-tools qrencode miniupnpc)." \
      "   • Pensez à supprimer la redirection du port $WG_PORT/UDP sur la box." \
      "   • Le routage restera actif jusqu'au prochain redémarrage du Pi."
  (( UNATTENDED )) && txt "   • Les mises à jour de sécurité automatiques restent actives (c'est recommandé)."
  [[ $IP_MODE == nm ]] && txt "   • L'adresse IP fixe du Pi ($LAN_IP) reste configurée dans NetworkManager."
  return 0
}

cmd_update() {
  load_settings
  take_lock
  local tmp new old
  old=$(script_version "$BIN_PATH" 2>/dev/null)
  old=${old:-$WGPI_VERSION}
  info "Recherche d'une nouvelle version sur $WGPI_REPO…"
  command -v curl >/dev/null 2>&1 || ensure_packages curl ca-certificates || die "curl est nécessaire."
  download_script tmp || die "Téléchargement impossible, ou fichier reçu invalide (rien n'a été changé). Détails : $LOG_FILE"
  new=$(script_version "$tmp")
  if [[ -f $BIN_PATH ]] && cmp -s "$tmp" "$BIN_PATH"; then
    rm -f "$tmp"
    ok "wg-pi est déjà à jour (v$old)."
    return 0
  fi
  # Jamais de retour en arrière (ex. API en panne juste après un envoi → lien « main » encore en cache)
  if [[ -n $new ]] && version_lt "$new" "$old"; then
    rm -f "$tmp"
    ok "Pas de version plus récente sur le dépôt (installée : v$old, dépôt : v$new)."
    return 0
  fi
  put_bin "$tmp" || { rm -f "$tmp"; die "Impossible de remplacer $BIN_PATH."; }
  rm -f "$tmp"
  ok "wg-pi mis à jour : v$old → v${new:-?} (vos réglages et appareils ne changent pas)"
  # L'interface web est générée par la commande : on la relance pour qu'elle prenne la nouvelle version
  systemctl try-restart "$WEB_UNIT" >/dev/null 2>&1
  return 0
}

# ----------------------------------------------------------------------------
# Interface web (sudo wg-pi web) : panneau HTTPS servi par le Pi, accessible
# seulement depuis le réseau local et le VPN. Toutes les actions passent par wg-pi.
# ----------------------------------------------------------------------------
web_conf_get() { sed -n "s/^$1=//p" "$WEB_CONF" 2>/dev/null | head -n1; }

web_conf_set() {
  local tmp
  install -d -m 700 "$STATE_DIR"
  tmp=$(mktemp) || return 1
  { grep -v "^$1=" "$WEB_CONF" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  cat "$tmp" >"$WEB_CONF"
  rm -f "$tmp"
  chmod 600 "$WEB_CONF"
}

tcp_port_in_use() { [[ -n $(ss -Hltn "sport = :$1" 2>/dev/null) ]]; }

# Certificat auto-signé conforme aux exigences d'Apple (825 jours max, usage « serveur », pas une AC),
# sinon Safari sur iPhone/Mac peut refuser la connexion. Renouvelé automatiquement par web-serve.
web_make_cert() {
  local host cfg rc
  host=$(hostname)
  install -d -m 700 "$WEB_DIR"
  cfg=$(mktemp) || return 1
  cat >"$cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = wg-pi $host
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = IP:$LAN_IP,IP:$WG_NET4.1,DNS:$host,DNS:$host.local
EOF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
    -config "$cfg" -keyout "$WEB_DIR/key.pem" -out "$WEB_DIR/cert.pem"
  rc=$?
  rm -f "$cfg"
  (( rc == 0 )) && chmod 600 "$WEB_DIR/key.pem" "$WEB_DIR/cert.pem"
  return $rc
}

# Hache le mot de passe lu sur l'entrée standard (PBKDF2-SHA256, sel aléatoire)
web_hash_password() {
  python3 -I -c '
import hashlib, os, sys
pw = sys.stdin.buffer.read()
salt = os.urandom(16)
rounds = 200000
print("pbkdf2_sha256$%d$%s$%s" % (rounds, salt.hex(), hashlib.pbkdf2_hmac("sha256", pw, salt, rounds).hex()))'
}

web_set_password() {
  local p1="" p2 hash generated=0
  if interactive; then
    while true; do
      printf '%s ' "${BOLD}?${RESET} Mot de passe de l'interface web (8 caractères minimum) :"
      IFS= read -rs p1 <"$TTY" || p1=""
      echo
      (( ${#p1} >= 8 )) || { warn "Trop court : 8 caractères minimum."; continue; }
      printf '%s ' "${BOLD}?${RESET} Retapez-le pour confirmer :"
      IFS= read -rs p2 <"$TTY" || p2=""
      echo
      [[ $p1 == "$p2" ]] && break
      warn "Les deux saisies sont différentes, recommencez."
    done
  else
    p1=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
    generated=1
  fi
  hash=$(printf '%s' "$p1" | web_hash_password) || return 1
  [[ $hash == pbkdf2_sha256\$* ]] || return 1
  web_conf_set password "$hash"
  (( generated )) && warn "Mot de passe généré (notez-le, il ne sera plus affiché) : $p1"
  return 0
}

# web_ufw allow|delete <port> : autorise le panneau depuis le réseau local et le VPN si UFW est actif
web_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active" || return 0
  local net
  for net in "$LAN_NET" "$WG_NET4.0/24"; do
    if [[ $1 == allow ]]; then
      ufw allow from "$net" to any port "$2" proto tcp comment "wg-pi web" >>"$LOG_FILE" 2>&1
    else
      ufw delete allow from "$net" to any port "$2" proto tcp >>"$LOG_FILE" 2>&1
    fi
  done
}

web_write_unit() {
  write_unit "$WEB_UNIT" "[Unit]" "Description=wg-pi : interface web d'administration du VPN" \
    "Wants=network-online.target" "After=network-online.target wg-quick@$WG_IF.service" "" \
    "[Service]" "ExecStart=$BIN_PATH web-serve" "Restart=on-failure" "RestartSec=5" \
    "RuntimeDirectory=wg-pi-web" "RuntimeDirectoryMode=0700" "NoNewPrivileges=yes" "PrivateTmp=yes" "" \
    "[Install]" "WantedBy=multi-user.target"
  systemctl daemon-reload
}

# Démarre (ou redémarre) le service et attend que CE service écoute sur le port (et pas un autre
# programme). En cas d'échec, le service est désactivé pour ne pas redémarrer en boucle.
web_start() {
  local port=$1 i pid
  systemctl enable "$WEB_UNIT" >>"$LOG_FILE" 2>&1
  if systemctl restart "$WEB_UNIT" >>"$LOG_FILE" 2>&1; then
    for (( i = 0; i < 20; i++ )); do
      sleep 0.5
      pid=$(systemctl show -p MainPID --value "$WEB_UNIT" 2>/dev/null)
      [[ -n $pid && $pid != 0 ]] && ss -Hltnp "sport = :$port" 2>/dev/null | grep -q "pid=$pid," && return 0
    done
  fi
  systemctl disable --now "$WEB_UNIT" >>"$LOG_FILE" 2>&1
  return 1
}

# web_url <hôte> <port> : adresse du panneau (sans « :443 », le port par défaut du HTTPS)
web_url() { if [[ $2 == 443 ]]; then echo "https://$1"; else echo "https://$1:$2"; fi; }

# Port proposé : 443 (adresse sans numéro) s'il est libre, sinon 51821 ou le suivant libre
web_pick_port() {
  local p=443
  if tcp_port_in_use "$p"; then
    p=$WEB_DEFAULT_PORT
    while tcp_port_in_use "$p"; do (( p++ )); done
  fi
  echo "$p"
}

web_print_access() {
  local port=$1
  echo
  txt "Ouvrez dans un navigateur (ordinateur ou téléphone) :"
  kv "Depuis la maison" "$(web_url "$LAN_IP" "$port")"
  # Nom en .local : publié sur le réseau par avahi (présent sur Raspberry Pi OS)
  systemctl is-active --quiet avahi-daemon 2>/dev/null && kv "ou par son nom" "$(web_url "$(hostname).local" "$port")"
  kv "Depuis le VPN" "$(web_url "$WG_NET4.1" "$port")"
  echo
  txt "${DIM}La première fois, le navigateur affiche un avertissement de sécurité : c'est normal, le certificat${RESET}" \
      "${DIM}a été créé par le Pi lui-même. Choisissez « Paramètres avancés » puis « Continuer vers le site ».${RESET}" \
      "${DIM}Le panneau n'est joignable que depuis le réseau de la maison et le VPN : rien à ouvrir sur la box.${RESET}" "" \
      "  Mot de passe : ${BOLD}sudo wg-pi web password${RESET}   ·   Port : ${BOLD}sudo wg-pi web port <numéro>${RESET}   ·   Désactiver : ${BOLD}sudo wg-pi web off${RESET}"
}

web_enable() {
  local port inst
  take_lock
  title "Interface web d'administration"
  ensure_packages python3 openssl || die "Impossible d'installer python3 et openssl."
  port=$(web_conf_get port)
  # Pas de port enregistré, ou port repris entre-temps par un autre programme : on en choisit un libre
  if [[ ! $port =~ ^[0-9]+$ ]] || { ! systemctl is-active --quiet "$WEB_UNIT" && tcp_port_in_use "$port"; }; then
    port=$(web_pick_port)
    web_conf_set port "$port"
  fi
  # Le service lance la commande installée : elle doit connaître « web-serve »
  inst=$(script_version "$BIN_PATH" 2>/dev/null)
  if [[ -z $inst ]] || version_lt "$inst" "$WGPI_VERSION"; then
    install_self || die "Impossible d'installer la commande wg-pi : lancez d'abord sudo wg-pi update."
  fi
  if [[ ! -s $WEB_DIR/cert.pem || ! -s $WEB_DIR/key.pem ]]; then
    run "Création du certificat HTTPS du Pi" web_make_cert || die "Impossible de créer le certificat HTTPS."
  fi
  if [[ -z $(web_conf_get password) ]]; then
    web_set_password || die "Le mot de passe n'a pas pu être enregistré."
  fi
  web_write_unit
  web_ufw allow "$port"
  if ! run "Démarrage de l'interface web (port $port)" web_start "$port"; then
    journalctl -u "$WEB_UNIT" -n 20 --no-pager >&2
    die "L'interface web ne démarre pas. Journal : journalctl -u $WEB_UNIT"
  fi
  web_conf_set enabled 1
  ok "Interface web active (elle redémarrera toute seule avec le Pi)"
  web_print_access "$port"
}

web_disable() {
  local port
  take_lock
  port=$(web_conf_get port)
  systemctl disable --now "$WEB_UNIT" >>"$LOG_FILE" 2>&1
  rm -f "$UNIT_DIR/$WEB_UNIT"
  systemctl daemon-reload
  [[ -n $port ]] && web_ufw delete "$port"
  web_conf_set enabled 0
  ok "Interface web désactivée (mot de passe et certificat conservés pour une prochaine activation)."
}

# web_set_port [port] : change le port du panneau ; en cas d'échec, revient à l'ancien
web_set_port() {
  local new=${1:-} old
  take_lock
  [[ -n $new ]] || ask new "Nouveau port de l'interface web (443 = adresse sans numéro de port)" "443"
  valid_port "$new" || die "Port invalide : un nombre entre 1 et 65535."
  new=$((10#$new))
  old=$(web_conf_get port)
  if [[ $new == "$old" ]]; then
    ok "L'interface web utilise déjà le port $new."
    return 0
  fi
  if tcp_port_in_use "$new"; then
    die "Le port $new est déjà utilisé par un autre programme sur le Pi (détail : sudo ss -ltnp 'sport = :$new')."
  fi
  web_conf_set port "$new"
  if [[ ! -f $UNIT_DIR/$WEB_UNIT ]]; then
    ok "Port $new enregistré : il sera utilisé à l'activation (sudo wg-pi web)."
    return 0
  fi
  [[ -n $old ]] && web_ufw delete "$old"
  web_ufw allow "$new"
  if ! run "Redémarrage de l'interface web sur le port $new" web_start "$new"; then
    web_ufw delete "$new"
    if [[ -n $old ]]; then
      web_conf_set port "$old"
      web_ufw allow "$old"
      web_start "$old"
    fi
    die "L'interface web ne démarre pas sur le port $new : retour au port ${old:-précédent}."
  fi
  ok "Interface web déplacée sur le port $new"
  web_print_access "$new"
}

cmd_web() {
  load_settings
  case ${1:-on} in
    on|activer)
      web_enable ;;
    off|desactiver)
      web_disable ;;
    port)
      web_set_port "${2:-}" ;;
    password|mot-de-passe)
      take_lock
      web_set_password || die "Le mot de passe n'a pas pu être enregistré."
      # Les sessions sont en mémoire : redémarrer le panneau déconnecte tout le monde
      systemctl try-restart "$WEB_UNIT" >/dev/null 2>&1
      ok "Mot de passe de l'interface web changé (les sessions ouvertes ont été fermées)." ;;
    *)
      die "Usage : sudo wg-pi web [on|off|password|port <numéro>]" ;;
  esac
}

# Lancé par le service : écrit l'application de la version installée puis la démarre
cmd_web_serve() {
  load_settings
  local port app dir=${RUNTIME_DIRECTORY:-/run/wg-pi-web}
  port=$(web_conf_get port)
  [[ $port =~ ^[0-9]+$ ]] || port=$WEB_DEFAULT_PORT
  # Certificat absent ou expirant dans moins de 30 jours : on le refait
  if ! openssl x509 -checkend 2592000 -noout -in "$WEB_DIR/cert.pem" >/dev/null 2>&1; then
    web_make_cert >/dev/null 2>&1 || echo "wg-pi : impossible de renouveler le certificat HTTPS" >&2
  fi
  install -d -m 700 "$dir"
  app="$dir/web.py"
  web_app_source >"$app"
  # env plutôt qu'une affectation devant exec : WGPI_VERSION est en lecture seule dans ce script
  exec env WGPI_WEB_PORT="$port" WGPI_BIN="$BIN_PATH" WGPI_VERSION="$WGPI_VERSION" WGPI_WEB_CONF="$WEB_CONF" \
    WGPI_WEB_DIR="$WEB_DIR" WGPI_CLIENTS="$CLIENTS_DIR" python3 -I "$app"
}

# État du serveur et des appareils en JSON (lu par l'interface web). Les champs sont sûrs :
# noms validés, adresses IP, clés et compteurs ; aucun échappement JSON n'est nécessaire.
cmd_json() {
  load_settings
  local -A hs=() rx=() tx=() ep=()
  local pub _psk endpoint _allowed latest r t _ka name ip state mode ip6 enabled net6="" first=1 running=false
  if wg show "$WG_IF" >/dev/null 2>&1; then
    while IFS=$'\t' read -r pub _psk endpoint _allowed latest r t _ka; do
      hs["$pub"]=$latest rx["$pub"]=$r tx["$pub"]=$t ep["$pub"]=$endpoint
    done < <(wg show "$WG_IF" dump | tail -n +2)
  fi
  wg_running && running=true
  (( IPV6_ON )) && net6="${WG_NET6}/64"
  printf '{"version":"%s","running":%s,"endpoint":"%s","port":%s,"net":"%s","net6":"%s","dns":"%s","keepalive":%s,' \
    "$WGPI_VERSION" "$running" "$(endpoint_str)" "$WG_PORT" "$WG_NET4.0/24" "$net6" "$CLIENT_DNS" "$KEEPALIVE"
  printf '"pubkey":"%s","lan_ip":"%s","lan_net":"%s","default_route":"%s","now":%s,"peers":[' \
    "$SERVER_PUBKEY" "$LAN_IP" "$LAN_NET" "$DEFAULT_ROUTE" "$(date +%s)"
  while read -r name ip pub state; do
    mode="split"
    grep -q '^AllowedIPs = 0\.0\.0\.0/0' "$CLIENTS_DIR/$name.conf" 2>/dev/null && mode="full"
    ip6=""
    (( IPV6_ON )) && ip6="${WG_NET6}${ip##*.}"
    enabled=true
    [[ $state == off ]] && enabled=false
    (( first )) || printf ','
    first=0
    printf '{"name":"%s","ip":"%s","ip6":"%s","pub":"%s","enabled":%s,"mode":"%s","handshake":%s,"rx":%s,"tx":%s,"endpoint":"%s"}' \
      "$name" "$ip" "$ip6" "$pub" "$enabled" "$mode" "${hs["$pub"]:-0}" "${rx["$pub"]:-0}" "${tx["$pub"]:-0}" "${ep["$pub"]:-}"
  done < <(peers_table)
  printf ']}\n'
}

# Application web (Python 3, bibliothèque standard uniquement)
web_app_source() {
  cat <<'PYEOF'
#!/usr/bin/env python3
# Interface web de wg-pi, écrite et lancée par « wg-pi web-serve » (service wg-pi-web).
# Bibliothèque standard uniquement. Toutes les modifications passent par la commande wg-pi :
# le terminal et le navigateur voient donc toujours les mêmes appareils.
import hashlib
import hmac
import html
import http.server
import ipaddress
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

VERSION = os.environ.get("WGPI_VERSION", "?")
PORT = int(os.environ.get("WGPI_WEB_PORT", "51821"))
WGPI = os.environ.get("WGPI_BIN", "/usr/local/sbin/wg-pi")
CONF = os.environ.get("WGPI_WEB_CONF", "/etc/wg-pi/web.conf")
WEB_DIR = os.environ.get("WGPI_WEB_DIR", "/etc/wg-pi/web")
CLIENTS = os.environ.get("WGPI_CLIENTS", "/etc/wg-pi/clients")
WG_IF = os.environ.get("WGPI_WG_IF", "wg0")
COOKIE = "wgpi_session"
SESSION_TTL = 12 * 3600
MAX_FAILS = 5
BLOCK_SECONDS = 300
CACHE_SECONDS = 30
NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,15}")
NEW_NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{0,14}")  # pas de « - » en tête (pris pour une option)
# Seuls le réseau local, le VPN et la machine elle-même peuvent joindre le panneau
ALLOWED_NETS = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10")]
CSP = ("default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'self'; "
       "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")

sessions = {}   # jeton -> {"expires": horodatage, "csrf": jeton anti-CSRF}
failures = {}   # ip -> (échecs, bloqué jusqu'à)
lock = threading.Lock()
login_lock = threading.Lock()   # une vérification de mot de passe à la fois (limite le débit des essais)
cache = {"time": 0.0, "data": None}   # dernier « wg-pi json » (appareils, réglages)
cache_lock = threading.Lock()
esc = html.escape


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def read_conf():
    conf = {}
    try:
        with open(CONF, encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep:
                    conf[key] = value
    except OSError:
        pass
    return conf


def check_password(password):
    try:
        algo, rounds, salt, digest = read_conf().get("password", "").split("$")
        if algo != "pbkdf2_sha256":
            return False
        calc = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), int(rounds)).hex()
        return hmac.compare_digest(calc.encode(), digest.encode())
    except ValueError:
        return False


def same(a, b):
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def run_wgpi(*args, timeout=90):
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}
    try:
        return subprocess.run([WGPI, *args], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 1, "", "wg-pi ne répond pas (délai dépassé).")


def clean_message(text):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text or "")
    lines = [line.strip().lstrip("✖⚠✔➜").strip() for line in text.splitlines() if line.strip()]
    return " ".join(lines)[:400] or "Erreur inconnue."


def load_base(force=False):
    """Appareils et réglages (« wg-pi json »), relus toutes les 30 s ou après une modification."""
    with cache_lock:
        if force or cache["data"] is None or time.time() - cache["time"] > CACHE_SECONDS:
            r = run_wgpi("json", timeout=30)
            if r.returncode != 0:
                raise RuntimeError(clean_message(r.stderr or r.stdout))
            cache["data"] = json.loads(r.stdout)
            cache["time"] = time.time()
        return cache["data"]


def invalidate():
    with cache_lock:
        cache["data"] = None


def wg_live():
    """Compteurs en direct (rapide, appelé à chaque rafraîchissement) : clé publique -> état."""
    try:
        r = subprocess.run(["wg", "show", WG_IF, "dump"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    live = {}
    for line in r.stdout.splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 7:
            try:
                live[f[0]] = (f[2], int(f[4]), int(f[5]), int(f[6]))
            except ValueError:
                pass
    return live


def get_state():
    base = load_base()
    live = wg_live()
    now = int(time.time())
    peers, online = [], 0
    for p in base.get("peers", []):
        endpoint, hs, rx, tx = (live or {}).get(p.get("pub"), ("", 0, 0, 0))
        enabled = bool(p.get("enabled", True))
        age = now - hs if hs else None
        connected = enabled and age is not None and age < 180
        online += 1 if connected else 0
        peers.append({"name": p.get("name", ""), "ip": p.get("ip", ""), "ip6": p.get("ip6", ""),
                      "mode": p.get("mode", "full"), "enabled": enabled, "connected": connected,
                      "age": age, "rx": rx, "tx": tx,
                      "endpoint": "" if endpoint in ("", "(none)") else endpoint})
    server = {k: base.get(k, "") for k in ("version", "endpoint", "port", "net", "net6", "dns",
                                            "keepalive", "pubkey", "lan_net", "default_route")}
    server.update({"running": live is not None, "online": online, "total": len(peers)})
    return {"server": server, "peers": peers, "time": time.time()}


def client_conf_path(name):
    if not NAME_RE.fullmatch(name or ""):
        return None
    path = os.path.join(CLIENTS, name + ".conf")
    return path if os.path.isfile(path) else None


def qr_png(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        r = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-m", "2", "-o", "-"], input=data,
                           capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return b""
    return r.stdout if r.returncode == 0 else b""


# Emblème officiel de WireGuard (tracés repris tels quels de https://www.wireguard.com/img/wireguard.svg).
# Le dragon est une découpe : un disque blanc derrière le garde blanc sur fond sombre, sans toucher au logo.
# « WireGuard » et le logo « WireGuard » sont des marques déposées de Jason A. Donenfeld.
WG_PATHS = (
    "m301.28 145.56s6.9396-145.56-153.04-145.56c-141.48 0-145.9 139.63-145.9 139.63s-20.811 160.37 149.16 160.37c163.02 0 149.78-154.44 149.78-154.44zm-197.8-50.863c30.017-18.364 68.366-7.1401 82.735 20.476 2.7233 5.2338 3.0694 13.291 1.3447 18.782-5.9546 18.956-20.014 29.587-39.312 34.103 5.6892-4.8707 10.218-10.394 11.659-18.025a26.402 26.402 0 0 0-4.5425-20.956 26.76 26.76 0 0 0-30.811-9.3892c-11.881 4.5111-18.389 15.354-17.216 28.683 1.0898 12.381 10.484 20.405 28.061 23.453-2.627 1.3904-4.6503 2.4144-6.6299 3.5172a63.918 63.918 0 0 0-20.544 17.868c-1.7839 2.4084-3.0104 2.6024-5.727 0.94116-35.338-21.61-37.609-75.844 0.98226-99.453zm-26.449 133.53c-5.6769 1.441-11.178 3.5742-16.981 5.4775 2.8385-19.151 25.265-36.788 44.23-34.776a48.881 48.881 0 0 0-9.242 25.893c-6.302 1.1606-12.241 1.9414-18.007 3.405zm120.79-186.98c5.6099 0.20612 11.23 0.12091 16.844 0.25378a29.052 29.052 0 0 1 4.1674 0.58069 40.607 40.607 0 0 1-4.2357 5.4332c-2.007 1.8701-4.2745 3.6986-7.1661 0.856-0.6955-0.68372-2.3386-0.52679-3.5487-0.54272-5.5823-0.07336-11.172-0.25177-16.746-0.04132a104.04 104.04 0 0 0-14.425 1.473c-0.89368 0.16046-2.2299 3.1315-1.8191 4.227 0.9693 2.5853 2.3833 5.4363 4.4779 7.0898 7.7403 6.11 15.972 11.596 23.748 17.664 7.556 5.8966 14.589 12.358 18.875 21.253 5.5843 11.59 5.747 23.743 3.3388 35.95-4.0203 20.378-14.333 37.261-31.032 49.524-6.7288 4.941-15.06 7.7451-22.767 11.295-6.778 3.1225-13.755 5.8115-20.549 8.9008-12.249 5.5695-19.133 18.865-17.108 32.688 1.8585 12.685 12.987 23.271 25.735 25.456 15.292 2.6216 31.071-7.3163 34.812-22.86 4.2067-17.478-5.2898-33.083-23.065-37.813-0.78271-0.20831-1.5684-0.40552-3.2012-0.8269 4.7549-2.1245 8.8614-3.6381 12.653-5.7244q9.9213-5.4594 19.481-11.562c1.8742-1.199 2.8868-1.1996 4.4852 0.18225 12.225 10.57 19.518 23.718 21.563 39.839 3.3845 26.684-9.2471 51.198-33.072 63.762-36.86 19.439-81.965-2.6864-90.106-43.552-6.9738-35.003 17.73-66.754 47.462-72.884 12.787-2.6364 24.48-7.9596 33.57-17.807 5.8652-6.3541 8.7084-11.806 9.6772-14.266a39.565 39.565 0 0 0 2.7211-14.469 33.867 33.867 0 0 0-2.9654-12.398c-3.104-7.075-14.995-18.33-17.939-20.704l-28-21.921c-0.98761-0.81256-2.0994-0.75366-4.5079-0.59045-2.8611 0.19391-10.175 0.59888-13.331-0.22815 2.553-1.9321 9.5132-4.7451 12.502-7.007-9.0734-6.1297-19.43-3.9158-28.941-5.7461 2.1992-4.0959 13.081-10.39 19.27-11.091a91.533 91.533 0 0 0-1.6876-10.281c-0.37781-1.3917-1.9312-2.7408-3.2864-3.5355-3.286-1.9267-6.7694-3.5167-10.549-5.4327a21.936 21.936 0 0 1 11.332-3.5055 42.316 42.316 0 0 1 11.348 1.1056c6.7422 1.5405 12.124 0.53491 17.488-4.048-4.222-1.7002-8.4435-3.2535-12.538-5.0907a123.04 123.04 0 0 1-11.779-6.1583c10.622 1.4755 20.896 5.4585 31.757 4.0034q0.1387-0.74048 0.27728-1.4809c-8.1194-1.8899-16.239-3.7798-25.229-5.8724 15.04-1.3769 29.042-1.604 42.301 4.8541 3.731 1.8173 7.6348 3.3215 11.211 5.3972 1.7443 1.0124 2.9186 3.0078 4.3496 4.5594 1.1366 1.2325 2.0495 2.8837 3.446 3.6264 5.3 2.8184 11.134 2.9291 17.078 2.7879 0.04443-0.67694 0.08606-1.3114 0.1308-1.9933 5.9821 1.8693 12.715 8.7679 12.704 13.806-9.6911 0-19.374-0.037-29.056 0.05389-1.0348 0.0097-2.0626 0.76563-3.0936 1.1754 0.97986 0.57067 1.9428 1.5994 2.9423 1.6362z",
    "m185.32 26.906a1.4806 1.4806 0 0 0-0.18927 2.3686 2.2326 2.2326 0 0 0 3.0724 0.8219c0.9328-0.47052 1.8478-0.97137 2.975-1.5665-0.9079-0.775-1.6362-1.4148-2.3857-2.0324-1.318-1.086-2.411-0.40386-3.4724 0.40833z",
)
LOGO = ('<svg class="logo" viewBox="-2 -2 305 304" aria-hidden="true"><circle cx="150" cy="150" r="146" fill="#fff"/>'
        + "".join(f'<path fill="#88171a" transform="translate(-1.5394)" d="{d}"/>' for d in WG_PATHS) + '</svg>')
FAVICON = "data:image/svg+xml," + urllib.parse.quote(LOGO.replace('class="logo" ', 'xmlns="http://www.w3.org/2000/svg" '))
TRADEMARK = ('« WireGuard » et le logo « WireGuard » sont des marques déposées de Jason A. Donenfeld · '
             '<a href="https://www.wireguard.com/" target="_blank" rel="noopener noreferrer">wireguard.com</a>')

DARK = ("--bg:#0d0f12;--card:#16191e;--soft:#1d2127;--text:#e7e9ec;--muted:#98a2b3;--line:#282d35;"
        "--accent:#e5484d;--accent-2:#f05b60;--ok:#3ccb7f;--ok-soft:#10291c;--bad:#f97066;--bad-soft:#2c1412;"
        "--shadow:none")
CSS = """
:root{--bg:#f3f4f6;--card:#fff;--soft:#f7f8fa;--text:#14171a;--muted:#667085;--line:#e5e7eb;
--accent:#88171a;--accent-2:#6f1215;--on-accent:#fff;--ok:#12a150;--ok-soft:#e8f7ee;--bad:#d92d20;--bad-soft:#fdeeec;
--shadow:0 1px 2px rgba(16,24,40,.05),0 2px 8px rgba(16,24,40,.06);--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
:root[data-theme=dark]{%DARK%}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){%DARK%}}
*{box-sizing:border-box}[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;
-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
.wrap{max-width:1040px;margin:0 auto;padding:0 18px}
.mono{font-family:var(--mono);font-size:12.5px}
.top{position:sticky;top:0;z-index:5;background:var(--card);border-bottom:1px solid var(--line)}
@supports (backdrop-filter:blur(1px)){.top{background:color-mix(in srgb,var(--card) 82%,transparent);backdrop-filter:saturate(1.4) blur(10px)}}
.bar{display:flex;align-items:center;justify-content:space-between;height:56px}
.brand{display:flex;align-items:center;gap:10px;color:inherit;text-decoration:none}
.brand b{font-size:17px;letter-spacing:-.01em}.brand small{color:var(--muted);font-size:12.5px}
.logo{width:32px;height:32px;flex:none}
.tm{color:var(--muted);font-size:11.5px;text-align:center;margin-top:2px}.tm a{color:inherit}
.tools{display:flex;align-items:center;gap:8px}
.ico{display:inline-flex}
.ico svg,.icon-btn svg,.btn svg,.search svg,.step h4 svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;
stroke-linecap:round;stroke-linejoin:round;flex:none}
svg .f{fill:currentColor;stroke:none}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;height:36px;padding:0 14px;border-radius:10px;
border:1px solid var(--line);background:var(--card);color:var(--text);font:inherit;font-weight:600;cursor:pointer;
text-decoration:none;white-space:nowrap;transition:background .15s,border-color .15s}
.btn:hover{background:var(--soft)}.btn:active{transform:translateY(1px)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--on-accent)}.btn.primary:hover{background:var(--accent-2)}
.btn.danger{background:var(--bad);border-color:var(--bad);color:#fff}
.btn.ghost{background:transparent}.btn.block{width:100%}.btn[disabled]{opacity:.6;cursor:default}
.icon-btn{display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;padding:0;border-radius:9px;
border:1px solid var(--line);background:var(--card);color:var(--text);cursor:pointer;text-decoration:none;
transition:background .15s,color .15s,border-color .15s}
.icon-btn:hover{background:var(--soft)}.icon-btn.danger:hover{color:var(--bad);border-color:var(--bad)}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow)}
main{padding-top:16px;padding-bottom:4px}
.alert{margin-bottom:12px;padding:10px 14px;border-radius:12px;background:var(--bad-soft);color:var(--bad);font-weight:600}
.server{padding:12px 16px;margin-bottom:14px}
.srv-main{display:flex;flex-wrap:wrap;align-items:center;gap:10px 28px}
.pill{display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:999px;font-weight:700;font-size:13px}
.pill::before{content:"";width:8px;height:8px;border-radius:50%;background:currentColor}
.pill.ok{background:var(--ok-soft);color:var(--ok)}.pill.bad{background:var(--bad-soft);color:var(--bad)}
.kv{display:flex;flex-direction:column;min-width:0}.kv>span{color:var(--muted);font-size:12px}.kv b{font-weight:600;overflow-wrap:anywhere}
.push{margin-left:auto}
.srv-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px 24px;margin-top:12px;
padding-top:12px;border-top:1px dashed var(--line)}
.srv-details .wide{grid-column:1/-1}.key{display:flex;align-items:center;gap:8px}
#srv-toggle[aria-expanded=true] .ico{transform:rotate(180deg)}
.clients{overflow:hidden}
.clients-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;padding:12px 16px;
border-bottom:1px solid var(--line)}
.clients-head h2{margin:0;font-size:17px;display:flex;align-items:center;gap:8px}
.count{font-size:12px;font-weight:700;color:var(--muted);background:var(--soft);border:1px solid var(--line);border-radius:999px;padding:0 8px}
.clients-tools{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.search{display:flex;align-items:center;gap:6px;height:36px;padding:0 10px;border:1px solid var(--line);border-radius:10px;
background:var(--soft);color:var(--muted)}
.search input{border:none;background:transparent;color:var(--text);font:inherit;width:170px;outline:none}
select{height:36px;padding:0 8px;border:1px solid var(--line);border-radius:10px;background:var(--soft);color:var(--text);font:inherit}
.row{position:relative;display:grid;grid-template-columns:42px minmax(0,1fr) 200px auto;align-items:center;gap:14px;
padding:11px 16px;border-bottom:1px solid var(--line);overflow:hidden}
.row:last-child{border-bottom:none}.row:hover{background:var(--soft)}
.spark{position:absolute;left:0;bottom:0;width:100%;height:100%;pointer-events:none}
.spark path{fill:var(--accent);opacity:.1}
.row>:not(.spark){position:relative}
.avatar{width:42px;height:42px;border-radius:50%;display:grid;place-items:center;color:#fff;font-weight:700;font-size:15px}
.avatar .dot{position:absolute;right:-1px;bottom:-1px;width:13px;height:13px;border-radius:50%;background:var(--muted);
border:2px solid var(--card)}
.row.online .avatar .dot{background:var(--ok);animation:pulse 2s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(18,161,80,.55)}70%{box-shadow:0 0 0 7px rgba(18,161,80,0)}100%{box-shadow:0 0 0 0 rgba(18,161,80,0)}}
.row.disabled .avatar{filter:grayscale(1);opacity:.45}.row.disabled .name{color:var(--muted)}
.l1{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px}
.name{font-weight:700;font-size:15px}
.badge{font-size:11.5px;font-weight:600;padding:0 8px;border-radius:999px;background:var(--soft);border:1px solid var(--line);color:var(--muted)}
.badge.off{background:var(--bad-soft);border-color:transparent;color:var(--bad)}
.ips{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.status{font-size:12.5px;color:var(--muted)}.status.on{color:var(--ok);font-weight:600}
.traffic{text-align:right;min-width:0}.traffic[hidden]{display:block!important;visibility:hidden}
.rates{font-weight:700;font-variant-numeric:tabular-nums;white-space:nowrap}
.totals{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.actions{display:flex;align-items:center;gap:6px}
.switch{position:relative;display:inline-block;width:38px;height:22px;margin-right:4px;flex:none}
.switch input{position:absolute;inset:0;opacity:0;margin:0;cursor:pointer;z-index:1}
.slider{position:absolute;inset:0;border-radius:999px;background:var(--line);transition:background .2s}
.slider::after{content:"";position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:50%;background:#fff;
box-shadow:0 1px 2px rgba(0,0,0,.3);transition:transform .2s}
.switch input:checked+.slider{background:var(--ok)}.switch input:checked+.slider::after{transform:translateX(16px)}
.switch input:focus-visible+.slider{outline:2px solid var(--accent);outline-offset:2px}
.switch input:disabled+.slider{opacity:.6}
.empty{padding:30px 16px;text-align:center;color:var(--muted)}.empty .btn{margin-top:10px}
footer{color:var(--muted);font-size:12.5px;text-align:center;padding:12px 16px 16px}
dialog{border:none;border-radius:18px;padding:0;width:min(580px,calc(100vw - 24px));max-height:calc(100vh - 24px);
background:var(--card);color:var(--text);box-shadow:0 24px 64px rgba(0,0,0,.35)}
dialog::backdrop{background:rgba(10,12,16,.55)}
.dlg{padding:16px 20px 20px}
.dlg-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:12px}
.dlg-head h3{margin:0;font-size:18px;overflow-wrap:anywhere}
.dlg-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.note{padding:9px 12px;border-radius:10px;font-weight:600;margin-bottom:12px}
.note.ok{background:var(--ok-soft);color:var(--ok)}.note.bad{background:var(--bad-soft);color:var(--bad)}
.qr-wrap{display:grid;grid-template-columns:auto 1fr;gap:20px;align-items:start}
.qr{display:block;width:220px;height:220px;image-rendering:pixelated;background:#fff;border-radius:12px;padding:4px;border:1px solid var(--line)}
.steps{display:flex;flex-direction:column;gap:12px}
.step h4{display:flex;align-items:center;gap:8px;margin:0 0 4px;font-size:14px}
.step ol{margin:0 0 8px;padding-left:20px;color:var(--muted)}
.hint{color:var(--muted);font-size:12.5px;margin:10px 0 0}
.field{display:block;font-weight:600;margin:0 0 6px}
input[type=text],input[type=password]{width:100%;height:40px;padding:0 12px;border:1px solid var(--line);border-radius:10px;
background:var(--soft);color:var(--text);font:inherit}
input[type=text]:focus,input[type=password]:focus,select:focus,.search:focus-within{outline:2px solid var(--accent);outline-offset:1px}
.form .hint{margin:6px 0 14px}
.choices{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.choice{display:flex;gap:10px;align-items:flex-start;padding:11px 12px;border:1px solid var(--line);border-radius:12px;cursor:pointer}
.choice.on{border-color:var(--accent);background:var(--soft)}
.choice input{margin-top:3px;accent-color:var(--accent)}
.choice-text{display:flex;flex-direction:column}.choice-text span{color:var(--muted);font-size:12.5px}
code{font-family:var(--mono);font-size:12px;background:var(--soft);border:1px solid var(--line);border-radius:6px;padding:1px 5px}
.login{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px 16px}
.login-card{width:min(380px,100%);padding:26px 24px}
.login-logo{display:flex;align-items:center;gap:12px;margin-bottom:20px}.login-logo .logo{width:42px;height:42px}
.login-logo b{display:block;font-size:20px}.login-logo span{color:var(--muted);font-size:13px}
.login .btn{margin-top:14px;height:42px}
.login .foot{color:var(--muted);font-size:12.5px;margin-top:16px;text-align:center}
.toast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:50;max-width:calc(100vw - 32px);padding:10px 16px;
border-radius:12px;background:#111827;color:#fff;font-weight:600;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.toast.bad{background:var(--bad)}
@media (max-width:760px){
.row{grid-template-columns:42px minmax(0,1fr);gap:8px 12px}
.traffic{grid-column:2;text-align:left;min-width:0}.traffic[hidden]{display:none!important}
.actions{grid-column:1/-1;justify-content:flex-end}
.search input{width:110px}.brand small,.hide-sm{display:none}
.qr-wrap{grid-template-columns:1fr;justify-items:center}.choices{grid-template-columns:1fr}
}
""".replace("%DARK%", DARK)

THEME_JS = r"""
try { var t = localStorage.getItem("wgpi-theme"); if (t === "light" || t === "dark") { document.documentElement.setAttribute("data-theme", t); } } catch (e) {}
"""

APP_JS = r"""
"use strict";
(function () {
  var ICONS = {
    plus: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
    qr: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><path class="f" d="M14 14h2.5v2.5H14zM17.5 17.5H20V20h-2.5zM14 18h2v2h-2zM18 14h2v2h-2z"/></svg>',
    edit: '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4z"/><path d="m13.5 6.5 4 4"/></svg>',
    download: '<svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/></svg>',
    trash: '<svg viewBox="0 0 24 24"><path d="M4 7h16"/><path d="M10 11v6M14 11v6"/><path d="M6 7l1 13h10l1-13"/><path d="M9 7V4h6v3"/></svg>',
    logout: '<svg viewBox="0 0 24 24"><path d="M14 4h5v16h-5"/><path d="m10 8-4 4 4 4"/><path d="M6 12h10"/></svg>',
    sun: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
    moon: '<svg viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/></svg>',
    auto: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path class="f" d="M12 4a8 8 0 0 1 0 16z"/></svg>',
    chevron: '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>',
    copy: '<svg viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/></svg>',
    close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    phone: '<svg viewBox="0 0 24 24"><rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 17h2"/></svg>',
    laptop: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 19h20"/></svg>'
  };
  var root = document.documentElement;
  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) { e.className = cls; } if (text != null) { e.textContent = text; } return e; }

  /* Icônes et thème (aussi sur la page de connexion) */
  document.querySelectorAll("[data-icon]").forEach(function (e) { e.insertAdjacentHTML("afterbegin", ICONS[e.getAttribute("data-icon")] || ""); });
  var THEMES = ["auto", "light", "dark"], THEME_NAMES = {auto: "automatique", light: "clair", dark: "sombre"};
  function getTheme() { try { return localStorage.getItem("wgpi-theme") || "auto"; } catch (e) { return "auto"; } }
  function applyTheme(t) {
    if (t === "auto") { root.removeAttribute("data-theme"); } else { root.setAttribute("data-theme", t); }
    var b = $("theme");
    if (b) { b.innerHTML = ICONS[t === "auto" ? "auto" : (t === "light" ? "sun" : "moon")]; b.title = "Thème : " + THEME_NAMES[t]; }
  }
  applyTheme(getTheme());
  if ($("theme")) {
    $("theme").addEventListener("click", function () {
      var t = THEMES[(THEMES.indexOf(getTheme()) + 1) % THEMES.length];
      try { localStorage.setItem("wgpi-theme", t); } catch (e) {}
      applyTheme(t);
    });
  }
  if (!$("list")) { return; }   /* page de connexion : rien d'autre à faire */

  var csrf = (document.querySelector('meta[name="csrf"]') || {}).content || "";
  /* Object.create(null) : un appareil nommé « constructor » ou « __proto__ » ne doit rien casser */
  var state = null, rows = Object.create(null), history = Object.create(null), query = "", sortKey = "name", toastTimer = null;
  var inflight = false, again = false;
  var nf = new Intl.NumberFormat("fr-FR", {maximumFractionDigits: 1});
  var NBSP = " ";

  function bytes(n) {
    var u = ["o", "Ko", "Mo", "Go", "To"], i = 0;
    n = Number(n) || 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i ? nf.format(n) : String(Math.round(n))) + NBSP + u[i];
  }
  function rate(n) { return bytes(n) + "/s"; }
  function ago(s) {
    if (s < 60) { return "il y a " + s + " s"; }
    if (s < 3600) { return "il y a " + Math.floor(s / 60) + " min"; }
    if (s < 86400) { return "il y a " + Math.floor(s / 3600) + " h"; }
    return "il y a " + Math.floor(s / 86400) + " j";
  }
  function hostOf(ep) { var m = /^\[(.*)\]:\d+$/.exec(ep) || /^(.*):\d+$/.exec(ep); return m ? m[1] : ep; }
  function initials(name) {
    var parts = name.split(/[^A-Za-z0-9]+/).filter(Boolean);
    var s = parts.length > 1 ? parts[0][0] + parts[1][0] : (parts[0] || name).slice(0, 2);
    return s.toUpperCase();
  }
  function color(name) {
    var h = 0;
    for (var i = 0; i < name.length; i++) { h = (h * 31 + name.charCodeAt(i)) % 360; }
    return "hsl(" + h + " 52% 46%)";
  }
  function iconBtn(name, title, cls) {
    var b = el("button", "icon-btn" + (cls ? " " + cls : ""));
    b.type = "button"; b.title = title; b.setAttribute("aria-label", title); b.innerHTML = ICONS[name];
    return b;
  }
  function svgEl(tag, attrs) {
    var e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    Object.keys(attrs).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    return e;
  }
  function toast(msg, bad) {
    var t = $("toast");
    t.textContent = msg; t.className = "toast" + (bad ? " bad" : ""); t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, 3500);
  }
  function api(method, url, body) {
    var opts = {method: method, credentials: "same-origin", cache: "no-store", headers: {"X-CSRF-Token": csrf}};
    if (body) { opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(body); }
    return fetch(url, opts).then(function (r) {
      if (r.status === 401) { window.location.href = "/login"; throw new Error("session"); }
      return r.json().catch(function () { return {}; }).then(function (d) {
        if (!r.ok) { throw new Error(d.error || ("Erreur " + r.status)); }
        return d;
      });
    });
  }
  function peerUrl(name, suffix) { return "/api/peers/" + encodeURIComponent(name) + "/" + suffix; }

  /* ---- Rafraîchissement ---- */
  /* Une seule requête à la fois ; une demande arrivée entre-temps est rejouée ensuite */
  function poll() {
    if (document.hidden) { return; }
    if (inflight) { again = true; return; }
    inflight = true;
    api("GET", "/api/state").then(function (d) {
      $("alert").hidden = true;
      if (!state || d.time > state.time) { update(d); }
    }).catch(function (e) {
      if (e.message === "session") { return; }
      $("alert").textContent = "Impossible de joindre le Pi : " + e.message;
      $("alert").hidden = false;
    }).then(function () {
      inflight = false;
      if (again) { again = false; poll(); }
    });
  }
  function update(d) {
    d.peers.forEach(function (p) {
      var h = history[p.name] || (history[p.name] = {samples: []});
      if (h.t != null && d.time - h.t < 1) {   /* deux mesures trop proches : on garde le débit précédent */
        p.down = h.down || 0; p.up = h.up || 0;
        return;
      }
      var down = 0, up = 0;
      if (h.t != null) {
        /* vu depuis l'appareil : il reçoit ce que le serveur envoie (tx) et envoie ce que le serveur reçoit (rx) */
        down = Math.max(0, (p.tx - h.tx) / (d.time - h.t));
        up = Math.max(0, (p.rx - h.rx) / (d.time - h.t));
      }
      h.t = d.time; h.rx = p.rx; h.tx = p.tx; h.down = down; h.up = up;
      h.samples.push(down + up);
      if (h.samples.length > 40) { h.samples.shift(); }
      p.down = down; p.up = up;
    });
    state = d;
    renderServer();
    renderList();
  }

  /* ---- Serveur ---- */
  function renderServer() {
    var s = state.server;
    var pill = $("srv-state");
    pill.textContent = s.running ? "Serveur actif" : "Serveur arrêté";
    pill.className = "pill " + (s.running ? "ok" : "bad");
    $("srv-endpoint").textContent = s.endpoint;
    $("srv-net").textContent = s.net;
    $("srv-online").textContent = s.online + " / " + s.total;
    $("d-pubkey").textContent = s.pubkey || "—";
    $("d-port").textContent = s.port + " (UDP)";
    $("d-net6").textContent = s.net6 || "désactivé";
    $("d-dns").textContent = s.dns || "—";
    $("d-keepalive").textContent = s.keepalive + " s";
    $("d-lan").textContent = s.lan_net || "—";
    $("d-mode").textContent = s.default_route === "split" ? "Réseau de la maison" : "Tout le trafic";
    $("d-version").textContent = "wg-pi " + s.version;
  }

  /* ---- Appareils ---- */
  function makeRow(name) {
    var r = {name: name, el: el("div", "row")};
    r.spark = svgEl("svg", {"class": "spark", viewBox: "0 0 100 30", preserveAspectRatio: "none", "aria-hidden": "true"});
    r.area = svgEl("path", {d: ""});
    r.spark.appendChild(r.area);
    r.avatar = el("div", "avatar");
    r.ini = el("span");
    r.avatar.append(r.ini, el("span", "dot"));
    var info = el("div", "info"), l1 = el("div", "l1");
    r.nameEl = el("span", "name"); r.mode = el("span", "badge"); r.off = el("span", "badge off", "Désactivé");
    l1.append(r.nameEl, r.mode, r.off);
    r.ips = el("div", "ips mono"); r.status = el("div", "status");
    info.append(l1, r.ips, r.status);
    r.traffic = el("div", "traffic"); r.rates = el("div", "rates"); r.totals = el("div", "totals");
    r.traffic.append(r.rates, r.totals);
    var act = el("div", "actions"), sw = el("label", "switch");
    r.toggle = el("input"); r.toggle.type = "checkbox";
    sw.append(r.toggle, el("span", "slider"));
    r.qr = iconBtn("qr", "QR code"); r.ren = iconBtn("edit", "Renommer");
    r.dl = el("a", "icon-btn"); r.dl.innerHTML = ICONS.download;
    r.dl.title = "Télécharger le fichier .conf"; r.dl.setAttribute("aria-label", r.dl.title);
    r.del = iconBtn("trash", "Supprimer", "danger");
    act.append(sw, r.qr, r.ren, r.dl, r.del);
    r.el.append(r.spark, r.avatar, info, r.traffic, act);
    r.toggle.addEventListener("change", function () { setEnabled(r, r.toggle.checked); });
    r.qr.addEventListener("click", function () { openQR(r.name, false); });
    r.ren.addEventListener("click", function () { openRename(r.name); });
    r.del.addEventListener("click", function () { openDelete(r.name); });
    return r;
  }
  function fillRow(r, p) {
    r.nameEl.textContent = p.name;
    r.ini.textContent = initials(p.name);
    r.avatar.style.background = color(p.name);
    r.el.classList.toggle("disabled", !p.enabled);
    r.el.classList.toggle("online", p.connected);
    r.mode.textContent = p.mode === "full" ? "Tout le trafic" : "Réseau maison";
    r.mode.title = p.mode === "full" ? "Tout le trafic de l'appareil passe par la maison" : "Seul l'accès au réseau de la maison passe par le VPN";
    r.off.hidden = p.enabled;
    r.ips.textContent = p.ip + (p.ip6 ? "  ·  " + p.ip6 : "");
    var st;
    if (!p.enabled) { st = "Accès coupé : l'appareil ne peut plus se connecter"; }
    else if (p.connected) { st = "Connecté" + (p.endpoint ? " depuis " + hostOf(p.endpoint) : ""); }
    else if (p.age != null) { st = "Vu " + ago(p.age); }
    else { st = "Jamais connecté"; }
    r.status.textContent = st;
    r.status.className = "status" + (p.connected ? " on" : "");
    r.rates.textContent = (p.connected || p.down || p.up) ? "↓ " + rate(p.down) + "   ↑ " + rate(p.up) : "";
    r.totals.textContent = (p.rx || p.tx) ? "Total ↓ " + bytes(p.tx) + " · ↑ " + bytes(p.rx) : "";
    r.totals.title = "Reçu (↓) et envoyé (↑) par l'appareil depuis le démarrage du VPN";
    r.traffic.hidden = !r.rates.textContent && !r.totals.textContent;
    if (!r.busy) { r.toggle.checked = p.enabled; }
    r.toggle.title = p.enabled ? "Accès autorisé : cliquez pour le couper" : "Accès coupé : cliquez pour le rétablir";
    r.toggle.setAttribute("aria-label", r.toggle.title);
    r.dl.href = "/device/" + encodeURIComponent(p.name) + "/conf";
    r.dl.setAttribute("download", p.name + ".conf");
    drawSpark(r, (history[p.name] || {samples: []}).samples);
  }
  function drawSpark(r, s) {
    var max = Math.max.apply(null, s.concat([0]));
    if (max < 2048) { r.area.setAttribute("d", ""); return; }
    var n = 40, off = n - s.length, d = "M0,30";
    for (var i = 0; i < s.length; i++) {
      d += " L" + ((off + i) * 100 / (n - 1)).toFixed(1) + "," + (30 - s[i] / max * 26).toFixed(1);
    }
    r.area.setAttribute("d", d + " L100,30 Z");
  }
  function compare(a, b) {
    if (sortKey === "seen") {
      var ka = a.connected ? -1 : (a.age == null ? 1e12 : a.age), kb = b.connected ? -1 : (b.age == null ? 1e12 : b.age);
      if (ka !== kb) { return ka - kb; }
    } else if (sortKey === "traffic") {
      var ta = a.rx + a.tx, tb = b.rx + b.tx;
      if (ta !== tb) { return tb - ta; }
    }
    return a.name.localeCompare(b.name, "fr");
  }
  function renderList() {
    var list = $("list"), q = query.trim().toLowerCase();
    var peers = state.peers.filter(function (p) { return !q || (p.name + " " + p.ip + " " + p.ip6).toLowerCase().indexOf(q) >= 0; });
    peers.sort(compare);
    var names = Object.create(null), wanted = [];
    peers.forEach(function (p) {
      var r = rows[p.name] || (rows[p.name] = makeRow(p.name));
      fillRow(r, p);
      names[p.name] = true;
      wanted.push(r.el);
    });
    Object.keys(rows).forEach(function (n) {
      if (!names[n]) { rows[n].el.remove(); if (!state.peers.some(function (p) { return p.name === n; })) { delete rows[n]; } }
    });
    var empty = $("empty");
    if (!wanted.length) {
      if (!empty) { empty = el("div", "empty"); empty.id = "empty"; }
      var kind = state.peers.length ? "q:" + query.trim() : "none";
      if (empty.getAttribute("data-kind") !== kind) {   /* reconstruit seulement si le message change */
        empty.setAttribute("data-kind", kind);
        empty.textContent = "";
        if (state.peers.length) { empty.append(el("div", null, "Aucun appareil ne correspond à « " + query.trim() + " ».")); }
        else {
          empty.append(el("div", null, "Aucun appareil pour l'instant."));
          var b = el("button", "btn primary"); b.type = "button"; b.innerHTML = ICONS.plus; b.append(el("span", null, "Ajouter le premier"));
          b.addEventListener("click", openNew); empty.append(b);
        }
      }
      if (empty.parentNode !== list) { list.appendChild(empty); }
    } else if (empty) { empty.remove(); }
    /* ne réordonne le DOM que si l'ordre a changé (évite de perdre le focus) */
    var current = Array.prototype.filter.call(list.children, function (c) { return c.id !== "empty"; });
    var same = current.length === wanted.length && wanted.every(function (e, i) { return current[i] === e; });
    if (!same) { wanted.forEach(function (e) { list.appendChild(e); }); }
    var c = $("count"); c.textContent = String(state.peers.length); c.hidden = !state.peers.length;
  }

  /* ---- Actions ---- */
  function setEnabled(r, on) {
    r.busy = true; r.toggle.disabled = true;
    api("POST", peerUrl(r.name, on ? "enable" : "disable"), {}).then(function () {
      toast(on ? "Accès de « " + r.name + " » rétabli" : "Accès de « " + r.name + " » coupé");
      poll();
    }).catch(function (e) {
      r.toggle.checked = !on;
      if (e.message !== "session") { toast(e.message, true); }
    }).then(function () { r.busy = false; r.toggle.disabled = false; });
  }
  var dlg = $("dlg"), dbody = $("dlg-body");
  function openDialog(title, build) {
    dbody.textContent = "";
    var head = el("div", "dlg-head"), h = el("h3", null, title);
    h.id = "dlg-title";
    var x = iconBtn("close", "Fermer");
    x.addEventListener("click", closeDialog);
    head.append(h, x);
    dbody.append(head);
    build(dbody);
    if (!dlg.open) { if (dlg.showModal) { dlg.showModal(); } else { dlg.setAttribute("open", ""); } }
  }
  function closeDialog() { if (dlg.open) { if (dlg.close) { dlg.close(); } else { dlg.removeAttribute("open"); } } }
  /* Fermeture par clic sur le fond, seulement si le clic a aussi commencé sur le fond
     (une sélection de texte relâchée à l'extérieur ne doit pas fermer la fenêtre) */
  var downOnBackdrop = false;
  dlg.addEventListener("pointerdown", function (e) { downOnBackdrop = e.target === dlg; });
  dlg.addEventListener("click", function (e) { if (e.target === dlg && downOnBackdrop) { closeDialog(); } downOnBackdrop = false; });
  /* Erreur d'une fenêtre déjà fermée : affichée en notification plutôt que perdue */
  function showError(f, err, ok, x) {
    if (f.isConnected && dlg.open) { err.textContent = x.message; err.hidden = false; ok.disabled = false; }
    else if (x.message !== "session") { toast(x.message, true); }
  }
  function actionsBar(cancelText, okText, okClass) {
    var bar = el("div", "dlg-actions"), cancel = el("button", "btn ghost", cancelText), ok = el("button", "btn " + okClass, okText);
    cancel.type = "button"; ok.type = "submit";
    cancel.addEventListener("click", closeDialog);
    bar.append(cancel, ok);
    return {bar: bar, ok: ok};
  }
  function errorBox() { var e = el("div", "note bad"); e.hidden = true; return e; }
  function nameInput(id, value) {
    var inp = el("input"); inp.id = id; inp.type = "text"; inp.required = true; inp.maxLength = 15;
    inp.pattern = "[A-Za-z0-9_][A-Za-z0-9_\\-]{0,14}"; inp.placeholder = "ex. telephone, pc-salon";
    inp.autocomplete = "off"; inp.spellcheck = false; inp.setAttribute("autocapitalize", "off");
    inp.value = value || "";
    return inp;
  }
  function step(iconName, title, items) {
    var s = el("div", "step"), h = el("h4"), ol = el("ol");
    h.innerHTML = ICONS[iconName]; h.append(document.createTextNode(title));
    items.forEach(function (t) { ol.append(el("li", null, t)); });
    s.append(h, ol);
    return s;
  }
  function openQR(name, isNew) {
    openDialog(name, function (b) {
      if (isNew) { b.append(el("div", "note ok", "Appareil créé : scannez ce QR code avec l'application WireGuard.")); }
      var wrap = el("div", "qr-wrap"), img = el("img", "qr");
      img.alt = "QR code de configuration de " + name;
      img.src = "/device/" + encodeURIComponent(name) + "/qr?v=" + Date.now();
      var steps = el("div", "steps");
      steps.append(step("phone", "Téléphone ou tablette", ["Installez l'application WireGuard.", "Touchez + › Scanner un code QR.", "Visez ce QR code, puis activez le tunnel."]));
      var pc = step("laptop", "Ordinateur", ["Téléchargez le fichier de configuration.", "WireGuard › Importer un tunnel depuis un fichier."]);
      var a = el("a", "btn primary"); a.innerHTML = ICONS.download; a.append(el("span", null, "Télécharger " + name + ".conf"));
      a.href = "/device/" + encodeURIComponent(name) + "/conf"; a.setAttribute("download", name + ".conf");
      pc.append(a);
      steps.append(pc);
      wrap.append(img, steps);
      b.append(wrap, el("p", "hint", "Ce QR code et ce fichier contiennent la clé privée de l'appareil : ne les partagez pas."));
    });
  }
  function choice(value, title, desc, checked) {
    var l = el("label", "choice" + (checked ? " on" : "")), r = el("input"), t = el("span", "choice-text");
    r.type = "radio"; r.name = "mode"; r.value = value; r.checked = checked;
    t.append(el("b", null, title), el("span", null, desc));
    l.append(r, t);
    return l;
  }
  function openNew() {
    var def = state && state.server.default_route === "split" ? "split" : "full";
    openDialog("Nouvel appareil", function (b) {
      var f = el("form", "form"), lab = el("label", "field", "Nom de l'appareil"), inp = nameInput("new-name");
      lab.htmlFor = "new-name";
      var modes = el("div", "choices");
      modes.append(choice("full", "Tout le trafic", "Wi-Fi publics sécurisés, Internet « depuis la maison ».", def === "full"),
                   choice("split", "Réseau de la maison", "NAS, PC de jeu, imprimante… le reste passe en direct.", def === "split"));
      modes.addEventListener("change", function () {
        modes.querySelectorAll(".choice").forEach(function (c) { c.classList.toggle("on", c.querySelector("input").checked); });
      });
      var err = errorBox(), act = actionsBar("Annuler", "Créer l'appareil", "primary");
      f.append(lab, inp, el("div", "hint", "1 à 15 caractères : lettres, chiffres, - et _ (sans espace ni accent)."),
               el("div", "field", "Ce que l'appareil fait passer par la maison"), modes, err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        var mode = (f.querySelector("input[name=mode]:checked") || {}).value || "full";
        api("POST", "/api/peers", {name: inp.value.trim(), mode: mode}).then(function (d) {
          poll();
          if (f.isConnected && dlg.open) { openQR(d.name, true); } else { toast("Appareil « " + d.name + " » créé"); }
        }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
      setTimeout(function () { inp.focus(); }, 30);
    });
  }
  function openRename(name) {
    openDialog("Renommer « " + name + " »", function (b) {
      var f = el("form", "form"), lab = el("label", "field", "Nouveau nom"), inp = nameInput("ren-name", name);
      lab.htmlFor = "ren-name";
      var err = errorBox(), act = actionsBar("Annuler", "Renommer", "primary");
      f.append(lab, inp, el("div", "hint", "Rien à changer sur l'appareil : son accès continue de fonctionner."), err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        var to = inp.value.trim();
        api("POST", peerUrl(name, "rename"), {name: to}).then(function () {
          if (f.isConnected) { closeDialog(); }
          toast("« " + name + " » s'appelle maintenant « " + to + " »");
          history[to] = history[name]; delete history[name];
          poll();
        }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
      setTimeout(function () { inp.focus(); inp.select(); }, 30);
    });
  }
  function openDelete(name) {
    openDialog("Supprimer « " + name + " » ?", function (b) {
      var f = el("form", "form"), err = errorBox(), act = actionsBar("Annuler", "Supprimer définitivement", "danger");
      f.append(el("p", null, "L'appareil ne pourra plus se connecter et sa configuration sera effacée. Pour couper l'accès temporairement, utilisez plutôt l'interrupteur."), err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true;
        api("POST", peerUrl(name, "delete"), {}).then(function () {
          if (f.isConnected) { closeDialog(); }
          toast("« " + name + " » supprimé"); delete history[name]; poll();
        }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
    });
  }

  /* ---- Barre d'outils ---- */
  $("new").addEventListener("click", openNew);
  $("search").addEventListener("input", function (e) { query = e.target.value; if (state) { renderList(); } });
  $("sort").addEventListener("change", function (e) { sortKey = e.target.value; if (state) { renderList(); } });
  $("srv-toggle").addEventListener("click", function () {
    var open = $("srv-details").hidden;
    $("srv-details").hidden = !open;
    $("srv-toggle").setAttribute("aria-expanded", String(open));
  });
  $("copy-key").addEventListener("click", function () {
    if (!state || !navigator.clipboard) { return; }
    navigator.clipboard.writeText(state.server.pubkey).then(function () { toast("Clé publique copiée"); });
  });
  $("logout").addEventListener("click", function () {
    api("POST", "/api/logout", {}).catch(function () {}).then(function () { window.location.href = "/login"; });
  });
  document.addEventListener("visibilitychange", poll);
  poll();
  setInterval(poll, 2000);
})();
"""


def head(title, csrf=""):
    meta = f'<meta name="csrf" content="{esc(csrf)}">' if csrf else ""
    return (f'<!doctype html><html lang="fr"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<meta name="robots" content="noindex">{meta}<title>{esc(title)} · wg-pi</title>'
            f'<link rel="icon" href="{FAVICON}"><style>{CSS}</style>'
            f'<script src="/static/theme.js"></script></head>')


def login_page(error=""):
    err = f'<div class="note bad">{esc(error)}</div>' if error else ""
    return head("Connexion") + f"""<body><main class="login">
<div class="card login-card">
<div class="login-logo">{LOGO}<div><b>wg-pi</b><span>VPN WireGuard®</span></div></div>{err}
<form method="post" action="/login"><label class="field" for="password">Mot de passe</label>
<input type="password" id="password" name="password" required autofocus autocomplete="current-password">
<button type="submit" class="btn primary block">Se connecter</button></form>
<p class="hint">Mot de passe oublié ? Sur le Pi : <code>sudo wg-pi web password</code></p></div>
<p class="foot">Accessible uniquement depuis le réseau de la maison et le VPN</p>
<p class="tm">{TRADEMARK}</p>
</main><script src="/static/app.js"></script></body></html>"""


def app_page(sess):
    return head("Appareils", sess["csrf"]) + f"""<body>
<header class="top"><div class="wrap bar">
<a class="brand" href="/">{LOGO}<b>wg-pi</b><small>VPN WireGuard®</small></a>
<div class="tools">
<button type="button" class="icon-btn" id="theme" aria-label="Changer de thème"></button>
<button type="button" class="btn ghost" id="logout" data-icon="logout"><span class="hide-sm">Déconnexion</span></button>
</div></div></header>
<main class="wrap">
<div class="alert" id="alert" role="alert" hidden></div>
<section class="card server" aria-label="Serveur">
<div class="srv-main">
<span class="pill ok" id="srv-state">Chargement…</span>
<div class="kv"><span>Adresse publique</span><b class="mono" id="srv-endpoint">…</b></div>
<div class="kv"><span>Réseau du VPN</span><b class="mono" id="srv-net">…</b></div>
<div class="kv"><span>Connectés</span><b id="srv-online">…</b></div>
<button type="button" class="btn ghost push" id="srv-toggle" aria-expanded="false" aria-controls="srv-details">Détails<span class="ico" data-icon="chevron"></span></button>
</div>
<div class="srv-details" id="srv-details" hidden>
<div class="kv wide"><span>Clé publique du serveur</span><div class="key"><b class="mono" id="d-pubkey"></b>
<button type="button" class="icon-btn" id="copy-key" data-icon="copy" title="Copier la clé publique" aria-label="Copier la clé publique"></button></div></div>
<div class="kv"><span>Port</span><b id="d-port"></b></div>
<div class="kv"><span>Réseau IPv6 du VPN</span><b class="mono" id="d-net6"></b></div>
<div class="kv"><span>DNS des appareils</span><b class="mono" id="d-dns"></b></div>
<div class="kv"><span>Keepalive</span><b id="d-keepalive"></b></div>
<div class="kv"><span>Réseau de la maison</span><b class="mono" id="d-lan"></b></div>
<div class="kv"><span>Mode par défaut</span><b id="d-mode"></b></div>
<div class="kv"><span>Version</span><b id="d-version"></b></div>
</div></section>
<section class="card clients" aria-label="Appareils">
<div class="clients-head"><h2>Appareils <span class="count" id="count" hidden></span></h2>
<div class="clients-tools">
<label class="search" data-icon="search"><input type="search" id="search" placeholder="Rechercher…" aria-label="Rechercher un appareil" autocomplete="off"></label>
<select id="sort" aria-label="Trier les appareils"><option value="name">Nom</option><option value="seen">Dernière connexion</option><option value="traffic">Trafic</option></select>
<button type="button" class="btn primary" id="new" data-icon="plus"><span>Nouvel appareil</span></button>
</div></div>
<div id="list"></div>
</section>
</main>
<footer>Accessible uniquement depuis le réseau de la maison et le VPN · wg-pi {esc(VERSION)}<div class="tm">{TRADEMARK}</div></footer>
<dialog id="dlg" aria-labelledby="dlg-title"><div class="dlg" id="dlg-body"></div></dialog>
<div class="toast" id="toast" role="status" hidden></div>
<script src="/static/app.js"></script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "wg-pi"
    sys_version = ""
    timeout = 30

    def setup(self):
        super().setup()
        self.connection.do_handshake()

    def log_message(self, fmt, *args):
        pass

    def is_allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        return any(ip in net for net in ALLOWED_NETS)

    def send(self, code, body, ctype="text/html; charset=utf-8", headers=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, code, obj, headers=None):
        self.send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8", headers)

    def redirect(self, location, headers=None):
        self.send(303, "", headers=dict({"Location": location}, **(headers or {})))

    def forbidden(self):
        self.send(403, "Accès réservé au réseau de la maison et au VPN.\n", "text/plain; charset=utf-8")

    def get_session(self):
        token = ""
        for part in self.headers.get("Cookie", "").split(";"):
            key, _, value = part.strip().partition("=")
            if key == COOKIE:
                token = value
        if not token:
            return None
        with lock:
            s = sessions.get(token)
            if not s or s["expires"] < time.time():
                sessions.pop(token, None)
                return None
            s["expires"] = time.time() + SESSION_TTL
            return {"token": token, "csrf": s["csrf"]}

    def do_GET(self):
        if not self.is_allowed():
            return self.forbidden()
        path = urllib.parse.urlsplit(self.path).path
        if path == "/static/app.js":
            return self.send(200, APP_JS, "application/javascript; charset=utf-8")
        if path == "/static/theme.js":
            return self.send(200, THEME_JS, "application/javascript; charset=utf-8")
        if path == "/login":
            return self.send(200, login_page())
        sess = self.get_session()
        if not sess:
            if path.startswith("/api/"):
                return self.send_json(401, {"error": "Session expirée : reconnectez-vous."})
            return self.redirect("/login")
        if path == "/":
            return self.send(200, app_page(sess))
        if path == "/api/state":
            try:
                return self.send_json(200, get_state())
            except Exception as e:  # état illisible : on le signale à la page plutôt que de planter
                return self.send_json(500, {"error": str(e)})
        m = re.fullmatch(r"/device/([A-Za-z0-9_-]{1,15})/(conf|qr)", path)
        if m:
            name, kind = m.groups()
            conf = client_conf_path(name)
            if not conf:
                return self.send(404, "Appareil introuvable.\n", "text/plain; charset=utf-8")
            if kind == "qr":
                png = qr_png(conf)
                if not png:
                    return self.send(500, "QR code indisponible (qrencode).\n", "text/plain; charset=utf-8")
                return self.send(200, png, "image/png")
            with open(conf, "rb") as f:
                data = f.read()
            log(f"{self.client_address[0]} : téléchargement de {name}.conf")
            return self.send(200, data, "application/octet-stream",
                             {"Content-Disposition": f'attachment; filename="{name}.conf"'})
        if path.startswith("/device/"):
            return self.redirect("/")
        return self.send(404, "Page introuvable.\n", "text/plain; charset=utf-8")

    def do_POST(self):
        if not self.is_allowed():
            return self.forbidden()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 <= length <= 4096:
            return self.send(413, "Requête refusée.\n", "text/plain; charset=utf-8")
        raw = self.rfile.read(length).decode("utf-8", "replace")
        path = urllib.parse.urlsplit(self.path).path
        if path == "/login":
            form = urllib.parse.parse_qs(raw)
            return self.handle_login((form.get("password") or [""])[0])
        sess = self.get_session()
        if not sess:
            return self.send_json(401, {"error": "Session expirée : reconnectez-vous."})
        # Jeton anti-CSRF dans un en-tête : impossible à poser depuis un autre site
        if not same(self.headers.get("X-CSRF-Token", ""), sess["csrf"]):
            return self.send_json(403, {"error": "Jeton de sécurité invalide : rechargez la page."})
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        if path == "/api/logout":
            with lock:
                sessions.pop(sess["token"], None)
            return self.send_json(200, {"ok": True},
                                  {"Set-Cookie": f"{COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0"})
        if path == "/api/peers":
            name = str(body.get("name", "")).strip()
            if not NEW_NAME_RE.fullmatch(name):
                return self.send_json(400, {"error": "Nom invalide : 1 à 15 caractères parmi lettres, chiffres, - et _ "
                                                     "(sans espace, sans accent, sans tiret au début)."})
            mode = "--split" if body.get("mode") == "split" else "--full"
            return self.mutate(("add", name, mode), f"appareil « {name} » ajouté", {"ok": True, "name": name})
        m = re.fullmatch(r"/api/peers/([A-Za-z0-9_-]{1,15})/(delete|enable|disable|rename)", path)
        if m:
            name, action = m.groups()
            # Un ancien appareil peut commencer par « - » : seules les options de wg-pi sont refusées
            if name in ("-y", "--yes", "--auto"):
                return self.send_json(404, {"error": "Appareil introuvable."})
            if action == "rename":
                new = str(body.get("name", "")).strip()
                if not NEW_NAME_RE.fullmatch(new):
                    return self.send_json(400, {"error": "Nouveau nom invalide : 1 à 15 caractères parmi lettres, "
                                                         "chiffres, - et _ (sans tiret au début)."})
                return self.mutate(("rename", name, new), f"« {name} » renommé en « {new} »", {"ok": True, "name": new})
            args = ("remove", name, "--yes") if action == "delete" else (action, name)
            labels = {"delete": "supprimé", "enable": "réactivé", "disable": "désactivé"}
            return self.mutate(args, f"appareil « {name} » {labels[action]}", {"ok": True})
        return self.send_json(404, {"error": "Action inconnue."})

    def mutate(self, args, what, result):
        r = run_wgpi(*args)
        invalidate()
        if r.returncode != 0:
            return self.send_json(400, {"error": clean_message(r.stderr or r.stdout)})
        log(f"{self.client_address[0]} : {what}")
        return self.send_json(200, result)

    def handle_login(self, password):
        ip = self.client_address[0]
        now = time.time()
        # L'essai est compté AVANT la vérification, sous le verrou : des requêtes envoyées
        # en parallèle ne peuvent pas contourner le blocage
        with lock:
            fails, until = failures.get(ip, (0, 0))
            if until <= now:
                fails += 1
                failures[ip] = (0, now + BLOCK_SECONDS) if fails >= MAX_FAILS else (fails, 0)
        if until > now:
            wait = int((until - now) // 60) + 1
            return self.send(429, login_page(f"Trop d'essais : réessayez dans {wait} min."))
        with login_lock:
            good = bool(password) and check_password(password)
        if good:
            token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            with lock:
                failures.pop(ip, None)
                for t in [t for t, s in sessions.items() if s["expires"] < now]:
                    del sessions[t]
                sessions[token] = {"expires": now + SESSION_TTL, "csrf": csrf}
            log(f"{ip} : connexion réussie")
            return self.redirect("/", {"Set-Cookie": f"{COOKIE}={token}; Path=/; HttpOnly; Secure; SameSite=Strict"})
        time.sleep(1)
        log(f"{ip} : mot de passe incorrect")
        return self.send(401, login_page("Mot de passe incorrect."))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ssl.SSLError, OSError)):
            return  # client non HTTPS, connexion coupée… sans intérêt dans le journal
        super().handle_error(request, client_address)


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.path.join(WEB_DIR, "cert.pem"), os.path.join(WEB_DIR, "key.pem"))
    httpd = Server(("0.0.0.0", PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    log(f"Interface web wg-pi {VERSION} à l'écoute en HTTPS sur le port {PORT}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
}

cmd_menu() {
  load_settings
  local c
  while true; do
    title "wg-pi — menu"
    txt "   1) Ajouter un appareil" \
        "   2) Supprimer un appareil" \
        "   3) Couper / rétablir l'accès d'un appareil" \
        "   4) Renommer un appareil" \
        "   5) Voir les appareils (qui est connecté ?)" \
        "   6) Afficher le QR code d'un appareil" \
        "   7) Diagnostic : ça ne marche pas ?" \
        "   8) Aide pour configurer la box" \
        "   9) Changer l'adresse publique (IP, DuckDNS…)" \
        "  10) Sauvegarder la configuration" \
        "  11) Interface web (gérer depuis le navigateur)" \
        "  12) Mettre à jour wg-pi" \
        "  13) Désinstaller" \
        "   0) Quitter" ""
    ask c "Votre choix" "0"
    case $c in
      1) (cmd_add) ;;
      2) (cmd_remove) ;;
      3) (cmd_toggle) ;;
      4) (cmd_rename) ;;
      5) (cmd_list) ;;
      6) (cmd_qr) ;;
      7) (cmd_check) ;;
      8) (cmd_box) ;;
      9) (cmd_endpoint) ;;
      10) (cmd_backup) ;;
      11) (cmd_web) ;;
      12) (cmd_update) ;;
      13) (cmd_uninstall); is_installed || return 0 ;;
      0|q|Q) return 0 ;;
      *) warn "Choix inconnu." ;;
    esac
    pause
  done
}

# Commandes internes appelées par les timers systemd
cmd_ddns_update() {
  [[ -r $DUCKDNS_FILE ]] || exit 0
  # shellcheck source=/dev/null
  source "$DUCKDNS_FILE"
  local r
  r=$(duckdns_call "$DUCKDNS_DOMAIN" "$DUCKDNS_TOKEN")
  [[ $r == OK* ]] || { echo "DuckDNS : échec de la mise à jour (réponse : ${r:-aucune})" >&2; exit 1; }
  echo "DuckDNS : $DUCKDNS_DOMAIN.duckdns.org à jour"
}

cmd_upnp_refresh() {
  load_settings
  (( UPNP )) || exit 0
  local cur
  cur=$(current_lan_ip)
  [[ -n $cur ]] && LAN_IP=$cur
  upnp_map || { echo "UPnP : impossible d'ouvrir le port $WG_PORT/UDP vers $LAN_IP" >&2; exit 1; }
  echo "UPnP : port $WG_PORT/UDP ouvert vers $LAN_IP"
}

usage() {
  cat <<EOF
${BOLD}wg-pi $WGPI_VERSION${RESET} — serveur VPN WireGuard « clé en main » pour Raspberry Pi

Utilisation : sudo wg-pi [commande]

  (sans commande)       menu interactif (ou installation si rien n'est installé)
  install [options]     installation assistée
  add [nom] [--split|--full]
                        ajouter un appareil et afficher son QR code
                        (--split : seulement l'accès au réseau de la maison,
                         --full : tout le trafic ; sinon le mode choisi à l'installation)
  remove [nom]          supprimer un appareil
  disable [nom]         couper l'accès d'un appareil sans le supprimer
  enable [nom]          rétablir l'accès d'un appareil
  rename [nom] [nouveau] renommer un appareil (rien à changer sur l'appareil)
  list                  appareils et état des connexions
  qr [nom]              réafficher le QR code / exporter la config d'un appareil
  check                 diagnostic complet
  box                   rappel : comment configurer la box
  endpoint [adresse]    changer l'adresse publique (IP, nom de domaine, DuckDNS)
  backup                sauvegarder la configuration (clés comprises)
  restore <fichier>     restaurer une sauvegarde (ex. sur une nouvelle carte SD)
  web [off|password|port N]
                        interface web d'administration (navigateur, réseau local et VPN)
  update                mettre à jour wg-pi depuis le dépôt GitHub
  uninstall             tout désinstaller
  help | version

Option générale :
  --yes                 sans questions : réponses par défaut pour l'installation,
                        confirmation automatique pour remove et uninstall

Options d'installation :
  --endpoint <adresse>  IP publique ou nom de domaine à utiliser
  --port <port>         port UDP (par défaut 51820)
  --client <nom>        nom du premier appareil (par défaut « telephone »)

Journal : $LOG_FILE
Projet  : $WGPI_REPO
EOF
}

main() {
  # Copie temporaire lancée par l'amorçage plus bas : supprimée en sortant
  if [[ -n ${WGPI_BOOTSTRAP:-} && $WGPI_BOOTSTRAP == "$WGPI_SELF" ]]; then
    trap 'rm -f -- "$WGPI_BOOTSTRAP"' EXIT
  fi
  local -a orig=("$@") args=()
  local a
  for a in "$@"; do
    case $a in
      -y|--yes|--auto) AUTO=1 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"
  local cmd=${1:-}
  (( $# )) && shift

  case $cmd in
    help|-h|--help|aide) usage; return 0 ;;
    version|-v|--version) echo "wg-pi $WGPI_VERSION — $WGPI_REPO"; return 0 ;;
  esac
  require_root "${orig[@]+"${orig[@]}"}"
  # Arrivé par un pipe (curl … | sudo bash) : le lien « main » de GitHub peut servir une version
  # en cache. On relance d'abord la toute dernière version, téléchargée par commit, pour que ce
  # soit elle qui installe (et pas seulement elle qui soit copiée à la fin).
  local boot
  if [[ -z $(self_path) && $WGPI_URL == "$WGPI_DEFAULT_URL" && -z ${WGPI_BOOTSTRAP:-} ]] &&
     command -v curl >/dev/null 2>&1 && download_script boot; then
    WGPI_BOOTSTRAP=$boot exec bash "$boot" "${orig[@]+"${orig[@]}"}"
  fi
  init_input
  touch "$LOG_FILE" 2>/dev/null
  trap 'printf "\n"; fail "Interrompu."; exit 130' INT

  case $cmd in
    "")
      if is_installed; then
        if interactive; then cmd_menu; else usage; fi
      else
        cmd_install
      fi ;;
    menu)                    cmd_menu ;;
    install)                 cmd_install "$@" ;;
    add|ajouter)             cmd_add "$@" ;;
    remove|rm|del|supprimer) cmd_remove "$@" ;;
    list|ls|liste|status)    cmd_list ;;
    qr|show)                 cmd_qr "$@" ;;
    check|doctor|diagnostic) cmd_check ;;
    box)                     cmd_box ;;
    endpoint)                cmd_endpoint "$@" ;;
    backup|sauvegarde)       cmd_backup ;;
    restore)                 cmd_restore "$@" ;;
    update|mise-a-jour)      cmd_update ;;
    disable|desactiver)      cmd_set_state off "$@" ;;
    enable|activer)          cmd_set_state on "$@" ;;
    rename|renommer)         cmd_rename "$@" ;;
    web)                     cmd_web "$@" ;;
    web-serve)               cmd_web_serve ;;
    json)                    cmd_json ;;
    uninstall|desinstaller)  cmd_uninstall ;;
    ddns-update)             cmd_ddns_update ;;
    upnp-refresh)            cmd_upnp_refresh ;;
    *) fail "Commande inconnue : $cmd"; echo; usage; return 1 ;;
  esac
}

main "$@"
