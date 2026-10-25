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

readonly WGPI_VERSION="1.1.1"
readonly WGPI_REPO="https://github.com/y0uls/WireGuard-RP"
# Adresse de la dernière version (modifiable pour un fork : WGPI_URL=… sudo -E wg-pi update)
readonly WGPI_URL="${WGPI_URL:-https://raw.githubusercontent.com/y0uls/WireGuard-RP/main/wg-pi.sh}"
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
valid_name()      { [[ $1 =~ ^[A-Za-z0-9_-]{1,15}$ ]]; }
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
  flock -n 9 || die "wg-pi est déjà en cours d'exécution dans un autre terminal."
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

# download_script <variable> : télécharge la dernière version dans un fichier temporaire
# et vérifie qu'il s'agit bien d'un script wg-pi valide
download_script() {
  local _f
  _f=$(mktemp) || return 1
  if ! curl -fsSL --max-time 60 "$WGPI_URL" -o "$_f" 2>>"$LOG_FILE"; then
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
# Affiche « nom ip clé_publique » pour chaque appareil déclaré dans wg0.conf
peers_table() {
  awk -v mark="$MARK" '
    index($0, mark " ") == 1 { name = substr($0, length(mark) + 2); next }
    name != "" && $1 == "PublicKey"  { pub = $3 }
    name != "" && $1 == "AllowedIPs" { split($3, a, "/"); print name, a[1], pub; name = "" }
  ' "$WG_CONF"
}

client_exists() { grep -qxF "$MARK $1" "$WG_CONF"; }
client_pubkey() { peers_table | awk -v n="$1" '$1 == n { print $3 }'; }
client_names()  { peers_table | awk '{ print $1 }'; }

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
  awk -v m="$MARK $name" -v p="$MARK " '
    $0 == m { skip = 1; next }
    skip && index($0, p) == 1 { skip = 0 }
    !skip { print }
  ' "$WG_CONF" >"$tmp" && cat "$tmp" >"$WG_CONF"
  rm -f "$tmp" "$CLIENTS_DIR/$name.conf"
  dir=$(user_export_dir)
  [[ -n $dir ]] && rm -f "$dir/$name.conf" "$dir/$name.png"
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
  local pub _psk endpoint _allowed latest r t _ka name ip state count=0 online=0 now
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
  while read -r name ip pub; do
    (( count++ ))
    latest=${hs["$pub"]:-0}
    if (( latest == 0 )); then
      state="${DIM}jamais${RESET}"
    elif (( now - latest < 180 )); then
      state="${GREEN}● connecté${RESET} (${ep["$pub"]:-?})"
      (( online++ ))
    else
      state=$(ago "$latest")
    fi
    printf '  %s %s %s %s  %s\n' "$(pad "$name" 16)" "$(pad "$ip" 13)" \
      "$(pad "$(human "${rx["$pub"]:-0}")" 9)" "$(pad "$(human "${tx["$pub"]:-0}")" 9)" "$state"
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

  now=$(date +%s)
  while read -r _ _ pub; do
    (( total++ ))
    ts=$(latest_handshake "$pub")
    [[ -n $ts ]] && (( ts > 0 && now - ts < 180 )) && (( online++ ))
  done < <(peers_table)
  info "$total appareil(s) configuré(s), $online connecté(s) en ce moment"
  [[ -f /run/reboot-required ]] && warn "Un redémarrage est demandé par les mises à jour : sudo reboot"

  echo
  if (( problems == 0 )); then
    ok "${BOLD}Tout est en ordre côté Pi.${RESET}"
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
  local t
  for t in wg-pi-duckdns wg-pi-upnp; do
    systemctl disable --now "$t.timer" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$t.service" "$UNIT_DIR/$t.timer"
  done
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
  put_bin "$tmp" || { rm -f "$tmp"; die "Impossible de remplacer $BIN_PATH."; }
  rm -f "$tmp"
  ok "wg-pi mis à jour : v$old → v${new:-?} (vos réglages et appareils ne changent pas)"
}

cmd_menu() {
  load_settings
  local c
  while true; do
    title "wg-pi — menu"
    txt "   1) Ajouter un appareil" \
        "   2) Supprimer un appareil" \
        "   3) Voir les appareils (qui est connecté ?)" \
        "   4) Afficher le QR code d'un appareil" \
        "   5) Diagnostic : ça ne marche pas ?" \
        "   6) Aide pour configurer la box" \
        "   7) Changer l'adresse publique (IP, DuckDNS…)" \
        "   8) Sauvegarder la configuration" \
        "   9) Mettre à jour wg-pi" \
        "  10) Désinstaller" \
        "   0) Quitter" ""
    ask c "Votre choix" "0"
    case $c in
      1) (cmd_add) ;;
      2) (cmd_remove) ;;
      3) (cmd_list) ;;
      4) (cmd_qr) ;;
      5) (cmd_check) ;;
      6) (cmd_box) ;;
      7) (cmd_endpoint) ;;
      8) (cmd_backup) ;;
      9) (cmd_update) ;;
      10) (cmd_uninstall); is_installed || return 0 ;;
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
  list                  appareils et état des connexions
  qr [nom]              réafficher le QR code / exporter la config d'un appareil
  check                 diagnostic complet
  box                   rappel : comment configurer la box
  endpoint [adresse]    changer l'adresse publique (IP, nom de domaine, DuckDNS)
  backup                sauvegarder la configuration (clés comprises)
  restore <fichier>     restaurer une sauvegarde (ex. sur une nouvelle carte SD)
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
    uninstall|desinstaller)  cmd_uninstall ;;
    ddns-update)             cmd_ddns_update ;;
    upnp-refresh)            cmd_upnp_refresh ;;
    *) fail "Commande inconnue : $cmd"; echo; usage; return 1 ;;
  esac
}

main "$@"
