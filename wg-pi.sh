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

readonly WGPI_VERSION="1.4.0"
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
# Génération du pare-feu généré. À incrémenter dès que write_firewall_script change :
# c'est ce qui déclenche la migration d'une installation existante par « wg-pi update ».
readonly FW_GEN=4
# Groupes, ressources et règles d'accès (sudo wg-pi group / resource / access)
readonly ACCESS_FILE="$STATE_DIR/access.conf"
readonly ACCESS_VER=1
readonly ACCESS_ALL="tous"      # identifiant du groupe virtuel « tous les appareils »
# Chemin séparé pour que les tests puissent le rediriger : le garde-fou SSH doit être
# vérifiable sans toucher à la configuration réelle de la machine.
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
# Instantané du pare-feu et minuteur d'annulation : dans /run, donc effacés au
# redémarrage — c'est voulu, un instantané périmé serait pire que pas d'instantané.
readonly ACCESS_SNAP="/run/wg-pi/access-snapshot"
readonly ACCESS_ROLLBACK_UNIT="wg-pi-access-rollback"
# La confirmation, elle, doit SURVIVRE au redémarrage : dans STATE_DIR, pas dans /run.
readonly ACCESS_CONFIRMED="$STATE_DIR/access-confirme"
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
REACH="unknown"       # ok | cgnat | unknown : la box peut-elle recevoir une connexion entrante ?

# État pendant l'exécution
AUTO=0
TTY=""
PUBLIC_IP=""
UPNP_OK=0
REACH_WHY=""          # phrase qui explique l’indice retenu par detect_reachability
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

# json_esc <texte> : echappe une valeur pour une chaine JSON.
# cmd_json n'echappait rien : des qu'un libelle saisi par l'utilisateur y entre, le JSON
# devient invalide, json.loads leve, et /api/state repond 500 — soit le panneau entier
# blanc, et pas seulement la vue concernee. Tout nouveau champ texte doit passer par ici.
json_esc() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  printf '%s' "$s"
}

# atomic_write <fichier> [droits] : ecrit l entree standard dans <fichier> sans jamais
# le laisser tronque. Sans <droits>, les droits existants sont conserves (600 pour un
# fichier neuf) ; avec, ils sont imposes — ce qui remet d aplomb un fichier que
# l utilisateur aurait cree a la main avec des droits trop larges.
# tronque. Le motif « cmd > tmp && cat tmp > fichier » employe ailleurs dans ce script vide
# la cible avant de la recopier : une coupure au mauvais moment faisait perdre le fichier,
# donc pour wg0.conf la cle privee du serveur et tous les appareils. mktemp est place dans
# le dossier de destination, sinon « mv » degenere en copie puis suppression et perd son
# atomicite.
atomic_write() {
  local dest=$1 want=${2-} dir tmp mode
  dir=$(dirname "$dest")
  if [[ -n $want ]]; then
    mode=$want
  else
    mode=$(stat -c '%a' "$dest" 2>/dev/null) || mode=600
  fi
  tmp=$(mktemp "$dir/.$(basename "$dest").XXXXXX") || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s $tmp ]] || { rm -f "$tmp"; return 1; }   # un generateur en echec ne doit pas installer un fichier vide
  # Un chmod ou un mv en échec laisserait le temporaire sur place. Ce n'est pas
  # seulement de l'encombrement : atomic_write sert aussi à écrire wg0.conf, qui
  # contient la clé privée du serveur.
  if ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

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

# Votre box peut-elle recevoir une connexion venant d’Internet ?
# Positionne REACH (ok | cgnat | unknown) et REACH_WHY (l’indice retenu, en français).
# Les indices viennent de la box elle-même (UPnP) et de sondes ICMP : aucun service tiers,
# aucun paquet supplémentaire. Presque toujours < 3 s, 10 s au pire (box muette), et
# « unknown » dès que rien n’est concluant : on ne rassure jamais à tort.
detect_reachability() {
  REACH=unknown
  REACH_WHY="Impossible de le vérifier depuis le Pi : la box ne répond pas en UPnP et ne laisse pas passer les sondes."
  local ext hop ttl self probe=1.1.1.1

  # 1. L’adresse que la box annonce côté Internet est l’indice le plus fiable.
  ext=$(upnp_external_ip) || ext=""
  if [[ -n $ext ]]; then
    if is_private_ipv4 "$ext" || is_cgnat "$ext"; then
      REACH=cgnat
      REACH_WHY="La box annonce l’adresse $ext côté Internet : elle n’est pas directement sur Internet (un autre routeur devant, ou une adresse partagée par l’opérateur)."
      return 0
    fi
    if [[ -n $PUBLIC_IP && $ext != "$PUBLIC_IP" ]]; then
      REACH=cgnat
      REACH_WHY="La box annonce $ext côté Internet, mais vos connexions sortent avec l’adresse $PUBLIC_IP : votre opérateur partage son adresse entre plusieurs abonnés (CGNAT)."
      return 0
    fi
    if [[ $ext == "$PUBLIC_IP" ]]; then
      # Verdict favorable, mais pas definitif : certaines box 4G/5G interrogent un serveur
      # STUN et annoncent l'adresse publique vue depuis Internet, alors qu'elles sont
      # elles-memes derriere le NAT de l'operateur. On retient « ok » sans sortir, et on
      # laisse les indices suivants le contredire s'ils trouvent un routeur d'operateur
      # au-dessus de la box : un verdict favorable doit etre le plus difficile a obtenir.
      REACH=ok
      REACH_WHY="La box porte bien votre adresse publique $PUBLIC_IP : une redirection de port est possible."
    fi
  fi

  # 2. Le Pi est lui-même sur un réseau d'opérateur : clé 4G/5G branchée dessus, partage de
  #    connexion depuis un téléphone. C'est l'adresse DU PI qu'il faut regarder, et pas l'IP
  #    publique : api.ipify.org et les services du même genre rapportent l'adresse qu'ils
  #    voient, donc celle du NAT de l'opérateur, qui est publique — jamais du 100.64.0.0/10.
  self=$(current_lan_ip) || self=""
  [[ -n $self ]] || self=$LAN_IP
  if is_cgnat "$self"; then
    REACH=cgnat
    REACH_WHY="Le Pi a reçu l'adresse $self, dans la plage partagée des opérateurs (100.64.0.0/10) : il est lui-même derrière le NAT de l'opérateur, et aucune connexion entrante ne peut l'atteindre."
    return 0
  fi

  # 3. Sonde TTL : un routeur en 100.64.0.0/10, ou à adresse privée au-delà de la box,
  #    trahit un NAT d’opérateur entre la box et Internet. Beaucoup de box filtrent ces
  #    réponses ICMP : dans ce cas on ne conclut rien plutôt que de rassurer à tort.
  command -v ping >/dev/null 2>&1 || return 0
  for ttl in 1 2 3 4; do
    hop=$(LC_ALL=C ping -4 -n -t "$ttl" -c 1 -W 1 "$probe" 2>/dev/null |
            sed -n 's/^From \([0-9.]*\).*[Tt]ime to live exceeded.*/\1/p' | head -n1) || true
    [[ -n $hop ]] || continue
    is_ipv4 "$hop" || continue
    if is_cgnat "$hop"; then
      REACH=cgnat
      REACH_WHY="Un routeur de votre opérateur répond en $hop (plage partagée 100.64.0.0/10) entre votre box et Internet : les connexions entrantes n’arrivent jamais jusqu’à la box."
      return 0
    fi
    if is_private_ipv4 "$hop" && [[ $hop != "${LAN_GW:-}" ]]; then
      REACH=cgnat
      REACH_WHY="Un routeur à adresse privée ($hop) se trouve entre votre box (${LAN_GW:-?}) et Internet : la redirection devrait aussi être faite sur ce routeur, ou votre opérateur partage son adresse."
      return 0
    fi
    # Premier saut déjà public : rien d’anormal au-dessus de la box, on arrête de sonder.
    is_private_ipv4 "$hop" || break
  done
  return 0
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
             ENDPOINT CLIENT_DNS DEFAULT_ROUTE SERVER_PUBKEY DDNS UPNP UNATTENDED ISP IP_MODE REACH; do
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
    echo "# wg-pi-fw-gen: $FW_GEN"
    echo "# Généré par wg-pi : règles pare-feu et NAT du VPN, appliquées par wg-quick"
    echo "# (PostUp/PostDown de $WG_CONF). Usage : firewall.sh up|down|reload"
    echo "WG_IF='$WG_IF'"
    echo "PORT='$WG_PORT'"
    echo "ACCESS_FILE='$ACCESS_FILE'"
    echo "BIN='$BIN_PATH'"
    echo "NET4='$WG_NET4.0/24'"
    echo "NET6='${WG_NET6}/64'"
    echo "IPV6_NAT='$IPV6_NAT'"
    cat <<'EOF'

# Le filtrage est-il demandé ? Lu dans le fichier d'accès, pas dans les réglages : c'est
# la même source de vérité que la commande wg-pi. Le test porte sur « filtre » et jamais
# sur « ouvert », pour qu'un fichier absent ou abîmé laisse passer le trafic.
filtering() {
  [ -r "$ACCESS_FILE" ] || return 1
  [ "$(awk -F"|" '$1 == "MODE" { print $2; exit }' "$ACCESS_FILE" 2>/dev/null)" = "filtre" ]
}

rules() { # $1 = -I (ajout) ou -D (retrait), $2 = iptables ou ip6tables, $3 = réseau du VPN
  rc=0
  "$2" -w "$1" INPUT -p udp --dport "$PORT" -j ACCEPT || rc=1
  # « ! -i $WG_IF » est indispensable : sans lui, cette règle accepte aussi le trafic d'un
  # appareil du VPN vers un autre (il entre ET sort par wg0) dès que la connexion est
  # établie, ce qui contournerait tout filtrage entre appareils.
  "$2" -w "$1" FORWARD -o "$WG_IF" ! -i "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || rc=1
  "$2" -w -t nat "$1" POSTROUTING -s "$3" ! -o "$WG_IF" -j MASQUERADE || rc=1
  return $rc
}

# Retire les règles des générations précédentes, dont la forme a changé : sans ça, une
# ancienne règle conntrack « -o wg0 » sans « ! -i wg0 » survivrait au rechargement et
# continuerait d'accepter le trafic déjà établi entre deux appareils.
legacy_down() {
  _ld_del() {
    i=0
    while [ "$i" -lt 5 ]; do
      "$1" -w -D FORWARD -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || break
      i=$((i + 1))
    done
  }
  _ld_del iptables
  [ "$IPV6_NAT" = 1 ] && _ld_del ip6tables
  return 0
}

# Retire l'acceptation générale du trafic venant du VPN, en boucle bornée : un
# rechargement antérieur a pu la poser plusieurs fois. TOUJOURS, sans regarder le mode :
# la poser dépend du filtrage, la retirer non. Sans cela elle survivait à une
# désinstallation faite pendant que le filtrage était actif.
blanket_del() {
  _bd() {
    i=0
    while [ "$i" -lt 10 ]; do
      "$1" -w -D FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null || break
      i=$((i + 1))
    done
  }
  _bd iptables
  [ "$IPV6_NAT" = 1 ] && _bd ip6tables
  return 0
}

base_down() {
  legacy_down
  blanket_del
  rules -D iptables "$NET4" 2>/dev/null
  [ "$IPV6_NAT" = 1 ] && rules -D ip6tables "$NET6" 2>/dev/null
  return 0
}

base_up() {
  # Nettoie d'éventuels restes avant d'ajouter (évite les doublons)
  base_down
  rules -I iptables "$NET4" || return 1
  if [ "$IPV6_NAT" = 1 ]; then
    rules -I ip6tables "$NET6" || echo "wg-pi : règles IPv6 non appliquées (IPv6 ignoré)" >&2
  fi
  # L'acceptation générale n'est posée QUE hors filtrage : sinon elle accepterait tout
  # avant que le moteur ait son mot à dire, et les règles seraient sans effet alors que
  # l'interface annoncerait le contraire.
  if ! filtering; then
    iptables -w -I FORWARD 1 -i "$WG_IF" -j ACCEPT || return 1
    [ "$IPV6_NAT" = 1 ] && { ip6tables -w -I FORWARD 1 -i "$WG_IF" -j ACCEPT || true; }
  fi
  return 0
}

# Reconstruit les chaînes du moteur et pose les sauts. Au démarrage, le minuteur
# d'annulation transitoire n'a pas survécu au redémarrage : --boot le RÉARME, parce que le
# réflexe de quelqu'un qui vient de se couper l'accès est de redémarrer.
access_up() {
  filtering || return 0
  [ -x "$BIN" ] || { echo "wg-pi : $BIN introuvable, filtrage non appliqué" >&2; return 1; }
  WGPI_LOCKED=1 "$BIN" access-apply --boot
}

access_down() {
  [ -x "$BIN" ] || return 0
  WGPI_LOCKED=1 "$BIN" access-apply --remove >/dev/null 2>&1 || true
  return 0
}

case "$1" in
  up)   base_up || exit 1; access_up || echo "wg-pi : règles d'accès non appliquées (sudo wg-pi access check)" >&2 ;;
  down) access_down; base_down ;;
  # « reload » refait le chemin COMPLET. C'est ce que conseille « wg-pi check » et ce
  # qu'appelle la migration après une mise à jour : jamais un sous-ensemble des règles,
  # sinon la remédiation affichée serait fausse.
  reload) access_down; base_down; base_up || exit 1; access_up || echo "wg-pi : règles d accès non appliquées (sudo wg-pi access check)" >&2 ;;
  *)
    echo "usage : $0 up|down|reload" >&2
    exit 2
    ;;
esac
exit 0
EOF
  } | atomic_write "$FW_SCRIPT" 700
}

# Génération du pare-feu actuellement installé, ou 0 s'il est absent ou antérieur au marqueur.
fw_installed_gen() {
  local g=""
  [[ -f $FW_SCRIPT ]] || { echo 0; return 0; }
  # awk plutot que sed : le motif tient sans aucun echappement, donc rien a casser.
  g=$(awk '/^# wg-pi-fw-gen: / { print $3; exit }' "$FW_SCRIPT" 2>/dev/null)
  echo "${g:-0}"
}

# Régénère le pare-feu et le recharge si celui installé date d'une version antérieure.
# Appelé par « wg-pi update » : write_firewall_script n'était sinon appelé qu'à
# l'installation et à la restauration, de sorte qu'une mise à jour laissait en place
# l'ancien pare-feu et qu'aucune correction de règle n'atteignait jamais les installations
# existantes.
fw_sync() {
  local cur sauve=""
  cur=$(fw_installed_gen)
  (( cur == FW_GEN )) && return 0
  info "Mise à jour des règles du pare-feu (génération $cur → $FW_GEN)…"
  # Le nouveau fichier porte la nouvelle génération DÈS SON ÉCRITURE. Si le
  # rechargement échoue ensuite, le laisser en place ferait mentir « fw-sync » et
  # « check », qui se croiraient à jour précisément quand il faut agir. On garde donc
  # de quoi revenir à l'ancien.
  if [[ -f $FW_SCRIPT ]]; then
    sauve=$(mktemp) || sauve=""
    # Un mktemp réussi suivi d'une copie en échec laisserait un fichier orphelin.
    if [[ -n $sauve ]] && ! cp -p "$FW_SCRIPT" "$sauve" 2>/dev/null; then
      rm -f "$sauve"
      sauve=""
    fi
  fi
  write_firewall_script || {
    fail "Impossible de régénérer $FW_SCRIPT."
    [[ -n $sauve ]] && rm -f "$sauve"
    return 1
  }
  if wg_running; then
    if "$FW_SCRIPT" reload; then
      ok "Règles du pare-feu rechargées."
    else
      if [[ -n $sauve ]]; then
        cp -p "$sauve" "$FW_SCRIPT" 2>/dev/null &&
          info "Ancien pare-feu rétabli : « sudo wg-pi fw-sync » pourra réessayer."
      fi
      rm -f "$sauve"
      fail "Rechargement des règles impossible → sudo systemctl restart wg-quick@$WG_IF"
      return 1
    fi
  else
    ok "Règles du pare-feu régénérées (appliquées au prochain démarrage du VPN)."
  fi
  [[ -n $sauve ]] && rm -f "$sauve"
  return 0
}

# Une version de wg-pi antérieure à 1.4.0 rangeait son instantané directement dans /run
# et lui appliquait « install -d -m 700 », ce qui revenait à faire « chmod 700 /run ».
# Tout ce qui ne tourne pas en root s'en trouvait cassé : Docker sans privilèges, la
# session de l'utilisateur, mDNS, la résolution de noms. On répare, et UNIQUEMENT quand
# les droits valent exactement 700 — c'est-à-dire quand c'est bien nous qui les avons posés.
repair_run_mode() {
  local m
  m=$(stat -c '%a' /run 2>/dev/null) || return 0
  [[ $m == 700 ]] || return 0
  chmod 755 /run 2>/dev/null &&
    warn "Droits de /run remis à 755 : une version précédente de wg-pi les avait restreints à 700."
  return 0
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
# Adresse que la box annonce côté Internet (UPnP), ou rien si elle ne répond pas.
upnp_external_ip() {
  local out ip
  command -v upnpc >/dev/null 2>&1 || return 1
  out=$(timeout 6 upnpc -m "$LAN_IF" -s 2>/dev/null) || true
  ip=$(sed -n 's/^ExternalIPAddress = //p' <<<"$out" | head -n1 | tr -d '[:space:]')
  is_ipv4 "$ip" || return 1
  printf '%s' "$ip"
}

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
  local ext
  info "Ouverture automatique du port $WG_PORT/UDP sur la box (UPnP)…"
  if ! ext=$(upnp_external_ip); then
    warn "La box ne répond pas en UPnP (option désactivée ?) : ouvrez le port à la main (guide pas à pas : sudo wg-pi box)."
    return 1
  fi
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
  ' "$WG_CONF" >"$tmp" && atomic_write "$WG_CONF" <"$tmp"
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
  ' "$WG_CONF" >"$tmp" && atomic_write "$WG_CONF" <"$tmp"
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
# Accès : groupes d'appareils, ressources de la maison et règles d'accès.
#
# Tout tient dans un seul fichier, $ACCESS_FILE, en champs séparés par « | ».
#
# Un SEUL fichier, parce que « mv » n'est atomique que pour un fichier : les lecteurs
# (cmd_json, firewall.sh) ne prennent donc aucun verrou et ne peuvent jamais voir un
# état à moitié écrit. Avec plusieurs fichiers, un lecteur mélangerait la nouvelle
# composition d'un groupe avec l'ancienne version d'une règle.
#
# Le séparateur « | » et non la tabulation : la tabulation est un caractère IFS blanc,
# donc « read » fusionne les délimiteurs consécutifs. Une règle sans port aurait
# silencieusement décalé tous les champs suivants, et rien ne l'aurait signalé.
#
# Jamais dans settings.conf, que load_settings charge par « source » : un libellé y
# deviendrait du code shell exécuté en root. Jamais dans wg0.conf non plus, dont
# peers_table termine la lecture d'un bloc sur la ligne AllowedIPs.
#
# Format :
#   V|<version>
#   MODE|ouvert                        ouvert = aucun filtrage, comportement historique
#   GROUP|<id>|<libellé>
#   MEMBER|<appareil>|<groupe>
#   RES|<id>|<libellé>|<ip ou cidr>
#   POLICY|<id>|<actif>|<source>|<destination>|<proto>|<ports>|<sens>|<libellé>
#
# Sources      : grp:<id>
# Destinations : internet | maison | pi | res:<id> | grp:<id>
# Protocoles   : any | tcp | udp | icmp
# Sens         : aller (seule la source initie) | deux
# ----------------------------------------------------------------------------

# Le groupe « tous » est VIRTUEL : jamais écrit en lignes MEMBER, calculé à la lecture.
# Rien à réconcilier quand un appareil est ajouté, aucune dérive possible, et tout nouvel
# appareil est immédiatement couvert par les règles qui l'utilisent.
access_is_all() { [[ ${1-} == "$ACCESS_ALL" ]]; }

# Contenu du fichier, ou le contenu par défaut s'il n'existe pas encore. Toute la lecture
# passe par ici : une installation sans fichier se comporte donc exactement comme avant.
access_cat() {
  if [[ -r $ACCESS_FILE ]]; then
    cat "$ACCESS_FILE"
  else
    echo "V|$ACCESS_VER"
    echo "MODE|ouvert"
  fi
}

# access_rows <TYPE> : les lignes du type demandé, préfixe retiré. Les champs sont
# reconstruits plutôt que découpés par une expression : rien à échapper, donc rien à
# casser, et un libellé contenant « | » resterait entier.
access_rows() {
  access_cat | awk -F'|' -v t="$1" '
    NF && $1 == t {
      out = $2
      for (i = 3; i <= NF; i++) out = out "|" $i
      print out
    }'
}

# Mode courant. Le test porte sur « filtre » et jamais sur « ouvert » : un fichier vide,
# tronqué ou illisible doit laisser passer le trafic, jamais déclencher un filtrage.
access_mode() {
  local m
  m=$(access_cat | awk -F'|' '$1 == "MODE" { print $2; exit }')
  [[ $m == filtre ]] && { echo filtre; return 0; }
  echo ouvert
}

access_group_exists() {
  access_is_all "${1-}" && return 0
  access_rows GROUP | awk -F'|' -v g="${1-}" '$1 == g { f = 1 } END { exit !f }'
}

access_res_exists() {
  access_rows RES | awk -F'|' -v r="${1-}" '$1 == r { f = 1 } END { exit !f }'
}

access_res_target() {
  access_rows RES | awk -F'|' -v r="${1-}" '$1 == r { print $3; exit }'
}

# Libellé d'un groupe, ou son identifiant à défaut.
access_group_label() {
  local l
  access_is_all "${1-}" && { echo "Tous les appareils"; return 0; }
  l=$(access_rows GROUP | awk -F'|' -v g="${1-}" '$1 == g { print $2; exit }')
  echo "${l:-${1-}}"
}

access_res_label() {
  local l
  l=$(access_rows RES | awk -F'|' -v r="${1-}" '$1 == r { print $2; exit }')
  echo "${l:-${1-}}"
}

# Groupes d'un appareil, « tous » compris.
access_device_groups() {
  access_rows MEMBER | awk -F'|' -v d="${1-}" '$1 == d { print $2 }' | sort -u
  echo "$ACCESS_ALL"
}

# Appareils d'un groupe. Pour « tous », la liste complète des appareils configurés.
access_group_devices() {
  if access_is_all "${1-}"; then
    peers_table | awk '{ print $1 }'
    return 0
  fi
  access_rows MEMBER | awk -F'|' -v g="${1-}" '$2 == g { print $1 }' | sort -u
}

# Libellé lisible d'une destination de règle.
access_dest_label() {
  case ${1-} in
    internet) echo "Internet" ;;
    maison)   echo "Le réseau de la maison (${LAN_NET:-?})" ;;
    pi)       echo "Le Raspberry Pi lui-même" ;;
    res:*)    echo "$(access_res_label "${1#res:}") ($(access_res_target "${1#res:}"))" ;;
    grp:*)    echo "Le groupe « $(access_group_label "${1#grp:}") »" ;;
    *)        echo "${1-}" ;;
  esac
}

# Affichage d'une liste de ports. Surtout pas une substitution du tiret : ${p/-/ à }
# transformerait 8000-9000 en « 8000 à 9000 » mais aussi 80,8000-9000 de travers.
access_ports_label() {
  [[ -z ${1-} ]] && { echo "tous les ports"; return 0; }
  echo "${1//,/, }"
}

# emit <ligne...> : imprime chaque argument sur sa propre ligne.
emit() { local x; for x in "$@"; do echo "$x"; done; }

# --- validation de saisie ---------------------------------------------------
# Les identifiants suivent exactement valid_name, pour trois raisons cumulées : la limite
# de 28 caractères des noms de chaînes iptables, le découpage par espaces au moment
# d'appliquer les règles, et le fait qu'un identifiant se retrouve dans des noms de
# chaînes. Les LIBELLÉS, eux, sont libres et accentués : ils passent par json_esc.
access_valid_id() { valid_name "${1-}"; }
# Un libelle est du texte libre, mais access.conf est un format a barres verticales, et
# « RES|<id>|<libelle>|<cible> » place le libelle AU MILIEU : une barre y decalerait la
# cible, et la ressource designerait alors une autre machine. On refuse donc la barre,
# les caracteres de controle, et on borne la longueur.
access_valid_label() {
  local v=${1-}
  (( ${#v} <= 60 )) || return 1
  [[ $v == *"|"* ]] && return 1
  [[ $v == *[[:cntrl:]]* ]] && return 1
  return 0
}

access_valid_proto() {
  case ${1-} in any|tcp|udp|icmp) return 0 ;; *) return 1 ;; esac
}

access_valid_dir() {
  case ${1-} in aller|deux) return 0 ;; *) return 1 ;; esac
}

# Une cible de ressource : une adresse IPv4 ou un réseau IPv4.
access_valid_target() {
  local t=${1-}
  if [[ $t == */* ]]; then
    is_ipv4 "${t%/*}" || return 1
    [[ ${t#*/} =~ ^[0-9]{1,2}$ ]] && (( 10#${t#*/} <= 32 ))
  else
    is_ipv4 "$t"
  fi
}

# Liste de ports : vide (tous les ports), ou des entrées « N » et « N-M » séparées par des
# virgules. Le budget est contrôlé ici parce que « -m multiport » n'accepte que 15 ports,
# une plage en comptant deux : mieux vaut refuser à la saisie qu'échouer à l'application.
access_valid_ports() {
  local p=${1-} item lo hi budget=0
  [[ -z $p ]] && return 0
  for item in ${p//,/ }; do
    if [[ $item =~ ^[0-9]{1,5}$ ]]; then
      valid_port "$item" || return 1
      budget=$(( budget + 1 ))
    elif [[ $item =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[2]}
      valid_port "$lo" && valid_port "$hi" || return 1
      (( 10#$lo < 10#$hi )) || return 1
      budget=$(( budget + 2 ))
    else
      return 1
    fi
  done
  (( budget <= 15 ))
}

# Le sens « deux » n'est filtrable que vers un groupe : c'est le seul cas où les deux
# sens du trafic traversent wg0 et passent donc par le moteur. Vers Internet, la maison ou
# une ressource, le trafic entrant vient de l'autre interface, ne traverse pas la chaîne du
# moteur, et dépend de la box et d'UFW : promettre un filtrage symétrique serait faux.
access_valid_two_way() {   # <sens> <destination>
  [[ ${1-} != deux ]] && return 0
  [[ ${2-} == grp:* ]]
}

# Forme d'une destination. L'existence de la ressource ou du groupe est vérifiée à part :
# ici on ne juge que la syntaxe.
access_valid_dest() {
  case ${1-} in
    internet|maison|pi) return 0 ;;
    res:*) access_valid_id "${1#res:}" ;;
    grp:*) access_valid_id "${1#grp:}" ;;
    *) return 1 ;;
  esac
}

# --- écriture ---------------------------------------------------------------
# access_save : lit le contenu voulu sur l'entrée standard, retire les références mortes,
# ordonne les lignes, et installe le tout atomiquement.
#
# Les références mortes sont PURGÉES à l'écriture plutôt que refusées : un appareil
# supprimé à la main dans wg0.conf ne bloque donc jamais la commande suivante, et
# l'anomalie se résorbe d'elle-même. L'ordre des lignes est fixe pour que le fichier soit
# stable d'une écriture à l'autre, donc lisible, comparable et testable.
access_save() {
  local src type a b c d e f g h name mode=ouvert ver=$ACCESS_VER
  local -A dev=() grp=() res=() seen=()
  local -a groups=() members=() resources=() policies=()
  src=$(cat)

  while read -r name _; do
    [[ -n $name ]] && dev[$name]=1
  done < <(peers_table)

  # Premier passage : ce que le contenu voulu déclare.
  while IFS='|' read -r type a b c d e f g h; do
    case $type in
      V)     [[ -n $a ]] && ver=$a ;;
      MODE)  if [[ $a == filtre ]]; then mode=filtre; else mode=ouvert; fi ;;
      GROUP) if [[ -n $a ]] && ! access_is_all "$a"; then grp[$a]=1; fi ;;
      RES)   [[ -n $a ]] && res[$a]=1 ;;
    esac
  done <<<"$src"

  # Second passage : on retient, en écartant tout ce qui pointe dans le vide.
  while IFS='|' read -r type a b c d e f g h; do
    case $type in
      GROUP)
        [[ -n $a ]] || continue
        access_is_all "$a" && continue            # « tous » est virtuel, jamais écrit
        [[ -n ${seen[G$a]:-} ]] && continue
        seen[G$a]=1
        groups+=("GROUP|$a|$b")
        ;;
      RES)
        [[ -n $a ]] || continue
        [[ -n ${seen[R$a]:-} ]] && continue
        seen[R$a]=1
        resources+=("RES|$a|$b|$c")
        ;;
      MEMBER)
        [[ -n $a && -n $b ]] || continue
        [[ -n ${dev[$a]:-} ]] || continue         # appareil disparu
        [[ -n ${grp[$b]:-} ]] || continue         # groupe disparu
        [[ -n ${seen[M$a/$b]:-} ]] && continue    # doublon
        seen[M$a/$b]=1
        members+=("MEMBER|$a|$b")
        ;;
      POLICY)
        [[ -n $a ]] || continue
        [[ -n ${seen[P$a]:-} ]] && continue
        # La source est toujours un groupe. Une règle qui pointe un groupe disparu est
        # écartée, « tous » étant toujours valide puisqu il est virtuel.
        case $c in
          grp:*) [[ -n ${grp[${c#grp:}]:-} ]] || access_is_all "${c#grp:}" || continue ;;
          *) continue ;;
        esac
        case $d in
          grp:*) [[ -n ${grp[${d#grp:}]:-} ]] || access_is_all "${d#grp:}" || continue ;;
          res:*) [[ -n ${res[${d#res:}]:-} ]] || continue ;;
        esac
        seen[P$a]=1
        policies+=("POLICY|$a|$b|$c|$d|$e|$f|$g|$h")
        ;;
    esac
  done <<<"$src"

  {
    echo "# Généré et relu par wg-pi. Champs séparés par « | ». Après une modification à"
    echo "# la main : sudo wg-pi access check"
    echo "V|$ver"
    echo "MODE|$mode"
    emit "${groups[@]+"${groups[@]}"}" | sort
    emit "${resources[@]+"${resources[@]}"}" | sort
    emit "${members[@]+"${members[@]}"}" | sort
    emit "${policies[@]+"${policies[@]}"}" | sort
  } | atomic_write "$ACCESS_FILE" 600
}

# Crée le fichier s'il n'existe pas, sans rien changer d'autre.
access_init() {
  [[ -f $ACCESS_FILE ]] && return 0
  install -d -m 700 "$STATE_DIR" || return 1
  access_cat | access_save
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

# Explique une ligne qui ne peut pas recevoir de connexion entrante, et quoi demander.
print_cgnat_guide() {
  txt "${BOLD}Pourquoi c’est bloquant${RESET} : un VPN à la maison suppose que vos appareils puissent" \
      "joindre votre box depuis l’extérieur. Ici elle ne l’est pas — soit l’opérateur partage la" \
      "même adresse publique entre plusieurs abonnés, soit un autre routeur se trouve devant" \
      "elle — et aucune redirection de port ne peut y changer quoi que ce soit." ""
  txt "${BOLD}La solution${RESET} : une adresse IPv4 publique, à demander à votre opérateur (souvent gratuit)."
  case ${ISP:-} in
    free)     txt "   Chez Free : espace abonné › Ma Freebox › « Demander une adresse IP fixe V4" \
                  "   full-stack » (gratuit), puis redémarrez la Freebox." ;;
    orange)   txt "   Chez Orange : l’IPv4 publique est la règle sur la fibre et l’ADSL. Ce blocage vient" \
                  "   plutôt d’un accès 4G/5G, ou d’un routeur supplémentaire devant la Livebox." ;;
    sfr|bouygues)
              txt "   Chez $(isp_label "$ISP") : demandez au support une IPv4 publique, non partagée." ;;
    *)        txt "   Box 4G/5G, Starlink, partage de connexion depuis un téléphone : ces accès sont" \
                  "   presque toujours partagés, et l’opérateur n’y propose pas d’IPv4 publique." ;;
  esac
  echo
  txt "wg-pi ne peut pas contourner ça : il configure un serveur WireGuard chez vous, et c’est" \
      "votre ligne qui ne peut pas être jointe depuis l’extérieur." ""
}

print_troubleshooting() {
  txt "" "${BOLD}Pistes à vérifier :${RESET}"
  if [[ $REACH == cgnat ]]; then
    txt "  • ${BOLD}Votre ligne ne peut pas recevoir de connexion depuis Internet${RESET} — c’est la cause" \
        "    la plus probable, et la redirection de la box n’y changera rien." \
        "    ${REACH_WHY:-Votre box n’est pas directement joignable depuis Internet.}" \
        "    → demandez une IPv4 publique à votre opérateur (souvent gratuit)."
  fi
  txt "  • La redirection du port ${BOLD}$WG_PORT en UDP${RESET} vers ${BOLD}$LAN_IP${RESET} est-elle enregistrée sur la box ?" \
      "  • Le téléphone est-il bien en 4G/5G (Wi-Fi coupé) ?" \
      "  • Le tunnel est-il activé dans l'application WireGuard ?" \
      "  • L'adresse « $ENDPOINT » est-elle à jour ? (IP publique actuelle : ${PUBLIC_IP:-inconnue})"
  [[ $ISP == free && $REACH != cgnat ]] && txt "  • Free : votre IPv4 est peut-être partagée (voir « sudo wg-pi box »)."
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
  info "Vérification : votre box peut-elle recevoir une connexion depuis Internet ?…"
  detect_reachability
  case $REACH in
    ok)
      ok "$REACH_WHY" ;;
    cgnat)
      warn "Votre ligne ne peut pas recevoir de connexion depuis Internet."
      txt "   $REACH_WHY" ""
      print_cgnat_guide
      if is_installed; then
        warn "Tant que c’est le cas, le VPN ne sera pas joignable depuis l’extérieur."
      elif interactive; then
        ask_yn "Continuer quand même l’installation ?" n ||
          die "Installation interrompue. Relancez-la quand vous aurez une IPv4 publique."
      else
        die "Ligne sans connexion entrante possible (CGNAT) : installation interrompue."
      fi ;;
    *)
      warn "$REACH_WHY"
      txt "   Le seul test fiable est une vraie connexion depuis la 4G/5G : il a lieu à la dernière étape." ;;
  esac
  echo

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
    free)   txt "Chez Free, l'IP publique est fixe si vous avez l'IPv4 « full-stack » : vous pouvez" \
                "alors l'utiliser directement (le nom xxxx.freeboxos.fr fonctionne aussi)." \
                "→ En IPv4 partagée, elle reste fixe mais seule une petite plage de ports est" \
                "  redirigeable : demandez l'IP fixe V4 full-stack (gratuit) dans l'espace abonné." ;;
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
  local name pub rc tmo
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
  tmo=300
  if [[ $REACH == cgnat ]]; then
    tmo=30
    warn "Rappel : votre ligne ne peut pas recevoir de connexion depuis Internet (voir l’étape 3)."
    txt "   Ce test va donc très probablement échouer, et la box n’y est pour rien."
  fi
  wait_handshake "$pub" "$tmo"
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
    atomic_write "$WG_CONF" <"$tmp"
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
  # La colonne des groupes n'apparaît que si l'utilisateur en a créé : une installation qui
  # n'utilise pas la fonctionnalité voit exactement le tableau d'avant.
  local groupes="" ghdr="" has_groups=0
  [[ -n $(access_rows GROUP) ]] && has_groups=1
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
  (( has_groups )) && ghdr="$(pad GROUPES 20) "
  printf '  %s %s%s %s %s  %s\n' "$(pad APPAREIL 16)" "$ghdr" "$(pad "IP VPN" 13)" \
    "$(pad REÇU 9)" "$(pad ENVOYÉ 9)" "DERNIÈRE CONNEXION"
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
    groupes=""
    if (( has_groups )); then
      # Le groupe « tous » est implicite : l'afficher sur chaque ligne n'apprendrait rien.
      groupes=$(access_device_groups "$name" | grep -v "^$ACCESS_ALL\$" | paste -sd, -)
      groupes="$(pad "${groupes:-—}" 20) "
    fi
    printf '  %s %s%s %s %s  %s\n' "$(pad "$name" 16)" "$groupes" "$(pad "$ip" 13)" \
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
  fi

  detect_reachability
  case $REACH in
    ok)    ok "$REACH_WHY" ;;
    cgnat) fail "$REACH_WHY"
           echo
           print_cgnat_guide
           (( problems++ )) ;;
    *)     warn "$REACH_WHY" ;;
  esac

  local fwgen
  fwgen=$(fw_installed_gen)
  if (( fwgen == FW_GEN )); then
    ok "Règles du pare-feu à jour (génération $FW_GEN)"
  else
    fail "Pare-feu resté en génération $fwgen au lieu de $FW_GEN → sudo wg-pi fw-sync"
    txt "   Une mise à jour venue d'une version antérieure ne pouvait pas le régénérer"         "   toute seule. La commande ci-dessus le fait, sans toucher à vos appareils."
    (( problems++ ))
  fi

  # Le filtrage : son état est lu dans le NOYAU, jamais dans le fichier de réglages. Sans
  # cette section, un utilisateur dont les règles viennent d'être effacées par un
  # « ufw reload » n'apprenait rien en lançant le diagnostic principal.
  if [[ $(access_mode) == filtre ]]; then
    case $(access_kernel_state_safe) in
      actif)
        ok "Filtrage des accès actif"
        access_confirmed || { warn "Filtrage non confirmé : il sera annulé automatiquement → sudo wg-pi access confirm"; (( problems++ )); }
        ;;
      inconnu)
        warn "Filtrage demandé, mais l'état du pare-feu n'a pas pu être lu"
        ;;
      *)
        fail "Filtrage demandé mais NON appliqué : tous vos appareils peuvent se joindre → sudo wg-pi access on"
        (( problems++ ))
        ;;
    esac
    access_dns_warn || (( problems++ ))
  else
    info "Aucun cloisonnement entre appareils (sudo wg-pi access show pour en savoir plus)"
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
  repair_run_mode
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
  # La migration doit tourner dans la NOUVELLE version : on passe par le binaire
  # fraîchement installé, et non depuis ce processus qui exécute encore l'ancien script.
  # WGPI_LOCKED évite que l'enfant retente un flock que ce processus détient déjà :
  # take_lock fait « exec 9> », l'enfant hériterait du descripteur mais créerait une
  # nouvelle description, et le verrou échouerait au lieu d'être reconnu.
  WGPI_LOCKED=1 "$BIN_PATH" fw-sync ||
    warn "Les règles du pare-feu n'ont pas pu être mises à jour : lancez « sudo wg-pi check »."
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
  atomic_write "$WEB_CONF" <"$tmp"
  rm -f "$tmp"
  chmod 600 "$WEB_CONF"
}

# Retire une clé du fichier de configuration du panneau.
web_conf_del() {
  local tmp
  [[ -f $WEB_CONF ]] || return 0
  tmp=$(mktemp) || return 1
  grep -v "^$1=" "$WEB_CONF" 2>/dev/null >"$tmp"
  atomic_write "$WEB_CONF" 600 <"$tmp"
  rm -f "$tmp"
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

# Le mot de passe lu sur l'entrée standard correspond-il à l'empreinte donnée en argument ?
# Sert à refuser un mot de passe de consultation identique à celui de l'administrateur :
# il donnerait silencieusement l'accès complet, puisque l'empreinte admin est testée
# d'abord.
web_password_matches() {
  [[ -n ${1-} ]] || return 1
  python3 -I -c '
import hashlib, hmac, sys
stored = sys.argv[1]
pw = sys.stdin.buffer.read()
try:
    algo, rounds, salt, digest = stored.split("$")
except ValueError:
    sys.exit(1)
if algo != "pbkdf2_sha256":
    sys.exit(1)
calc = hashlib.pbkdf2_hmac("sha256", pw, bytes.fromhex(salt), int(rounds)).hex()
sys.exit(0 if hmac.compare_digest(calc, digest) else 1)' "$1"
}

# web_set_password [--lecture-seule] : enregistre le mot de passe administrateur, ou
# celui du compte de consultation.
web_set_password() {
  local p1="" p2 hash generated=0 ro=0 cle=password quoi="de l'interface web"
  if [[ ${1-} == --lecture-seule ]]; then
    ro=1 cle=password_ro quoi="du compte de consultation"
  fi
  if interactive; then
    while true; do
      printf '%s ' "${BOLD}?${RESET} Mot de passe $quoi (8 caractères minimum) :"
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
  # Un mot de passe de consultation identique à celui de l'administrateur donnerait
  # l'accès complet sans le dire : l'empreinte admin étant vérifiée en premier, le rôle
  # retenu serait « admin ». On refuse plutôt que de laisser passer ce piège silencieux.
  if (( ro )) && printf '%s' "$p1" | web_password_matches "$(web_conf_get password)"; then
    fail "Ce mot de passe est celui de l'administrateur : il donnerait l'accès complet."
    return 1
  fi
  hash=$(printf '%s' "$p1" | web_hash_password) || return 1
  [[ $hash == pbkdf2_sha256\$* ]] || return 1
  web_conf_set "$cle" "$hash"
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
    lecture-seule|consultation)
      take_lock
      [[ -n $(web_conf_get password) ]] || die "Activez d'abord l'interface web : sudo wg-pi web"
      if [[ ${2:-} == off ]]; then
        web_conf_del password_ro
        systemctl try-restart "$WEB_UNIT" >/dev/null 2>&1
        ok "Compte de consultation supprimé."
      else
        web_set_password --lecture-seule || die "Le mot de passe n'a pas pu être enregistré."
        systemctl try-restart "$WEB_UNIT" >/dev/null 2>&1
        ok "Compte de consultation activé."
        txt "   Ce mot de passe permet de ${BOLD}regarder${RESET} : voir les appareils, les débits et les"             "   accès. Il ne permet ni d'ajouter ou supprimer un appareil, ni de récupérer une"             "   configuration ou un QR code — ceux-ci contiennent la clé privée de l'appareil."             "   Pour le retirer : ${BOLD}sudo wg-pi web lecture-seule off${RESET}"
      fi ;;
    *)
      die "Usage : sudo wg-pi web [on|off|password|lecture-seule [off]|port <numéro>]" ;;
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
# Les règles qui concernent un groupe donné, rendues en texte lisible.
access_group_rules() {   # <groupe>
  local id a src dst proto ports sens libelle n=0
  while IFS='|' read -r id a src dst proto ports sens libelle; do
    [[ -n $id ]] || continue
    [[ ${src#grp:} == "$1" ]] || continue
    n=$(( n + 1 ))
    local detail="$proto"
    [[ $proto == any ]] && detail="tous protocoles"
    [[ -n $ports ]] && detail="$detail $(access_ports_label "$ports")"
    [[ $sens == deux ]] && detail="$detail, dans les deux sens"
    printf '   %s %s\n' "$(pad "$([[ $n -eq 1 ]] && echo "peut joindre" || echo "")" 15)" \
      "$(access_dest_label "$dst") ${DIM}($detail)${RESET}"
  done < <(access_rows POLICY)
  (( n == 0 )) && printf '   %s %s\n' "$(pad "peut joindre" 15)" "${DIM}rien : aucune règle ne concerne ce groupe${RESET}"
  return 0
}

# Vue d'ensemble : pour chaque groupe, ses appareils et ce qu'il peut joindre.
# Une liste par groupe plutôt qu'un tableau : les libellés accentués et les noms de
# ressources ont des largeurs trop variables pour tenir en colonnes dans un terminal.
access_show() {
  local mode id libelle devs
  mode=$(access_mode)
  title "Accès"

  if [[ $mode == ouvert ]]; then
    warn "Aucun cloisonnement pour l'instant."
    txt "   Tous vos appareils peuvent joindre le réseau de la maison ($LAN_NET), le Pi" \
        "   lui-même et Internet. Les groupes et les règles ci-dessous sont enregistrés," \
        "   mais ils ne seront appliqués qu'une fois le filtrage activé." ""
  else
    ok "Filtrage actif : seul ce qui est autorisé ci-dessous passe."
    echo
  fi

  while IFS='|' read -r id libelle; do
    [[ -n $id ]] || continue
    devs=$(access_group_devices "$id" | paste -sd' ' -)
    printf '%s\n' "${BOLD}Groupe « $libelle »${RESET} ${DIM}($id)${RESET}"
    printf '   %s %s\n' "$(pad "appareils" 15)" "${devs:-${DIM}aucun${RESET}}"
    access_group_rules "$id"
    echo
  done < <(access_rows GROUP)

  devs=$(access_group_devices "$ACCESS_ALL" | paste -sd' ' -)
  printf '%s\n' "${BOLD}Groupe « Tous les appareils »${RESET} ${DIM}($ACCESS_ALL, automatique)${RESET}"
  printf '   %s %s\n' "$(pad "appareils" 15)" "${devs:-${DIM}aucun${RESET}}"
  access_group_rules "$ACCESS_ALL"
  echo

  # Les appareils qui ne sont dans aucun groupe nommé : utile à voir, parce qu'une fois le
  # filtrage actif ils ne dépendront plus que des règles portant sur « tous ».
  #
  # Mais seulement s'il EXISTE au moins un groupe nommé : sinon cette ligne répète mot pour
  # mot la liste du groupe « tous » affichée juste au-dessus, et n'apprend rien.
  local orphans="" name
  if [[ -n $(access_rows GROUP) ]]; then
    while read -r name _; do
      [[ -n $name ]] || continue
      [[ $(access_device_groups "$name" | grep -vc "^$ACCESS_ALL$") -eq 0 ]] && orphans="$orphans $name"
    done < <(peers_table)
    [[ -n $orphans ]] && txt "${DIM}Appareils dans aucun groupe nommé :$orphans${RESET}" ""
  fi

  access_listening_note
}

# Ce qui écoute sur le Pi et que les appareils du VPN peuvent joindre. C'est la partie
# « les accès derrière » que personne ne voit : un conteneur Docker publié sur 0.0.0.0 est
# joignable par tous les appareils du VPN, et aucune règle de ce fichier ne le filtre tant
# que le moteur n'est pas actif.
access_listening_note() {
  command -v ss >/dev/null 2>&1 || return 0
  local lines
  lines=$(ss -Hltn 2>/dev/null | awk '{ print $4 }' |
    awk -F: '{ print $NF }' | sort -un | paste -sd' ' -)
  [[ -n $lines ]] || return 0
  txt "${BOLD}Ports en écoute sur le Pi${RESET} (joignables depuis le VPN) : $lines"
  txt "${DIM}   Un service publié sur toutes les interfaces, par exemple un conteneur Docker," \
      "   est atteignable par chacun de vos appareils du VPN.${RESET}" ""
  return 0
}

# Vérification de cohérence du fichier d'accès. Rend un code non nul s'il y a un problème.
access_check() {
  local problems=0 id libelle a src dst proto ports sens n
  title "Vérification des accès"

  if [[ -f $ACCESS_FILE ]]; then
    ok "Fichier $ACCESS_FILE présent"
    local m
    m=$(stat -c '%a' "$ACCESS_FILE" 2>/dev/null)
    if [[ $m == 600 ]]; then
      ok "Droits 600"
    else
      fail "Droits $m au lieu de 600 → ils seront remis d'aplomb à la prochaine écriture"
      problems=$(( problems + 1 ))
    fi
  else
    info "Aucun fichier d'accès : aucun groupe, aucune règle, aucun filtrage (comportement d'origine)."
    echo
    return 0
  fi

  kv "Mode" "$(access_mode)"
  kv "État réel (noyau)" "$(access_kernel_state_safe)"
  if [[ $(access_mode) == filtre ]]; then
    if access_confirmed; then
      ok "Configuration confirmée : elle survit aux redémarrages."
    else
      warn "Configuration non confirmée : elle sera annulée automatiquement → sudo wg-pi access confirm"
      problems=$(( problems + 1 ))
    fi
  fi
  access_dns_warn || problems=$(( problems + 1 ))

  n=$(access_rows GROUP | grep -c . || true)
  kv "Groupes" "$n"
  n=$(access_rows RES | grep -c . || true)
  kv "Ressources" "$n"
  n=$(access_rows POLICY | grep -c . || true)
  kv "Règles" "$n"

  # Toutes les ECRITURES de wg-pi passent par access_valid_label. Restent les fichiers
  # ecrits a la main et les sauvegardes anciennes : comme « RES|<id>|<libelle>|<cible> »
  # place le libelle AU MILIEU, une barre verticale y decale la cible, et la ressource
  # designe alors une AUTRE machine sans que rien ne change a l ecran. Le diagnostic est
  # le dernier endroit ou cela peut encore se voir.
  while IFS="|" read -r id libelle a; do
    [[ -n $id ]] || continue
    if ! access_valid_target "$a"; then
      fail "Ressource « $id » : « $a » n'est ni une adresse IP ni un réseau. Le fichier a-t-il été modifié à la main ?"
      problems=$(( problems + 1 ))
    fi
    if ! access_valid_label "$libelle"; then
      fail "Ressource « $id » : libellé invalide (une barre verticale décalerait la cible)."
      problems=$(( problems + 1 ))
    fi
  done < <(access_rows RES)
  while IFS="|" read -r id libelle; do
    [[ -n $id ]] || continue
    access_valid_label "$libelle" || {
      fail "Groupe « $id » : libellé invalide."
      problems=$(( problems + 1 ))
    }
  done < <(access_rows GROUP)

  # Un groupe vide n'est pas une erreur, mais une règle qui s'appuie dessus n'aura aucun
  # effet : autant le dire.
  while IFS='|' read -r id libelle; do
    [[ -n $id ]] || continue
    if [[ -z $(access_group_devices "$id") ]]; then
      if access_rows POLICY | awk -F'|' -v g="grp:$id" '$3 == g { f = 1 } END { exit !f }'; then
        warn "Le groupe « $libelle » ($id) n'a aucun appareil, mais une règle l'utilise comme source : elle ne s'appliquera à personne."
      else
        info "Le groupe « $libelle » ($id) n'a aucun appareil."
      fi
    fi
  done < <(access_rows GROUP)

  # Les références mortes sont purgées à l'écriture : si on en voit encore, le fichier a
  # été modifié à la main depuis.
  while IFS='|' read -r id a src dst proto ports sens libelle; do
    [[ -n $id ]] || continue
    access_valid_proto "$proto" || { fail "Règle $id : protocole « $proto » inconnu."; problems=$(( problems + 1 )); }
    access_valid_dir "$sens" || { fail "Règle $id : sens « $sens » inconnu."; problems=$(( problems + 1 )); }
    access_valid_two_way "$sens" "$dst" || { fail "Règle $id : « deux sens » n'est filtrable que vers un groupe, pas vers « $dst »."; problems=$(( problems + 1 )); }
    access_valid_ports "$ports" || { fail "Règle $id : liste de ports « $ports » invalide (au plus 15 ports, une plage en comptant deux)."; problems=$(( problems + 1 )); }
    access_valid_dest "$dst" || { fail "Règle $id : destination « $dst » invalide."; problems=$(( problems + 1 )); }
    case $dst in
      res:*) access_res_exists "${dst#res:}" || { fail "Règle $id : la ressource « ${dst#res:} » n'existe pas."; problems=$(( problems + 1 )); } ;;
      grp:*) access_is_all "${dst#grp:}" || access_group_exists "${dst#grp:}" || { fail "Règle $id : le groupe « ${dst#grp:} » n'existe pas."; problems=$(( problems + 1 )); } ;;
    esac
  done < <(access_rows POLICY)

  echo
  if (( problems == 0 )); then
    ok "${BOLD}Le fichier d'accès est cohérent.${RESET}"
  else
    warn "$problems problème(s). Une écriture (par exemple sudo wg-pi group list puis une modification) purge les références mortes."
  fi
  echo
  (( problems == 0 ))
}

# ----------------------------------------------------------------------------
# Moteur d'accès : traduction des règles en filtrage effectif.
#
# Le cœur est access_rules_plan, une fonction PURE : elle ne touche pas au noyau, elle
# écrit le plan des règles sur sa sortie standard. Tout ce qui peut être faux dans ce
# palier est donc vérifiable sans root, sans iptables et sans Raspberry Pi — et c'est
# aussi ce que « wg-pi access plan » montre à l'utilisateur avant d'appliquer.
#
# Topologie posée dans le noyau, deux sauts seulement dans les chaînes intégrées :
#
#   filter/FORWARD
#     1  -o wg0 ! -i wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT   (socle)
#     2  -i wg0 -j WGPI-FWD-<tampon>            ← unique point d'entrée du moteur
#     …  -j DOCKER-USER, ufw-*                  (jamais touchés)
#
#   filter/INPUT
#     1  -i wg0 -j WGPI-IN-<tampon>
#
# Les chaînes portent un suffixe de tampon, A ou B : le nouveau jeu est construit à froid
# dans le tampon inactif, qu'aucun saut ne désigne, donc un échec en cours de route n'a
# aucun effet sur le trafic. La bascule insère le nouveau saut DEVANT l'ancien avant de
# retirer l'ancien : il n'y a jamais d'instant sans règles.
#
# Un refus répond REJECT et non DROP : l'accès interdit échoue instantanément
# (« connexion refusée ») au lieu d'une attente de trente secondes. Pour un
# non-technicien, c'est la différence entre « c'est interdit » et « c'est en panne ».
# ----------------------------------------------------------------------------

access_chain_fwd()  { echo "WGPI-FWD-$1"; }
access_chain_in()   { echo "WGPI-IN-$1"; }
access_chain_deny() { echo "WGPI-DENY-$1"; }
access_chain_grp()  { echo "WGPI-S-$2-$1"; }   # $1 = tampon, $2 = groupe

# Fragment de correspondance protocole + ports. « -m multiport » n'accepte que 15 ports,
# une plage en comptant deux : la limite est contrôlée à la saisie par access_valid_ports,
# donc ici on se contente de traduire. Les plages s'écrivent « 8000-9000 » côté
# utilisateur et « 8000:9000 » côté iptables, et la conversion se fait port par port.
access_match_proto() {   # <proto> <ports>
  local proto=$1 ports=${2-} item out=""
  [[ $proto == any ]] && { [[ -z $ports ]] && return 0; proto=tcp; }
  [[ $proto == icmp ]] && { echo "-p icmp"; return 0; }
  out="-p $proto"
  if [[ -n $ports ]]; then
    local list=""
    for item in ${ports//,/ }; do
      if [[ $item == *-* ]]; then
        item="${item%-*}:${item#*-}"
      fi
      [[ -n $list ]] && list="$list,$item"
      [[ -z $list ]] && list="$item"
    done
    out="$out -m multiport --dports $list"
  fi
  echo "$out"
}

# Fragment de correspondance pour une destination. Rend une ligne par cible : une
# destination « groupe » en produit une par appareil du groupe.
access_match_dest() {   # <destination>
  local d=$1 ip name
  case $d in
    internet)
      # « Tout ce qui ne rentre pas dans le tunnel et ne va pas à la maison ». On exclut
      # par « ! -o $WG_IF » et non en nommant l'interface de la box : c'est vrai quel que
      # soit le nombre d'interfaces montantes, et ça exclut bien le trafic entre appareils.
      echo "! -o $WG_IF ! -d $LAN_NET"
      ;;
    maison)
      # L'adresse de destination suffit. Contraindre l'interface de sortie n'ajoute rien et
      # casse la règle dès que la cible est joignable par un autre chemin.
      echo "-d $LAN_NET"
      ;;
    res:*)
      ip=$(access_res_target "${d#res:}")
      [[ -n $ip ]] || return 0
      echo "-d $ip"
      ;;
    grp:*)
      # Un appareil du VPN se joint par son adresse dans le tunnel, et le trafic sort par
      # wg0 : c'est le seul cas où source et destination sont toutes deux dans le VPN.
      while read -r name; do
        [[ -n $name ]] || continue
        ip=$(client_ip "$name")
        [[ -n $ip ]] && echo "-o $WG_IF -d $ip"
      done < <(access_group_devices "${d#grp:}")
      ;;
    pi)
      # Joindre le Pi lui-même relève de la chaîne INPUT, pas de FORWARD : rien à émettre
      # ici. access_rules_plan s'en occupe à part.
      return 0
      ;;
  esac
  return 0
}

# Adresse d'un appareil dans le tunnel.
client_ip() { peers_table | awk -v n="$1" '$1 "" == n "" { print $2; exit }'; }

# Le port SSH, tel que sshd le déclare. En cas de doute on ne devine pas : le secours est
# émis pour TOUS les ports trouvés, et si rien n'est déterminable l'appelant refuse
# d'activer le filtrage plutôt que de poser un garde-fou sur le mauvais port.
access_ssh_ports() {
  local out
  if command -v sshd >/dev/null 2>&1; then
    out=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
    [[ -n $out ]] && { echo "$out"; return 0; }
  fi
  out=$(awk '$1 == "Port" && $2 ~ /^[0-9]+$/ { print $2 }' "$SSHD_CONFIG" 2>/dev/null)
  [[ -n $out ]] && { echo "$out"; return 0; }
  # Aucune configuration lisible : sshd écoute alors sur son défaut.
  if command -v sshd >/dev/null 2>&1 || systemctl is-active --quiet ssh 2>/dev/null; then
    echo 22
  fi
  return 0
}

# Vrai si le port SSH a pu être établi. L'activation du filtrage s'y refuse sinon : poser
# un garde-fou sur le mauvais port serait pire que de ne pas filtrer du tout.
access_ssh_known() { [[ -n $(access_ssh_ports) ]]; }

# access_rules_plan <tampon> [ctdir 0|1] : écrit le plan complet des règles, une
# invocation iptables par ligne, arguments séparés par des espaces.
#
# INVARIANT : aucun argument émis ne contient d'espace. C'est pourquoi le préfixe de
# journal est « wg-pi-refus: » sans espace final. L'appelant peut donc découper chaque
# ligne par mots sans aucun quoting, ce qui évite toute une classe de bogues.
#
# Fonction PURE : elle lit l'état et écrit du texte. Elle ne touche jamais au noyau.
access_rules_plan() {
  local buf=${1:-B} ctdir=${2:-1}
  local fwd deny inch gid name ip g rank
  local pid pact psrc pdst pproto pports psens m frag
  fwd=$(access_chain_fwd "$buf")
  deny=$(access_chain_deny "$buf")
  inch=$(access_chain_in "$buf")

  # --- création des chaînes -------------------------------------------------
  echo "-N $fwd"
  echo "-N $inch"
  echo "-N $deny"
  while IFS='|' read -r gid _; do
    [[ -n $gid ]] || continue
    echo "-N $(access_chain_grp "$buf" "$gid")"
  done < <(access_rows GROUP)
  echo "-N $(access_chain_grp "$buf" "$ACCESS_ALL")"

  # --- chaîne de refus -----------------------------------------------------
  # Le journal est limité en débit : un appareil qui boucle ne doit pas remplir la carte SD.
  echo "-A $deny -m limit --limit 2/min --limit-burst 5 -j LOG --log-prefix wg-pi-refus:"
  # REJECT et non DROP : « connexion refusée » tout de suite, au lieu d'une attente de 30 s.
  echo "-A $deny -p tcp -j REJECT --reject-with tcp-reset"
  echo "-A $deny -j REJECT --reject-with icmp-admin-prohibited"

  # --- chaîne d'entrée FORWARD ---------------------------------------------
  # Le retour d'un flux déjà autorisé entre deux appareils du VPN : il entre ET sort par
  # wg0, donc la règle de socle ne le couvre pas (elle porte « ! -i wg0 »). Sans ceci, le
  # sens « aller » casserait la réponse. Avec --ctdir REPLY on n'autorise QUE la réponse,
  # et non une nouvelle connexion en sens inverse.
  if (( ctdir )); then
    echo "-A $fwd -m conntrack --ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT"
  else
    # xt_conntrack sans --ctdir : on dégrade honnêtement, le sens « aller » devient « deux »
    # pour le pair-à-pair uniquement. wg-pi check le signale.
    echo "-A $fwd -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  fi

  # Un saut par couple (appareil, groupe). Une chaîne de groupe qui ne correspond à rien
  # revient à l'appelante, donc le saut suivant est essayé : l'appartenance à plusieurs
  # groupes cumule naturellement les autorisations.
  while read -r name ip _; do
    [[ -n $name && -n $ip ]] || continue
    while read -r g; do
      [[ -n $g ]] || continue
      echo "-A $fwd -s $ip -m comment --comment wgpi:dev:$name -j $(access_chain_grp "$buf" "$g")"
    done < <(access_device_groups "$name")
  done < <(peers_table)
  echo "-A $fwd -j $deny"

  # --- une chaîne par groupe ----------------------------------------------
  # Les règles sont émises dans l'ordre internet, puis maison et ressources, puis
  # pair-à-pair : le trafic de masse correspond ainsi à la première règle.
  {
    while IFS='|' read -r gid _; do
      [[ -n $gid ]] && echo "$gid"
    done < <(access_rows GROUP)
    echo "$ACCESS_ALL"
  } | while read -r gid; do
    for rank in 1 2 3; do
      while IFS='|' read -r pid pact psrc pdst pproto pports psens _; do
        [[ -n $pid ]] || continue
        [[ $pact == 1 ]] || continue
        [[ ${psrc#grp:} == "$gid" ]] || continue
        : "$psens"   # utilise plus bas, dans la passe « deux sens »
        case $pdst in
          internet) (( rank == 1 )) || continue ;;
          maison|res:*) (( rank == 2 )) || continue ;;
          grp:*) (( rank == 3 )) || continue ;;
          pi) continue ;;   # traité dans INPUT
          *) continue ;;
        esac
        frag=$(access_match_proto "$pproto" "$pports")
        while read -r m; do
          [[ -n $m ]] || continue
          echo "-A $(access_chain_grp "$buf" "$gid") $m $frag -m comment --comment wgpi:pol:$pid -j ACCEPT"
        done < <(access_match_dest "$pdst")
      done < <(access_rows POLICY)
    done

    # Sens « deux » : une règle qui autorise A vers le groupe B dans les deux sens doit
    # aussi permettre à B d'initier vers A. On émet donc le miroir dans la chaîne de B.
    # C'est limité aux destinations « groupe », les seules où les deux sens traversent
    # wg0 et sont donc filtrables ici ; access_valid_two_way le fait respecter à la saisie.
    while IFS='|' read -r pid pact psrc pdst pproto pports psens _; do
      [[ -n $pid ]] || continue
      [[ $pact == 1 ]] || continue
      [[ $psens == deux ]] || continue
      [[ ${pdst#grp:} == "$gid" && $pdst == grp:* ]] || continue
      frag=$(access_match_proto "$pproto" "$pports")
      while read -r m; do
        [[ -n $m ]] || continue
        echo "-A $(access_chain_grp "$buf" "$gid") $m $frag -m comment --comment wgpi:pol:$pid:retour -j ACCEPT"
      done < <(access_match_dest "$psrc")
    done < <(access_rows POLICY)
  done

  # --- chaîne INPUT --------------------------------------------------------
  # SSH est accepté inconditionnellement, et EN TÊTE : ce Pi s'administre souvent à
  # travers le VPN lui-même, et une règle fausse ne doit jamais pouvoir enfermer
  # l'utilisateur dehors. Aucune politique ne peut retirer cette ligne.
  echo "-A $inch -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  while read -r m; do
    [[ -n $m ]] || continue
    echo "-A $inch -p tcp --dport $m -m comment --comment wgpi:secours:ssh -j ACCEPT"
  done < <(access_ssh_ports)
  # Le port du VPN et l'ICMP restent toujours joignables : sans eux, plus de tunnel ni de
  # diagnostic possible.
  echo "-A $inch -p udp --dport $WG_PORT -m comment --comment wgpi:secours:vpn -j ACCEPT"
  echo "-A $inch -p icmp -m comment --comment wgpi:secours:ping -j ACCEPT"

  while IFS='|' read -r pid pact psrc pdst pproto pports _ _; do
    [[ -n $pid ]] || continue
    [[ $pact == 1 ]] || continue
    [[ $pdst == pi ]] || continue
    frag=$(access_match_proto "$pproto" "$pports")
    while read -r name; do
      [[ -n $name ]] || continue
      ip=$(client_ip "$name")
      [[ -n $ip ]] || continue
      echo "-A $inch -s $ip $frag -m comment --comment wgpi:pol:$pid -j ACCEPT"
    done < <(access_group_devices "${psrc#grp:}")
  done < <(access_rows POLICY)

  # JAMAIS d'ACCEPT terminal ici : la chaîne revient, et c'est UFW ou la politique par
  # défaut qui tranche. Un ACCEPT final court-circuiterait UFW et exposerait tous les
  # services du Pi, conteneurs Docker publiés sur 0.0.0.0 compris, à tous les appareils.
  echo "-A $inch -j RETURN"
  return 0
}

# --- lecture de l'état réel, dans le noyau ----------------------------------
# JAMAIS dans un fichier de réglages : un panneau qui annonce « filtrage actif » sur la
# foi d'un fichier mentirait dès qu'un « ufw reload » ou un redémarrage de Docker a effacé
# les chaînes. Tout ce qui est affiché à l'utilisateur vient d'ici.

# Tampon actuellement désigné par le saut dans FORWARD, ou rien.
access_active_buffer() {
  local b
  for b in A B; do
    if iptables -w -C FORWARD -i "$WG_IF" -j "$(access_chain_fwd "$b")" 2>/dev/null; then
      echo "$b"
      return 0
    fi
  done
  return 1
}

access_other_buffer() { if [[ ${1-} == A ]]; then echo B; else echo A; fi; }

# actif | incoherent | inactif. « incoherent » signifie que des chaînes existent mais que
# le chemin n'est pas complet : c'est le cas après qu'un autre outil a touché au pare-feu.
access_kernel_state() {
  local b fwd deny last blanket=0
  if ! b=$(access_active_buffer); then
    echo inactif
    return 0
  fi
  fwd=$(access_chain_fwd "$b")
  deny=$(access_chain_deny "$b")
  last=$(iptables -w -S "$fwd" 2>/dev/null | tail -n1)
  # La chaîne d'entrée doit se terminer par le saut vers le refus : sans lui, tout ce qui
  # n'a pas correspondu retombe dans la politique par défaut, donc passe.
  if [[ $last != *"-j $deny" ]]; then
    echo incoherent
    return 0
  fi
  # Et l'acceptation générale ne doit plus être là, sinon elle court-circuite le moteur.
  iptables -w -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null && blanket=1
  if (( blanket )); then
    echo incoherent
    return 0
  fi
  echo actif
  return 0
}

# Le saut est-il en PREMIÈRE position de FORWARD ? Docker, en redémarrant, insère ses
# propres règles en tête : la chaîne existe toujours mais n'est plus consultée en premier.
# « iptables -C » réussirait quand même, d'où cette vérification de position.
access_jump_first() {
  local b first
  b=$(access_active_buffer) || return 1
  first=$(iptables -w -S FORWARD 2>/dev/null | awk 'NR == 2 { print; exit }')
  [[ $first == *"-j $(access_chain_fwd "$b")" ]]
}

# --- sonde des fonctions du noyau -------------------------------------------
# « --ctdir » est sondé dans une chaîne jetable qu'aucun saut ne désigne : aucun paquet ne
# la traverse, donc aucun effet sur le trafic. Le résultat est mis en cache par version de
# noyau, pour que la sonde soit refaite après une mise à jour du noyau.
access_ctdir_supported() {
  local cache rc=1
  cache="/run/wg-pi-ctdir-$(uname -r 2>/dev/null)"
  if [[ -r $cache ]]; then
    [[ $(cat "$cache" 2>/dev/null) == 1 ]]
    return
  fi
  if iptables -w -N WGPI-PROBE 2>/dev/null; then
    if iptables -w -A WGPI-PROBE -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT 2>/dev/null; then
      rc=0
    fi
    iptables -w -F WGPI-PROBE 2>/dev/null
    iptables -w -X WGPI-PROBE 2>/dev/null
  fi
  echo $(( 1 - rc )) > "$cache" 2>/dev/null
  return $rc
}

# --- instantané et annulation automatique -----------------------------------
# L'instantané est pris AVANT la première écriture, jamais au début de l'application :
# sinon il capturerait un état déjà abîmé.
access_snapshot() {
  install -d -m 700 "$(dirname "$ACCESS_SNAP")" 2>/dev/null
  iptables-save > "$ACCESS_SNAP" 2>/dev/null && [[ -s $ACCESS_SNAP ]]
}

access_rollback_now() {
  [[ -s $ACCESS_SNAP ]] || return 1
  iptables-restore < "$ACCESS_SNAP" 2>>"$LOG_FILE"
}

# Arme le retour en arrière automatique. Seule une confirmation humaine le désarme :
# « --boot » et « --no-confirm » ne valident rien, et au démarrage ils RÉARMENT, parce que
# le minuteur transitoire ne survit pas au redémarrage et que le réflexe de quelqu'un qui
# vient de se couper l'accès est justement de redémarrer.
access_arm_rollback() {
  local delay=${1:-120}
  command -v systemd-run >/dev/null 2>&1 || return 1
  systemctl stop "$ACCESS_ROLLBACK_UNIT.timer" >/dev/null 2>&1
  systemd-run --quiet --collect --unit="$ACCESS_ROLLBACK_UNIT" --on-active="$delay" \
    "$BIN_PATH" access-rollback >/dev/null 2>&1
}

access_rollback_armed() {
  systemctl is-active --quiet "$ACCESS_ROLLBACK_UNIT.timer" 2>/dev/null
}

access_disarm_rollback() {
  systemctl stop "$ACCESS_ROLLBACK_UNIT.timer" >/dev/null 2>&1
  systemctl stop "$ACCESS_ROLLBACK_UNIT.service" >/dev/null 2>&1
  rm -f "$ACCESS_SNAP"
  return 0
}

# --- construction et démontage des chaînes ----------------------------------
# Chaînes d'un tampon réellement présentes dans le noyau.
access_buffer_chains() {   # <tampon>
  iptables -w -S 2>/dev/null |
    awk -v suf="-$1" '$1 == "-N" && $2 ~ ("^WGPI-.*" suf "$") { print $2 }'
}

# Vide puis supprime les chaînes d'un tampon. « -X » échoue tant qu'un saut désigne encore
# la chaîne : c'est exactement la protection voulue, on ignore donc l'échec plutôt que de
# forcer. Une chaîne vide mais encore désignée tuerait SSH et le panneau.
access_teardown() {   # <tampon>
  local c
  while read -r c; do
    [[ -n $c ]] && iptables -w -F "$c" 2>/dev/null
  done < <(access_buffer_chains "$1")
  while read -r c; do
    [[ -n $c ]] && iptables -w -X "$c" 2>/dev/null
  done < <(access_buffer_chains "$1")
  return 0
}

# Exécute un plan. Le plan garantit qu'aucun argument ne contient d'espace : le découpage
# par mots est donc sûr, et c'est ce qui permet de se passer de tout quoting ici.
access_run_plan() {
  local line rc=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # shellcheck disable=SC2086
    if ! iptables -w $line 2>>"$LOG_FILE"; then
      fail "Règle refusée par le noyau : iptables $line"
      rc=1
      break
    fi
  done
  return $rc
}

# --- bascule ----------------------------------------------------------------
# Le nouveau saut est inséré DEVANT l'ancien, puis l'ancien est retiré : il n'y a jamais
# d'instant où aucune règle ne s'applique. L'acceptation générale du trafic venant du VPN
# est retirée en dernier, et en boucle, parce qu'un rechargement antérieur a pu la poser
# plusieurs fois.
access_switch() {   # <nouveau tampon> [ancien tampon]
  local new=$1 old=${2-} i
  iptables -w -I FORWARD 1 -i "$WG_IF" -j "$(access_chain_fwd "$new")" || return 1
  iptables -w -I INPUT 1 -i "$WG_IF" -j "$(access_chain_in "$new")" || return 1
  # Retirée en boucle, parce qu'un rechargement antérieur a pu la poser plusieurs fois,
  # mais BORNÉE : une boucle qui ne s'arrête que sur l'échec d'une commande externe est une
  # boucle infinie en puissance, et celle-ci tournerait dans du code de pare-feu.
  i=0
  while (( i < 10 )) && iptables -w -D FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null; do
    i=$(( i + 1 ))
  done
  if [[ -n $old && $old != "$new" ]]; then
    iptables -w -D FORWARD -i "$WG_IF" -j "$(access_chain_fwd "$old")" 2>/dev/null
    iptables -w -D INPUT -i "$WG_IF" -j "$(access_chain_in "$old")" 2>/dev/null
    access_teardown "$old"
  fi
  return 0
}

# Retire tout : les sauts, les chaînes des deux tampons, et remet l'acceptation générale.
access_unswitch() {
  local b
  for b in A B; do
    iptables -w -D FORWARD -i "$WG_IF" -j "$(access_chain_fwd "$b")" 2>/dev/null
    iptables -w -D INPUT -i "$WG_IF" -j "$(access_chain_in "$b")" 2>/dev/null
  done
  iptables -w -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null ||
    iptables -w -I FORWARD 1 -i "$WG_IF" -j ACCEPT
  for b in A B; do
    access_teardown "$b"
  done
  return 0
}

# --- application ------------------------------------------------------------
# cmd_access_apply [--boot] [--remove] : construit le jeu de règles dans le tampon
# inactif, vérifie qu'il est accepté par le noyau, puis bascule. Un échec en cours de
# construction n'a aucun effet sur le trafic, puisque aucun saut ne désigne encore ces
# chaînes.
cmd_access_apply() {
  load_settings
  local a boot=0 remove=0 sans_filet=0 modifie=0 ctdir=1 cur new filet=1
  for a in "$@"; do
    case $a in
      --boot)        boot=1 ;;
      --remove)      remove=1 ;;
      --sans-filet)  sans_filet=1 ;;
      --modifie)     modifie=1 ;;
      *) die "Option inconnue : $a" ;;
    esac
  done
  [[ -n ${WGPI_LOCKED:-} ]] || take_lock

  if (( remove )); then
    access_unswitch
    access_disarm_rollback
    return 0
  fi

  [[ $(access_mode) == filtre ]] || { access_unswitch; return 0; }

  # Sans aucune règle, appliquer le filtrage couperait tout : le moteur n'autorise que
  # ce qui est écrit. « access on » refuse déjà ce cas, mais il n'est pas le seul
  # chemin — le panneau web réapplique après chaque écriture, et supprimer la dernière
  # règle arrivait donc ici sans garde-fou, coupant tous les appareils d'un coup.
  if [[ $(access_policy_count) -eq 0 ]]; then
    die "Aucune règle enregistrée : appliquer le filtrage couperait tous vos appareils.
Posez une règle, ou coupez le filtrage : sudo wg-pi access off"
  fi

  # Le garde-fou SSH n'a de valeur que si l'on connaît le bon port. Dans le doute, on
  # refuse de filtrer : poser un secours sur le mauvais port est pire que ne pas filtrer.
  access_ssh_known || die "Port SSH indéterminable : le filtrage n'est pas appliqué (sécurité). Vérifiez /etc/ssh/sshd_config."

  access_ctdir_supported || ctdir=0

  cur=$(access_active_buffer) || cur=""
  new=$(access_other_buffer "${cur:-B}")

  # Construction à froid dans le tampon inactif.
  access_teardown "$new"
  if ! access_rules_plan "$new" "$ctdir" | access_run_plan; then
    access_teardown "$new"
    die "Les règles ont été refusées par le noyau : rien n'a été changé. Détails : $LOG_FILE"
  fi

  # L'instantané est pris maintenant : juste avant la première écriture qui touche au
  # trafic, et donc sur un état encore sain.
  access_snapshot || filet=0

  # Au démarrage, le minuteur n'est réarmé que si la configuration n'a JAMAIS été
  # confirmée. Sinon le filtrage se désactiverait tout seul après chaque redémarrage passé
  # inaperçu plus de deux minutes — un filet de sécurité qui se referme sur l'utilisateur
  # n'en est pas un.
  #
  # Attention : on saute seulement l'ARMEMENT, jamais la bascule qui suit. Sortir ici
  # laisserait les chaînes construites mais aucun saut pour y mener, donc un filtrage
  # annoncé et inexistant.
  # Une modification efface la validation : la configuration appliquée n'est plus celle
  # qu'un humain avait approuvée, et le filet doit jouer pour la NOUVELLE.
  (( modifie )) && access_set_confirmed 0

  if access_confirmed; then
    # Configuration déjà validée par un humain ET inchangée : pas de minuteur. Le cas
    # visé est la réapplication à l'identique, après qu'un « ufw reload » ou un
    # redémarrage de Docker a effacé les chaînes — redemander une confirmation pour
    # un jeu de règles qui tournait déjà serait du bruit, et personne n'y répondrait.
    :
  elif (( sans_filet )); then
    warn "Aucune annulation automatique : vous avez demandé à passer outre."
  elif (( ! filet )); then
    # Sans instantané, le minuteur n'aurait RIEN à restaurer. L'armer quand même
    # donnerait un filet qui n'existe pas, et « access-rollback » affirmerait plus tard
    # une restauration qui n'a pas eu lieu. Mieux vaut refuser que mentir.
    if (( boot )); then
      warn "Instantané du pare-feu impossible : aucune annulation automatique disponible."
    else
      access_teardown "$new"
      die "Instantané du pare-feu impossible : le retour en arrière ne peut pas être garanti,
le filtrage n'est donc pas appliqué.
Pour forcer malgré tout, en acceptant le risque de perdre l'accès : sudo wg-pi access on --sans-filet"
    fi
  elif ! access_arm_rollback 120; then
    if (( boot )); then
      warn "Minuteur d'annulation indisponible : les règles de secours SSH restent le seul filet."
    else
      access_teardown "$new"
      die "Impossible d'armer l'annulation automatique (systemd-run). Filtrage non appliqué.
Pour forcer malgré tout, en acceptant le risque de perdre l'accès : sudo wg-pi access on --sans-filet"
    fi
  else
    # INVARIANT : un minuteur armé implique une configuration non confirmée. Sans lui,
    # « confirme » pouvait rester vrai alors qu'une annulation était en vol : le panneau
    # web n'affichait pas son bandeau, personne ne confirmait, et deux minutes plus tard
    # tout le cloisonnement tombait — pour une simple modification de règle.
    access_set_confirmed 0
  fi

  if ! access_switch "$new" "$cur"; then
    access_rollback_now
    access_teardown "$new"
    die "Bascule impossible : l'état précédent a été restauré."
  fi
  return 0
}

# Appelé par le minuteur : remet l'état d'avant si personne n'a confirmé.
cmd_access_rollback() {
  load_settings
  [[ -s $ACCESS_SNAP ]] || return 0
  warn "Aucune confirmation reçue : retour à l'état précédent du pare-feu."
  access_rollback_now
  # Le mode repasse à ouvert, sinon le prochain démarrage réappliquerait les règles qui
  # viennent justement de couper l'accès.
  access_cat | access_set_mode_line ouvert | access_save
  access_set_confirmed 0
  # L'instantané pris au démarrage ne contient PAS l'acceptation générale du trafic du VPN,
  # puisque le pare-feu l'avait omise en mode filtré. Le restaurer seul laisserait donc un
  # tunnel qui monte et un accès mort là où la politique par défaut de FORWARD est DROP,
  # c'est-à-dire dès que Docker ou UFW est présent. On repasse explicitement par le
  # démontage, qui garantit son retour.
  access_unswitch
  rm -f "$ACCESS_SNAP"
  return 0
}

# La confirmation est persistée dans un fichier, et non en mémoire : sans cela, le minuteur
# d'annulation serait réarmé à CHAQUE démarrage du Pi, et le filtrage se désactiverait tout
# seul dès qu'un redémarrage passerait inaperçu plus de deux minutes. Le fichier vit dans
# STATE_DIR, donc il est inclus dans les sauvegardes.
access_confirmed() { [[ -f $ACCESS_CONFIRMED ]]; }
access_set_confirmed() {
  if [[ ${1:-0} == 1 ]]; then
    install -d -m 700 "$STATE_DIR" 2>/dev/null
    : > "$ACCESS_CONFIRMED" && chmod 600 "$ACCESS_CONFIRMED"
  else
    rm -f "$ACCESS_CONFIRMED"
  fi
  return 0
}

# Une règle « Internet seulement » exclut le réseau de la maison, donc aussi la box. Si le
# DNS des appareils EST la box — c'est le choix proposé par défaut à l'installation — plus
# aucun nom ne se résout : l'utilisateur a « Internet » et croit que rien ne marche. On le
# prévient avant d'appliquer, avec la commande exacte qui répare.
access_dns_blocked_groups() {
  local dns gid glabel ok_dns
  # Le premier DNS configuré qui appartient au réseau de la maison, s'il y en a un.
  for dns in ${CLIENT_DNS//,/ }; do
    dns=${dns// /}
    is_ipv4 "$dns" || continue
    [[ -n ${LAN_NET:-} ]] || continue
    cidr_overlap "$dns/32" "$LAN_NET" && break
    dns=""
  done
  [[ -n ${dns:-} ]] && is_ipv4 "$dns" || return 0

  while IFS='|' read -r gid glabel; do
    [[ -n $gid ]] || continue
    # Le groupe a-t-il une règle « internet » ?
    access_rows POLICY | awk -F'|' -v g="grp:$gid" '$2 == 1 && $3 == g && $4 == "internet" { f = 1 } END { exit !f }' || continue
    # Et une règle qui couvre ce DNS ?
    ok_dns=0
    access_rows POLICY | awk -F'|' -v g="grp:$gid" '$2 == 1 && $3 == g { print $4 }' |
      while read -r d; do
        case $d in
          maison) echo couvert; break ;;
          res:*) is_ipv4 "$(access_res_target "${d#res:}")" &&
                 cidr_overlap "$dns/32" "$(access_res_target "${d#res:}")/32" && { echo couvert; break; } ;;
        esac
      done | grep -q couvert && ok_dns=1
    (( ok_dns )) || printf '%s|%s|%s\n' "$gid" "$glabel" "$dns"
  done < <(access_rows GROUP)
  return 0
}

access_dns_warn() {
  local gid glabel dns n=0
  while IFS='|' read -r gid glabel dns; do
    [[ -n $gid ]] || continue
    n=$(( n + 1 ))
    if (( n == 1 )); then
      warn "Attention au DNS : « Internet seulement » exclut aussi votre box."
    fi
    txt "   Le groupe « $glabel » a Internet mais ne peut pas joindre son DNS ($dns) :" \
        "   aucun nom de site ne s'y résoudra. Pour le réparer :" \
        "     ${BOLD}sudo wg-pi resource add dns $dns --libelle=\"Le DNS de la box\"${RESET}" \
        "     ${BOLD}sudo wg-pi access allow $gid res:dns --proto=udp --ports=53${RESET}" \
        "     ${BOLD}sudo wg-pi access allow $gid res:dns --proto=tcp --ports=53${RESET}"
  done < <(access_dns_blocked_groups)
  (( n == 0 ))
}

# --- activation et désactivation --------------------------------------------
# Nombre de règles enregistrées et actives.
access_policy_count() { access_rows POLICY | awk -F'|' '$2 == 1' | grep -c . || true; }

cmd_access_on() {
  local a sans_filet=0
  for a in "$@"; do
    case $a in
      --sans-filet) sans_filet=1 ;;
      *) die "Option inconnue : $a" ;;
    esac
  done
  take_lock
  if [[ $(access_mode) == filtre ]]; then
    local etat
    etat=$(access_kernel_state)
    if [[ $etat == actif ]]; then
      info "Le filtrage est déjà actif."
      return 0
    fi
    # Le filtrage est demandé mais absent du pare-feu. C'est le cas après qu'un autre outil
    # a effacé les chaînes : un « ufw reload », un redémarrage de Docker. Il faut
    # RÉAPPLIQUER, et surtout pas sortir en annonçant que tout va bien — c'est la commande
    # que le dépannage conseille dans cette situation précise.
    warn "Le filtrage est demandé mais n'est pas appliqué (état lu dans le noyau : $etat)."
    info "Réapplication des règles…"
    local WGPI_LOCKED=1
    cmd_access_apply || return 1
    ok "${BOLD}Filtrage réappliqué.${RESET} État lu dans le noyau : $(access_kernel_state)."
    return 0
  fi

  # Sans aucune règle, activer le filtrage couperait tout : le moteur n'autorise que ce
  # qui est écrit. On refuse plutôt que de produire un VPN muet.
  if [[ $(access_policy_count) -eq 0 ]]; then
    fail "Aucune règle enregistrée : activer le filtrage couperait tous vos appareils."
    txt "" "Posez d'abord une base large, que vous resserrerez ensuite :" \
        "  ${BOLD}sudo wg-pi access allow tous internet${RESET}" \
        "  ${BOLD}sudo wg-pi access allow tous maison${RESET}" \
        "  ${BOLD}sudo wg-pi access allow tous pi${RESET}" ""
    return 1
  fi

  # L'IPv6 du tunnel n'est pas filtrée par ce moteur. Si elle est routée vers Internet,
  # une règle du type « invités : Internet seulement » serait contournable en IPv6 : la
  # promesse serait fausse, et une promesse de cloisonnement fausse est pire que pas de
  # cloisonnement du tout.
  if (( IPV6_NAT )); then
    fail "Votre Pi route l'IPv6 vers Internet : le filtrage ne couvrirait que l'IPv4."
    txt "" "Vos règles seraient contournables en IPv6, donc wg-pi refuse de les annoncer" \
        "comme appliquées. Deux issues :" \
        "  • désactiver l'IPv6 dans le tunnel, puis relancer l'activation ;" \
        "  • attendre la prise en charge de l'IPv6 par le moteur d'accès." ""
    return 1
  fi

  # Le pare-feu doit être de la génération qui sait omettre l'acceptation générale.
  fw_sync || die "Le pare-feu n'a pas pu être mis à jour : filtrage non activé."

  # Toute activation repart d'une configuration NON confirmée : le filet de sécurité doit
  # jouer pour la nouvelle configuration, pas hériter d'une confirmation ancienne.
  access_set_confirmed 0
  access_cat | access_set_mode_line filtre | access_save || die "Écriture de $ACCESS_FILE impossible."

  # Avertissement sur le DNS avant d'appliquer : une fois le filtrage en place, l'utilisateur
  # verrait « Internet » marcher et tous les noms de sites échouer, sans comprendre pourquoi.
  access_dns_warn || echo

  local -a opts=()
  if (( sans_filet )); then
    warn "Activation sans annulation automatique, à votre demande."
    opts+=(--sans-filet)
  fi
  if ! cmd_access_apply "${opts[@]+"${opts[@]}"}"; then
    access_cat | access_set_mode_line ouvert | access_save
    return 1
  fi

  echo
  ok "${BOLD}Filtrage actif.${RESET} État lu dans le noyau : $(access_kernel_state)."
  if access_rollback_armed; then
    warn "${BOLD}Vérifiez tout de suite que vos appareils fonctionnent encore.${RESET}"
    txt_confirm
  else
    txt "   Aucune annulation automatique n'est armée : vérifiez vos appareils, et en cas" \
        "   de problème lancez ${BOLD}sudo wg-pi access off${RESET}."
  fi
  echo
  return 0
}

txt_confirm() {
  txt "   Sans confirmation de votre part, tout revient à l'état précédent dans 2 minutes." \
      "   Si tout va bien : ${BOLD}sudo wg-pi access confirm${RESET}" \
      "   Si quelque chose ne va plus : ${BOLD}sudo wg-pi access off${RESET} (ou attendez)."
}

cmd_access_off() {
  take_lock
  access_cat | access_set_mode_line ouvert | access_save || die "Écriture de $ACCESS_FILE impossible."
  access_set_confirmed 0
  local WGPI_LOCKED=1
  cmd_access_apply --remove
  ok "Filtrage désactivé : tous vos appareils peuvent à nouveau tout joindre."
  txt "   Vos groupes et vos règles sont conservés : ${BOLD}sudo wg-pi access on${RESET} les réappliquera."
  echo
  return 0
}

cmd_access_confirm() {
  take_lock
  if ! access_rollback_armed && [[ ! -s $ACCESS_SNAP ]]; then
    # Aucune annulation en vol. Si le filtrage tourne pourtant sans être marqué comme
    # confirmé, c'est l'état enregistré qui est en retard sur la réalité : on le remet
    # d'aplomb. Sans cela, le bandeau du panneau web resterait affiché indéfiniment et
    # son bouton ne pourrait rien y changer.
    if [[ $(access_mode) == filtre ]] && ! access_confirmed; then
      access_set_confirmed 1
      ok "Configuration confirmée : aucune annulation n'était en attente."
      return 0
    fi
    info "Rien à confirmer : aucune annulation n'est en attente."
    return 0
  fi
  access_disarm_rollback
  access_set_confirmed 1
  ok "Configuration confirmée : elle ne sera plus annulée automatiquement, redémarrages compris."
  echo
  return 0
}

# Essai à blanc. Les règles sont réellement posées dans le tampon inactif, qu'aucun saut
# ne désigne : aucun paquet ne les traverse, et c'est le seul moyen fiable de détecter un
# module de noyau manquant. Puis tout est démonté.
cmd_access_plan() {
  load_settings
  local ctdir=1 buf plan rc=0
  title "Essai à blanc des règles d'accès"

  if [[ $(access_policy_count) -eq 0 ]]; then
    warn "Aucune règle active : le filtrage refuserait tout."
    echo
  fi

  if command -v iptables >/dev/null 2>&1 && [[ $(id -u) == 0 ]]; then
    access_ctdir_supported || { ctdir=0; warn "Ce noyau ne connaît pas « --ctdir » : le sens « aller » sera dégradé en « deux » pour le pair-à-pair."; }
  else
    info "iptables n'est pas interrogeable ici : le plan est affiché sans être essayé."
  fi

  plan=$(access_rules_plan "T" "$ctdir")
  printf '%s\n' "$plan" | sed 's/^/   iptables /'
  echo
  kv "Règles à poser" "$(printf '%s\n' "$plan" | grep -c .)"

  if command -v iptables >/dev/null 2>&1 && [[ $(id -u) == 0 ]]; then
    take_lock
    access_teardown T
    if printf '%s\n' "$plan" | access_run_plan; then
      ok "Toutes les règles sont acceptées par le noyau."
    else
      fail "Au moins une règle est refusée par ce noyau : l'activation échouerait."
      rc=1
    fi
    access_teardown T
  fi
  echo
  return $rc
}

# --- vue d'accès pour le panneau web ----------------------------------------
# Le panneau n'évalue RIEN : il affiche ce que cette fonction a résolu. C'est la
# contrainte la plus importante de tout le palier — si l'évaluation était dupliquée en
# JavaScript, les deux implémentations dériveraient et la vue finirait par annoncer un
# cloisonnement que le pare-feu n'applique pas.
#
# Tous les libellés passent par json_esc : ils viennent de l'utilisateur, et un guillemet
# non échappé rendrait /api/state invalide, donc le panneau entier blanc.

# État réel, ou « inconnu » quand on ne peut pas interroger le noyau. Surtout pas
# « inactif » dans ce cas : ce serait affirmer une absence de filtrage non vérifiée.
access_kernel_state_safe() {
  command -v iptables >/dev/null 2>&1 || { echo inconnu; return 0; }
  iptables -w -S FORWARD >/dev/null 2>&1 || { echo inconnu; return 0; }
  access_kernel_state
}

# Les ports en écoute sur le Pi, joignables depuis le VPN. C'est la partie « les accès
# derrière » que personne ne voit : un conteneur publié sur 0.0.0.0 est atteignable par
# tous les appareils du VPN.
access_listening_ports() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -Hltn 2>/dev/null | awk '{ print $4 }' | awk -F: '{ print $NF }' |
    awk '$0 ~ /^[0-9]+$/' | sort -un
}

# Flux d'un groupe, en JSON. La source de vérité est access_rows POLICY, exactement comme
# pour le générateur de règles.
access_json_flows() {   # <groupe>
  local pid pact psrc pdst pproto pports psens plabel first=1
  printf '['
  while IFS='|' read -r pid pact psrc pdst pproto pports psens plabel; do
    [[ -n $pid ]] || continue
    [[ $pact == 1 ]] || continue
    [[ ${psrc#grp:} == "$1" ]] || continue
    (( first )) || printf ','
    first=0
    printf '{"id":"%s","dest":"%s","label":"%s","proto":"%s","ports":"%s","sens":"%s","titre":"%s"}' \
      "$(json_esc "$pid")" "$(json_esc "$pdst")" "$(json_esc "$(access_dest_label "$pdst")")" \
      "$(json_esc "$pproto")" "$(json_esc "$pports")" "$(json_esc "$psens")" "$(json_esc "$plabel")"
  done < <(access_rows POLICY)
  printf ']'
}

access_json_devices() {   # <groupe>
  local d first=1
  printf '['
  while read -r d; do
    [[ -n $d ]] || continue
    (( first )) || printf ','
    first=0
    printf '"%s"' "$(json_esc "$d")"
  done < <(access_group_devices "$1")
  printf ']'
}

access_json() {
  local gid glabel rid rlabel rtarget p first=1
  printf '{"mode":"%s","noyau":"%s","confirme":%s,"groupes":[' \
    "$(access_mode)" "$(access_kernel_state_safe)" \
    "$(if access_confirmed; then echo true; else echo false; fi)"
  while IFS='|' read -r gid glabel; do
    [[ -n $gid ]] || continue
    (( first )) || printf ','
    first=0
    printf '{"id":"%s","libelle":"%s","auto":false,"appareils":%s,"flux":%s}' \
      "$(json_esc "$gid")" "$(json_esc "$glabel")" \
      "$(access_json_devices "$gid")" "$(access_json_flows "$gid")"
  done < <(access_rows GROUP)
  (( first )) || printf ','
  printf '{"id":"%s","libelle":"Tous les appareils","auto":true,"appareils":%s,"flux":%s}' \
    "$ACCESS_ALL" "$(access_json_devices "$ACCESS_ALL")" "$(access_json_flows "$ACCESS_ALL")"

  printf '],"ressources":['
  first=1
  while IFS='|' read -r rid rlabel rtarget; do
    [[ -n $rid ]] || continue
    (( first )) || printf ','
    first=0
    printf '{"id":"%s","libelle":"%s","cible":"%s"}' \
      "$(json_esc "$rid")" "$(json_esc "$rlabel")" "$(json_esc "$rtarget")"
  done < <(access_rows RES)

  printf '],"ecoute":['
  first=1
  while read -r p; do
    [[ -n $p ]] || continue
    (( first )) || printf ','
    first=0
    printf '%s' "$p"
  done < <(access_listening_ports)
  printf ']}'
}

# Groupes d'un appareil, en tableau JSON.
access_json_device_groups() {   # <appareil>
  local g first=1
  printf '['
  while read -r g; do
    [[ -n $g ]] || continue
    (( first )) || printf ','
    first=0
    printf '"%s"' "$(json_esc "$g")"
  done < <(access_device_groups "$1")
  printf ']'
}

# --- filtres de mutation ----------------------------------------------------
# Chaque mutation lit le fichier, le filtre, ajoute ses lignes, et repasse le tout à
# access_save qui purge et installe atomiquement. Les filtres passent par awk plutôt que
# par grep -v : un grep qui ne retient aucune ligne sort en échec, ce qui ferait tomber
# toute la chaîne sous « pipefail ».
access_drop() {        # <TYPE> <identifiant> : retire les lignes de ce type portant cet identifiant
  awk -F'|' -v t="$1" -v k="$2" '!(NF && $1 == t && $2 == k)'
}

access_drop_member() { # <appareil> [groupe] : sans groupe, toutes les appartenances de l'appareil
  awk -F'|' -v d="$1" -v g="${2-}" '!(NF && $1 == "MEMBER" && $2 == d && (g == "" || $3 == g))'
}

access_set_mode_line() {  # <ouvert|filtre>
  awk -F'|' -v m="$1" '
    $1 == "MODE" { next }
    { print }
    END { print "MODE|" m }'
}

# Prochain identifiant de règle libre : p1, p2, p3...
access_next_policy_id() {
  local n=1
  while access_cat | awk -F'|' -v i="p$n" '$1 == "POLICY" && $2 == i { f = 1 } END { exit !f }'; do
    n=$(( n + 1 ))
  done
  echo "p$n"
}

# Lit une option de la forme --cle=valeur. Rend la valeur, ou rien.
# Noms de variables distinctifs : un « k » tout court était confondu par l'analyseur
# statique avec un tableau associatif utilisé ailleurs dans le fichier.
# (Un commentaire commençant par le nom de cet analyseur serait pris pour une directive.)
opt_value() {
  local _ov_arg=$1 _ov_key=$2
  [[ $_ov_arg == "--$_ov_key="* ]] && printf '%s' "${_ov_arg#--$_ov_key=}"
}

# --- groupes ----------------------------------------------------------------
cmd_group() {
  load_settings
  local action=${1-} id grp dev libelle="" a
  [[ -n $action ]] && shift
  case $action in
    ""|list|liste)
      title "Groupes d'appareils"
      local n=0
      while IFS='|' read -r id libelle; do
        [[ -n $id ]] || continue
        n=$(( n + 1 ))
        printf '   %s %s %s\n' "$(pad "$id" 16)" "$(pad "$libelle" 28)" "${DIM}$(access_group_devices "$id" | wc -l) appareil(s)${RESET}"
      done < <(access_rows GROUP)
      printf '   %s %s %s\n' "$(pad "$ACCESS_ALL" 16)" "$(pad "Tous les appareils" 28)" "${DIM}$(access_group_devices "$ACCESS_ALL" | wc -l) appareil(s)${RESET}"
      if (( n == 0 )); then
        echo
        txt "Aucun groupe pour l'instant. Le groupe « $ACCESS_ALL » existe toujours et contient" \
            "tous vos appareils." "" \
            "Pour en créer un : ${BOLD}sudo wg-pi group add invites --libelle=\"Invités\"${RESET}"
      fi
      echo
      ;;
    add|ajouter)
      take_lock
      id=${1-}; [[ -n $id ]] && shift
      [[ -n $id ]] || die "Usage : wg-pi group add <nom> [--libelle=\"...\"]"
      access_valid_id "$id" || die "Nom de groupe invalide : 1 à 15 caractères parmi lettres, chiffres, - et _."
      access_is_all "$id" && die "« $ACCESS_ALL » est le groupe automatique : il existe déjà et contient tous vos appareils."
      for a in "$@"; do libelle=$(opt_value "$a" libelle); [[ -n $libelle ]] && break; done
      access_valid_label "$libelle" ||
        die "Libelle invalide : au plus 60 caracteres, sans barre verticale ni caractere de controle."
      [[ -n $libelle ]] || libelle=$id
      access_group_exists "$id" && info "Le groupe « $id » existait déjà : son libellé est mis à jour."
      { access_cat | access_drop GROUP "$id"; echo "GROUP|$id|$libelle"; } | access_save ||
        die "Écriture de $ACCESS_FILE impossible."
      ok "Groupe « $libelle » ($id) enregistré."
      txt "   Pour y mettre un appareil : ${BOLD}sudo wg-pi group join <appareil> $id${RESET}"
      ;;
    rm|remove|supprimer)
      take_lock
      id=${1-}
      [[ -n $id ]] || die "Usage : wg-pi group rm <nom>"
      access_is_all "$id" && die "« $ACCESS_ALL » est le groupe automatique : il ne peut pas être supprimé."
      access_group_exists "$id" || die "Aucun groupe « $id »."
      # Une règle qui s'appuie sur ce groupe doit être retirée sciemment : la purge
      # silencieuse d'access_save effacerait la règle sans que l'utilisateur le sache.
      local used
      used=$(access_rows POLICY | awk -F'|' -v g="grp:$id" '$3 == g || $4 == g { printf " %s", $1 }')
      [[ -n $used ]] && die "Le groupe « $id » est utilisé par la ou les règles :$used. Supprimez-les d'abord (sudo wg-pi access rm <id>)."
      { access_cat | access_drop GROUP "$id" | awk -F'|' -v g="$id" '!(NF && $1 == "MEMBER" && $3 == g)'; } | access_save ||
        die "Écriture de $ACCESS_FILE impossible."
      ok "Groupe « $id » supprimé."
      ;;
    join|ajoute)
      take_lock
      dev=${1-} grp=${2-}
      [[ -n $dev && -n $grp ]] || die "Usage : wg-pi group join <appareil> <groupe>"
      client_exists "$dev" || die "Aucun appareil « $dev » (liste : sudo wg-pi list)."
      access_is_all "$grp" && die "« $ACCESS_ALL » contient déjà tous les appareils : rien à faire."
      access_group_exists "$grp" || die "Aucun groupe « $grp » (créez-le : sudo wg-pi group add $grp)."
      { access_cat; echo "MEMBER|$dev|$grp"; } | access_save || die "Écriture de $ACCESS_FILE impossible."
      ok "« $dev » fait maintenant partie de : $(access_device_groups "$dev" | paste -sd' ' -)"
      ;;
    leave|retire)
      take_lock
      dev=${1-} grp=${2-}
      [[ -n $dev && -n $grp ]] || die "Usage : wg-pi group leave <appareil> <groupe>"
      access_is_all "$grp" && die "« $ACCESS_ALL » est automatique : un appareil ne peut pas en sortir."
      access_cat | access_drop_member "$dev" "$grp" | access_save || die "Écriture de $ACCESS_FILE impossible."
      ok "« $dev » ne fait plus partie de « $grp »."
      ;;
    set|definir)
      take_lock
      dev=${1-} grp=${2-}
      [[ -n $dev ]] || die "Usage : wg-pi group set <appareil> <groupe1,groupe2,...>  (liste vide = aucun groupe)"
      client_exists "$dev" || die "Aucun appareil « $dev »."
      for a in ${grp//,/ }; do
        access_is_all "$a" && continue
        access_group_exists "$a" || die "Aucun groupe « $a »."
      done
      {
        access_cat | access_drop_member "$dev"
        for a in ${grp//,/ }; do
          access_is_all "$a" || echo "MEMBER|$dev|$a"
        done
      } | access_save || die "Écriture de $ACCESS_FILE impossible."
      ok "Groupes de « $dev » : $(access_device_groups "$dev" | paste -sd' ' -)"
      ;;
    *)
      die "Action inconnue : group $action (list, add, rm, join, leave, set)"
      ;;
  esac
}

# --- ressources de la maison ------------------------------------------------
cmd_resource() {
  load_settings
  local action=${1-} id target libelle="" a l t
  [[ -n $action ]] && shift
  case $action in
    ""|list|liste)
      title "Ressources de la maison"
      local n=0
      while IFS='|' read -r id l t; do
        [[ -n $id ]] || continue
        n=$(( n + 1 ))
        kv "$(pad "$id" 16)$l" "$t"
      done < <(access_rows RES)
      if (( n == 0 )); then
        echo
        txt "Aucune ressource déclarée. Une ressource est un appareil de la maison que vous" \
            "voulez pouvoir citer dans une règle : le NAS, Home Assistant, l'imprimante…" "" \
            "Exemple : ${BOLD}sudo wg-pi resource add nas 192.168.1.20 --libelle=\"Le NAS\"${RESET}"
      fi
      echo
      ;;
    add|ajouter)
      take_lock
      id=${1-}; [[ -n $id ]] && shift
      target=${1-}; [[ -n $target ]] && shift
      [[ -n $id && -n $target ]] || die "Usage : wg-pi resource add <nom> <ip ou réseau> [--libelle=\"...\"]"
      access_valid_id "$id" || die "Nom de ressource invalide : 1 à 15 caractères parmi lettres, chiffres, - et _."
      access_valid_target "$target" ||
        die "« $target » n'est ni une adresse IP ni un réseau (exemples : 192.168.1.20 ou 192.168.1.64/28)."
      # Une ressource hors du réseau de la maison ne serait jamais joignable par le VPN :
      # mieux vaut le dire tout de suite que laisser une règle sans effet.
      if [[ -n ${LAN_NET:-} ]] && ! cidr_overlap "${target%/*}/32" "$LAN_NET"; then
        warn "« $target » n'est pas dans le réseau de la maison ($LAN_NET) : la règle risque d'être sans effet."
      fi
      for a in "$@"; do libelle=$(opt_value "$a" libelle); [[ -n $libelle ]] && break; done
      access_valid_label "$libelle" ||
        die "Libelle invalide : au plus 60 caracteres, sans barre verticale ni caractere de controle."
      [[ -n $libelle ]] || libelle=$id
      { access_cat | access_drop RES "$id"; echo "RES|$id|$libelle|$target"; } | access_save ||
        die "Écriture de $ACCESS_FILE impossible."
      ok "Ressource « $libelle » ($target) enregistrée sous le nom « $id »."
      txt "   Pour y donner accès : ${BOLD}sudo wg-pi access allow <groupe> res:$id${RESET}"
      ;;
    rm|remove|supprimer)
      take_lock
      id=${1-}
      [[ -n $id ]] || die "Usage : wg-pi resource rm <nom>"
      access_res_exists "$id" || die "Aucune ressource « $id »."
      local used
      used=$(access_rows POLICY | awk -F'|' -v r="res:$id" '$4 == r { printf " %s", $1 }')
      [[ -n $used ]] && die "La ressource « $id » est utilisée par la ou les règles :$used. Supprimez-les d'abord."
      access_cat | access_drop RES "$id" | access_save || die "Écriture de $ACCESS_FILE impossible."
      ok "Ressource « $id » supprimée."
      ;;
    *)
      die "Action inconnue : resource $action (list, add, rm)"
      ;;
  esac
}

# --- règles d'accès ---------------------------------------------------------
# Une règle AUTORISE, jamais n'interdit : il n'y a donc ni ordre, ni priorité, ni règle à
# déboguer en cascade. C'est la simplification la plus importante pour un non-technicien,
# et c'est aussi le modèle de NetBird.
cmd_access() {
  load_settings
  local action=${1-} src dst proto=any ports="" sens=aller libelle="" id a v
  [[ -n $action ]] && shift
  case $action in
    ""|show|montre)
      access_show
      ;;
    list|liste)
      title "Règles d'accès"
      local n=0
      while IFS='|' read -r id a src dst proto ports sens libelle; do
        [[ -n $id ]] || continue
        n=$(( n + 1 ))
        printf '   %s %s\n' "${BOLD}$(pad "$id" 5)${RESET}" "$libelle"
        printf '         %s → %s\n' "Le groupe « $(access_group_label "${src#grp:}") »" "$(access_dest_label "$dst")"
        printf '         %s, %s, %s\n' "$proto" "$(access_ports_label "$ports")" \
          "$([[ $sens == deux ]] && echo "dans les deux sens" || echo "la source initie")"
      done < <(access_rows POLICY)
      (( n == 0 )) && txt "Aucune règle. Tous vos appareils peuvent tout joindre (mode « $(access_mode) »)."
      echo
      ;;
    allow|autorise)
      take_lock
      src=${1-}; [[ -n $src ]] && shift
      dst=${1-}; [[ -n $dst ]] && shift
      [[ -n $src && -n $dst ]] ||
        die "Usage : wg-pi access allow <groupe> <destination> [--proto=tcp] [--ports=445,5000-5001] [--sens=deux] [--libelle=\"...\"]
Destinations : internet, maison, pi, res:<ressource>, grp:<groupe>"
      for a in "$@"; do
        v=$(opt_value "$a" proto);   [[ -n $v ]] && proto=$v
        v=$(opt_value "$a" ports);   [[ -n $v ]] && ports=$v
        v=$(opt_value "$a" sens);    [[ -n $v ]] && sens=$v
        v=$(opt_value "$a" libelle); [[ -n $v ]] && libelle=$v
      done
      access_is_all "$src" || access_group_exists "$src" || die "Aucun groupe « $src »."
      access_valid_dest "$dst" || die "Destination invalide : « $dst » (internet, maison, pi, res:<nom>, grp:<nom>)."
      case $dst in
        res:*) access_res_exists "${dst#res:}" || die "Aucune ressource « ${dst#res:} »." ;;
        grp:*) access_is_all "${dst#grp:}" || access_group_exists "${dst#grp:}" || die "Aucun groupe « ${dst#grp:} »." ;;
      esac
      access_valid_proto "$proto" || die "Protocole invalide : « $proto » (any, tcp, udp, icmp)."
      access_valid_dir "$sens" || die "Sens invalide : « $sens » (aller, deux)."
      access_valid_two_way "$sens" "$dst" ||
        die "« --sens=deux » n'a de sens que vers un groupe (grp:<nom>).
Vers Internet, la maison ou une ressource, le trafic qui revient ne passe pas par le VPN :
il dépend de votre box et d'UFW, et wg-pi ne peut rien en promettre."
      access_valid_ports "$ports" ||
        die "Liste de ports invalide : « $ports ». Exemples : 445 ou 445,5000-5001. Au plus 15 ports, une plage en comptant deux."
      [[ -n $ports && $proto != tcp && $proto != udp ]] &&
        die "Des ports n'ont de sens qu'avec --proto=tcp ou --proto=udp."
      access_valid_label "$libelle" ||
        die "Libelle invalide : au plus 60 caracteres, sans barre verticale ni caractere de controle."
      [[ -n $libelle ]] || libelle="$(access_group_label "$src") → $(access_dest_label "$dst")"
      id=$(access_next_policy_id)
      { access_cat; echo "POLICY|$id|1|grp:$src|$dst|$proto|$ports|$sens|$libelle"; } | access_save ||
        die "Écriture de $ACCESS_FILE impossible."
      ok "Règle $id enregistrée : $libelle"
      [[ $(access_mode) == ouvert ]] &&
        txt "   ${DIM}Le filtrage n'est pas encore actif : cette règle est enregistrée mais ne change rien pour l'instant.${RESET}"
      ;;
    rm|remove|supprimer)
      take_lock
      id=${1-}
      [[ -n $id ]] || die "Usage : wg-pi access rm <identifiant de règle>  (liste : sudo wg-pi access list)"
      access_cat | awk -F'|' -v i="$id" '$1 == "POLICY" && $2 == i { f = 1 } END { exit !f }' ||
        die "Aucune règle « $id »."
      access_cat | access_drop POLICY "$id" | access_save || die "Écriture de $ACCESS_FILE impossible."
      ok "Règle « $id » supprimée."
      ;;
    check|verifie)
      access_check
      ;;
    plan|essai)
      cmd_access_plan
      ;;
    on|active|activer)
      cmd_access_on "$@"
      ;;
    off|desactive|desactiver)
      cmd_access_off
      ;;
    confirm|confirme|confirmer)
      cmd_access_confirm
      ;;
    *)
      die "Action inconnue : access $action (show, list, allow, rm, check, plan, on, off, confirm)"
      ;;
  esac
}

# Aligne le pare-feu installé sur la version du script. Appelée automatiquement par
# « wg-pi update », et proposée par le diagnostic quand une mise à jour venue d'une version
# antérieure n'a pas pu le faire : cette version-là ne connaissait pas cette commande.
cmd_fw_sync() {
  load_settings
  [[ -n ${WGPI_LOCKED:-} ]] || take_lock
  fw_sync
}

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
    printf '{"name":"%s","ip":"%s","ip6":"%s","pub":"%s","enabled":%s,"mode":"%s","handshake":%s,"rx":%s,"tx":%s,"endpoint":"%s","groupes":%s}' \
      "$(json_esc "$name")" "$ip" "$ip6" "$pub" "$enabled" "$mode" "${hs["$pub"]:-0}" "${rx["$pub"]:-0}" "${tx["$pub"]:-0}" \
      "$(json_esc "${ep["$pub"]:-}")" "$(access_json_device_groups "$name")"
  done < <(peers_table)
  printf '],"acces":%s}\n' "$(access_json)"
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
# Identifiants et destinations des règles. Jamais de « - » en tête : wg-pi recevrait
# l'argument comme une option. Les motifs reprennent ceux du script, volontairement.
ACCES_ID_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{0,14}")
DEST_RE = re.compile(r"internet|maison|pi|(?:res|grp):[A-Za-z0-9_][A-Za-z0-9_-]{0,14}")
PORTS_RE = re.compile(r"[0-9]{1,5}(?:-[0-9]{1,5})?(?:,[0-9]{1,5}(?:-[0-9]{1,5})?)*")
CIBLE_RE = re.compile(r"[0-9a-fA-F:.]{2,45}(?:/[0-9]{1,3})?")
REGLE_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,16}")


def libelle_ok(v):
    """La barre verticale est le séparateur d'access.conf : elle n'entre pas dans un libellé."""
    return len(v) <= 60 and "|" not in v and all(32 <= ord(c) != 127 for c in v)
# Seuls le réseau local, le VPN et la machine elle-même peuvent joindre le panneau
ALLOWED_NETS = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10")]
CSP = ("default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'self'; "
       "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")

sessions = {}   # jeton -> {"expires": horodatage, "csrf": jeton anti-CSRF, "role": admin|lecture}
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


def _verify(stored, password):
    try:
        algo, rounds, salt, digest = (stored or "").split("$")
        if algo != "pbkdf2_sha256":
            return False
        calc = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), int(rounds)).hex()
        return hmac.compare_digest(calc.encode(), digest.encode())
    except ValueError:
        return False


def check_password(password):
    return check_password_role(password) is not None


def check_password_role(password):
    """Rend « admin », « lecture », ou None.

    L'empreinte de consultation n'est calculée QUE si celle de l'administrateur a
    échoué. Le conseil habituel serait de calculer les deux systématiquement pour
    aplatir le temps de réponse, mais PBKDF2-SHA256 tourne ici à 200 000 itérations :
    sur un Pi 1 en ARMv6 c'est de l'ordre de la seconde, et en calculer deux doublerait
    le temps de connexion POUR TOUT LE MONDE, sous un verrou qui sérialise déjà les
    essais. Ce qui fuit alors — « un second mot de passe existe » — n'a aucune valeur
    pour un attaquant déjà limité aux réseaux privés et à 5 essais par 5 minutes, et le
    time.sleep(1) du chemin d'échec masque l'écart.
    """
    conf = read_conf()
    if _verify(conf.get("password", ""), password):
        return "admin"
    ro = conf.get("password_ro", "")
    if ro and _verify(ro, password):
        return "lecture"
    return None


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
                      "groupes": p.get("groupes", []),
                      "endpoint": "" if endpoint in ("", "(none)") else endpoint})
    server = {k: base.get(k, "") for k in ("version", "endpoint", "port", "net", "net6", "dns",
                                            "keepalive", "pubkey", "lan_net", "default_route")}
    server.update({"running": live is not None, "online": online, "total": len(peers)})
    # La vue d'acces est resolue par la commande wg-pi : le panneau n'evalue rien, il
    # affiche. Dupliquer l'evaluation en JavaScript ferait deriver les deux, et la vue
    # finirait par annoncer un cloisonnement que le pare-feu n'applique pas.
    return {"server": server, "peers": peers, "acces": base.get("acces", {}),
            "time": time.time()}


def acces_vue():
    """La vue d'accès déjà résolue par « wg-pi json » : mode, groupes, ressources."""
    try:
        return load_base().get("acces") or {}
    except Exception:
        return {}


def acces_actif():
    """Le filtrage tourne-t-il ? Une règle écrite pendant qu'il tourne ne vaut rien
    tant qu'elle n'est pas poussée dans le noyau."""
    return acces_vue().get("mode") == "filtre"


def avertissements(texte):
    """Les « warn » du CLI sortent sur la SORTIE STANDARD, mêlés aux messages de succès.

    clean_message() aplatit tout et retire les marqueurs : il ne sait donc pas distinguer
    un avertissement d'un succès. On relit le texte brut pour ne garder que les lignes
    marquées, car ce sont les seules qui apprennent quelque chose au panneau — qu'une
    ressource est hors du réseau de la maison, ou qu'une règle va bloquer le DNS de la
    box. Les jeter, c'était laisser l'utilisateur découvrir le problème par lui-même."""
    propre = re.sub(r"\x1b\[[0-9;]*m", "", texte or "")
    gardes = [l.strip().lstrip("⚠").strip()
              for l in propre.splitlines() if l.strip().startswith("⚠")]
    return " ".join(g for g in gardes if g)[:400]


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
        "--accent:#e5484d;--accent-2:#f05b60;--accent-soft:#2d1618;--on-accent:#16191e;--ok:#3ccb7f;--ok-soft:#10291c;--bad:#f97066;--bad-soft:#2c1412;"
        "--g1:#60a5fa;--g2:#34d399;--g3:#fbbf24;--g4:#a78bfa;--g5:#22d3ee;--g6:#f472b6;"
        "--shadow:none")
CSS = """
:root{--bg:#f3f4f6;--card:#fff;--soft:#f7f8fa;--text:#14171a;--muted:#667085;--line:#e5e7eb;
--accent:#88171a;--accent-2:#6f1215;--on-accent:#fff;--accent-soft:#f7e9e9;--ok:#12a150;--ok-soft:#e8f7ee;--bad:#d92d20;--bad-soft:#fdeeec;
--g1:#2563eb;--g2:#059669;--g3:#b45309;--g4:#7c3aed;--g5:#0e7490;--g6:#be185d;
--shadow:0 1px 2px rgba(16,24,40,.05),0 2px 8px rgba(16,24,40,.06);--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
:root[data-theme=dark]{%DARK%}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){%DARK%}}
*{box-sizing:border-box}[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;
-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
.wrap{max-width:1040px;margin:0 auto;padding:0 18px}
.mono{font-family:var(--mono);font-size:12.5px}
.acces .clients-head{align-items:center;gap:10px}
#acc-matrix{overflow-x:auto;-webkit-overflow-scrolling:touch}
table.matrix{border-collapse:separate;border-spacing:0;width:100%;min-width:min-content;font-size:13px}
table.matrix th,table.matrix td{border-bottom:1px solid var(--line);padding:9px 10px;text-align:left;vertical-align:middle}
table.matrix th:first-child,table.matrix td:first-child{padding-left:16px}
table.matrix th:last-child,table.matrix td:last-child{padding-right:16px}
table.matrix thead th{position:sticky;top:0;background:var(--card);font-size:12px;color:var(--muted);font-weight:600;white-space:nowrap}
table.matrix tbody th{position:sticky;left:0;background:var(--card);min-width:9.5rem;font-weight:600}
table.matrix th.corner{left:0;z-index:2;background:var(--card)}
table.matrix tbody th small{display:block;color:var(--muted);font-weight:400;font-size:11.5px}
table.matrix tbody th small.auto{color:var(--accent)}
table.matrix td.yes{background:var(--ok-soft)}
table.matrix td.yes span{font-family:var(--mono);font-size:12px}
table.matrix td.no{background:repeating-linear-gradient(135deg,transparent,transparent 5px,var(--line) 5px,var(--line) 6px)}
.acc-note{color:var(--muted);font-size:12.5px;margin:12px 0 0}
.pan > .acc-note{padding:0 16px 14px;margin-top:12px}
.pan > .alert{margin:12px 16px}
.pan > #map-box{padding:0 16px}
/* Pastille de groupe sur la ligne d un appareil, et fiche d acces. */
.badge.grp{border-color:currentColor}
.badge.grp.g1{color:var(--g1)}.badge.grp.g2{color:var(--g2)}.badge.grp.g3{color:var(--g3)}
.badge.grp.g4{color:var(--g4)}.badge.grp.g5{color:var(--g5)}.badge.grp.g6{color:var(--g6)}
.fiche h4{margin:16px 0 6px;font-size:12.5px;color:var(--muted);font-weight:600;
text-transform:uppercase;letter-spacing:.04em}
.fiche h4:first-child{margin-top:4px}
.fiche-badges{display:flex;flex-wrap:wrap;gap:6px}
.fiche-l{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px;padding:6px 0;
border-bottom:1px solid var(--line)}
.fiche-l:last-of-type{border-bottom:0}
.fiche-l .via{color:var(--muted);font-size:12.5px}
.fiche-l .det{margin-left:auto;font-family:var(--mono);font-size:12px;color:var(--muted)}
.fiche-vide{color:var(--muted);font-size:13px;padding:4px 0}
.fiche-note{background:var(--soft);border:1px solid var(--line);border-radius:10px;
padding:10px 12px;margin:10px 0;color:var(--muted);font-size:12.5px}
.fiche-note.bad{background:var(--bad-soft);border-color:var(--bad);color:var(--text)}
@media (max-width:760px){.fiche-l .det{margin-left:0;flex-basis:100%}}
/* Compte de consultation : les commandes qui ne feraient rien sont masquees. Purement
   cosmetique — le refus est applique cote serveur. */
body[data-role=lecture] [data-admin]{display:none!important}
body[data-role=lecture] .chip{padding:2px 9px}
body[data-role=lecture] .ro-note{display:block}
.ro-note{display:none;color:var(--muted);font-size:12.5px;margin:0 0 12px}
/* Carte. Le SVG garde une largeur minimale et le conteneur defile : a 375 px, des
   etiquettes tassees se chevaucheraient, ce qui est pire qu un defilement. */
#map-box{overflow-x:auto;-webkit-overflow-scrolling:touch;margin-top:16px}
svg.map{width:100%;min-width:640px;height:auto;display:block}
svg.map text{font:11.5px system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--text)}
svg.map text.rate{font-size:10.5px;fill:var(--muted);font-family:var(--mono)}
svg.map text.ports{font-size:10px;fill:var(--muted);font-family:var(--mono)}
svg.map text.pi-lbl{fill:var(--muted);font-size:10.5px}
svg.map circle.pi{fill:var(--accent)}
svg.map circle.dot{fill:var(--muted)}
svg.map .map-node.on circle.dot{fill:var(--ok)}
svg.map .map-node.off text.lbl{fill:var(--muted);text-decoration:line-through}
svg.map .map-node{cursor:pointer}
svg.map .map-link{fill:none;stroke-linecap:round}
svg.map .map-link.axis{stroke:var(--muted)}
svg.map .map-link.axis.off{stroke:var(--line);stroke-dasharray:3 4}
/* Le cycle de tirets reste CONSTANT (12 unites) et le decalage vaut exactement un cycle :
   l animation boucle donc sans saut. Seules l intensite et l epaisseur varient avec le
   debit, parce qu elles se transitionnent, contrairement a la duree d animation. */
svg.map .map-link.live{stroke-dasharray:2 10;animation:wgflow 1.1s linear infinite;
transition:stroke-opacity .7s linear,stroke-width .7s linear}
svg.map .map-link.live.s2{animation-duration:.62s}
svg.map .map-link.live.s3{animation-duration:.34s}
@keyframes wgflow{to{stroke-dashoffset:-12}}
@media (prefers-reduced-motion:reduce){svg.map .map-link.live{animation:none}}
.paused svg.map .map-link.live{animation-play-state:paused}
svg.map .map-link.pol{stroke-width:1.6;stroke-opacity:.8}
svg.map .map-link.pol.wide{stroke-width:3.4}
svg.map .map-link.pol.oneway{stroke-dasharray:6 4}
svg.map.focus .map-link,svg.map.focus .map-node{opacity:.12;transition:opacity .2s linear}
svg.map.focus .map-link.sel,svg.map.focus .map-node.sel,svg.map.focus .map-pi{opacity:1}
svg.map .g1{stroke:var(--g1)}svg.map .g2{stroke:var(--g2)}svg.map .g3{stroke:var(--g3)}
svg.map .g4{stroke:var(--g4)}svg.map .g5{stroke:var(--g5)}svg.map .g6{stroke:var(--g6)}
svg.map circle.gdot{stroke:none}
svg.map circle.gdot.g1{fill:var(--g1)}svg.map circle.gdot.g2{fill:var(--g2)}
svg.map circle.gdot.g3{fill:var(--g3)}svg.map circle.gdot.g4{fill:var(--g4)}
svg.map circle.gdot.g5{fill:var(--g5)}svg.map circle.gdot.g6{fill:var(--g6)}
@media (max-width:760px){table.matrix tbody th{min-width:7.5rem}}
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
/* « ghost danger » : un bouton de suppression discret. Sans cette regle, il heriterait
   du texte blanc de .btn.danger sur un fond transparent, donc blanc sur blanc. */
.btn.ghost.danger{background:transparent;border-color:var(--line);color:var(--bad)}
.btn.ghost.danger:hover{background:var(--bad-soft);border-color:transparent;color:var(--bad)}
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
.srv-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px 24px;
padding:14px 16px 16px}
.srv-details .wide{grid-column:1/-1}.key{display:flex;align-items:center;gap:8px}
.clients{overflow:hidden}
.tabs{display:flex;gap:4px;margin:0 0 14px;padding:4px;background:var(--card);border:1px solid var(--line);
border-radius:14px;box-shadow:var(--shadow);overflow-x:auto;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tabs button{flex:1 1 auto;height:38px;padding:0 14px;border:none;border-radius:10px;background:transparent;
color:var(--muted);font:inherit;font-weight:600;cursor:pointer;white-space:nowrap;
display:inline-flex;align-items:center;justify-content:center;gap:7px}
.tabs button:hover{background:var(--soft);color:var(--text)}
.tabs button:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.tabs button[aria-selected=true]{background:var(--accent);color:var(--on-accent)}
.tabs button[aria-selected=true]:hover{background:var(--accent-2)}
/* Sur l onglet actif, le fond EST deja l accent : un anneau de focus de la meme
   couleur y serait invisible, et la navigation au clavier se ferait a l aveugle. */
.tabs button[aria-selected=true]:focus-visible{outline-color:var(--on-accent)}
.tcount{font-size:11px;font-weight:700;padding:1px 6px;border-radius:999px;background:var(--soft);color:var(--muted)}
.tcount:empty{display:none}
.tabs button[aria-selected=true] .tcount{background:rgba(0,0,0,.26);color:var(--on-accent)}
.pan[hidden]{display:none}
.secbox{padding:14px 16px}.secbox+.secbox{border-top:1px solid var(--line)}
.sec-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.sec-head h3{margin:0;font-size:15px;display:flex;align-items:center;gap:8px}
.tile{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:10px 12px;border:1px solid var(--line);
border-radius:12px;background:var(--soft)}
.tile+.tile{margin-top:8px}.tile b{font-size:14px}
.tile .push,.regle .push{margin-left:auto;display:flex;flex-wrap:wrap;gap:8px}
.tile .sub{color:var(--muted);font-size:12.5px}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{display:inline-flex;align-items:center;gap:5px;font-size:12px;font-weight:600;padding:2px 4px 2px 9px;
border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--muted)}
.chip.plain{padding:2px 9px}
.chip button{border:none;background:transparent;color:var(--muted);cursor:pointer;font:inherit;line-height:1;
padding:2px 4px;border-radius:999px}
.chip button:hover{background:var(--bad-soft);color:var(--bad)}
.grid-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:12px;align-items:start}
.grid-form .field{margin:0 0 6px}.grid-form select{width:100%}
.grid-form .wide{grid-column:1/-1}
.alert .btn{margin-left:auto}
.alert-ligne{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.regle{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:10px 16px;border-bottom:1px solid var(--line)}
.regle:last-child{border-bottom:none}
.regle .fleche{color:var(--muted)}
.regle .push{margin-left:auto}
.regle-vide{padding:22px 16px;text-align:center;color:var(--muted)}
.clients-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;padding:12px 16px;
border-bottom:1px solid var(--line)}
.clients-head h2{margin:0;font-size:17px;display:flex;align-items:center;gap:8px}
.count{font-size:12px;font-weight:700;color:var(--muted);background:var(--soft);border:1px solid var(--line);border-radius:999px;padding:0 8px}
.clients-tools{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.search{display:flex;align-items:center;gap:6px;height:36px;padding:0 10px;border:1px solid var(--line);border-radius:10px;
background:var(--soft);color:var(--muted)}
.search input{border:none;background:transparent;color:var(--text);font:inherit;width:170px;outline:none}
select{height:36px;padding:0 8px;border:1px solid var(--line);border-radius:10px;background:var(--soft);color:var(--text);font:inherit}
.row{position:relative;border-bottom:1px solid var(--line);overflow:hidden}
.row:last-child{border-bottom:none}.row:hover{background:var(--soft)}
.spark{position:absolute;left:0;top:0;right:0;bottom:0;width:100%;height:100%;pointer-events:none;z-index:0}
.spark path{fill:var(--accent);opacity:.13}
.row-main{position:relative;z-index:1;display:grid;grid-template-columns:42px minmax(0,1fr) auto auto;
align-items:center;gap:2px 14px;padding:10px 16px}
.avatar{position:relative;width:42px;height:42px;border-radius:50%;display:grid;place-items:center;color:#fff;
font-weight:700;font-size:15px;flex:none}
.avatar .dot{position:absolute;right:-1px;bottom:-1px;width:13px;height:13px;border-radius:50%;background:var(--muted);
border:2px solid var(--card)}
.row.online .avatar .dot{background:var(--ok);animation:pulse 2s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(18,161,80,.55)}70%{box-shadow:0 0 0 7px rgba(18,161,80,0)}100%{box-shadow:0 0 0 0 rgba(18,161,80,0)}}
.row.disabled .avatar{filter:grayscale(1);opacity:.45}.row.disabled .name{color:var(--muted)}
.l1{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px}
.name{font-weight:700;font-size:15px}
.badge{font-size:11.5px;font-weight:600;padding:0 8px;border-radius:999px;background:var(--soft);border:1px solid var(--line);color:var(--muted)}
.badge.off{background:var(--bad-soft);border-color:transparent;color:var(--bad)}
.info{min-width:0}
.l2{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px;margin-top:2px}
.ips{color:var(--muted);font-size:12.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ips .sep{opacity:.45;margin:0 2px}
.status{font-size:12.5px;color:var(--muted)}.status.on{color:var(--ok);font-weight:600}
.traffic{text-align:right;min-width:0;display:flex;flex-direction:column;align-items:flex-end;gap:3px}
.traffic[hidden]{display:flex!important;visibility:hidden}
.rates{font-weight:700;font-size:12.5px;font-variant-numeric:tabular-nums;white-space:nowrap;
padding:2px 9px;border-radius:999px;background:var(--accent-soft);color:var(--accent)}
.rates:empty{display:none}
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
.row-main{grid-template-columns:42px minmax(0,1fr);gap:8px 12px}
.traffic{grid-column:2;align-items:flex-start;text-align:left;min-width:0}
.traffic[hidden]{display:none!important}
.actions{grid-column:1/-1;justify-content:flex-end}
.tabs button{flex:0 0 auto;padding:0 12px}
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
    laptop: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 19h20"/></svg>',
    acces: '<svg viewBox="0 0 24 24"><path d="M12 3l7 3v5.5c0 4.2-2.9 7.6-7 8.5-4.1-.9-7-4.3-7-8.5V6l7-3z"/><path d="m9 12 2 2 4-4"/></svg>'
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

  /* L'animation de la carte est suspendue quand l'onglet est caché. Un tableau de bord
     laissé ouvert toute la journée sur un téléphone animerait sinon dans le vide, et ça
     se paie en batterie. */
  function syncPaused() {
    if (document.hidden) { root.classList.add("paused"); } else { root.classList.remove("paused"); }
  }
  document.addEventListener("visibilitychange", syncPaused);
  syncPaused();

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
    renderAcces();
    renderGroupes();
    renderRegles();
    renderConfirmation();
    majBascule();
    renderMap();
  }



  /* ---- Carte des accès ---- */
  /* Trois colonnes : les appareils, le Pi, les destinations. Toutes les arêtes sont
     pincées au point du Pi, parce que c'est la vérité du routage — chez wg-pi tout passe
     par lui. Un graphe radial a été écarté : le réseau est une étoile par construction,
     donc l'étoile ne porte aucune information, et à 30 appareils les étiquettes
     tangentielles demanderaient un rayon de 454 px quand un téléphone en offre 170.

     L'ANIMATION ne porte QUE sur les liens appareil↔Pi. « wg show » ne donne que des
     compteurs rx/tx PAR PAIR : animer une arête de politique selon le trafic supposerait
     d'attribuer ce trafic à une règle précise, ce qu'aucune donnée ne permet. Ce serait
     inventer un chiffre, et c'est le mensonge le plus tentant de cette vue. */
  var MAP_W = 700, MAP_ROW = 34, MAP_X_DEV = 150, MAP_X_PI = 350, MAP_X_DEST = 550;
  var mapFocus = null;

  function svgEl(tag, cls) {
    var e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    if (cls) { e.setAttribute("class", cls); }
    return e;
  }
  function svgText(x, y, cls, text, anchor) {
    var t = svgEl("text", cls);
    t.setAttribute("x", x); t.setAttribute("y", y);
    t.setAttribute("dominant-baseline", "middle");
    if (anchor) { t.setAttribute("text-anchor", anchor); }
    t.textContent = text;
    return t;
  }
  /* Courbe pincée au point du Pi : départ, point de contrôle au tiers, arrivée. */
  function mapPath(x1, y1, x2, y2) {
    var mx = (x1 + x2) / 2;
    return "M" + x1 + " " + y1 + "C" + mx + " " + y1 + " " + mx + " " + y2 + " " + x2 + " " + y2;
  }
  /* Palier de vitesse discret : « animation-duration » n'est pas interpolable, donc le
     faire varier en continu provoquerait un saut visible à chaque relevé. On n'en change
     qu'au franchissement d'un palier, et c'est l'intensité et l'épaisseur — qui se
     transitionnent proprement — qui portent la nuance. */
  function mapTier(bps) {
    if (bps > 2000000) { return 3; }
    if (bps > 200000) { return 2; }
    return 1;
  }
  function mapGroupClass(groupes, id) {
    var i = 0;
    for (i = 0; i < groupes.length; i++) {
      if (groupes[i].id === id) { return "g" + ((i % 6) + 1); }
    }
    return "g6";
  }

  function renderMap() {
    var a = state.acces || {}, box = $("map-box");
    if (!box) { return; }
    var groupes = a.groupes || [], peers = state.peers || [];

    /* Destinations citées par au moins une règle, dans le même ordre que les règles. */
    var destLabels = Object.create(null);
    groupes.forEach(function (g) {
      (g.flux || []).forEach(function (f) { destLabels[f.dest] = f.label; });
    });
    var dests = Object.keys(destLabels).sort(function (x, y) {
      var r = destRang(x) - destRang(y);
      return r !== 0 ? r : (destLabels[x] < destLabels[y] ? -1 : 1);
    });

    box.textContent = "";
    if (!peers.length) { return; }

    var rows = Math.max(peers.length, dests.length, 1);
    var h = rows * MAP_ROW + 48;
    var svg = svgEl("svg", "map" + (mapFocus ? " focus" : ""));
    svg.setAttribute("viewBox", "0 0 " + MAP_W + " " + h);
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", "Carte des acces : appareils, Pi, destinations");

    var yOf = function (i, n) { return 32 + (h - 48) * (i + 0.5) / Math.max(n, 1); };
    var yPi = h / 2;
    var liens = svgEl("g", "map-links");

    /* --- liens appareil vers Pi : les SEULS animes, sur de vraies mesures -------- */
    peers.forEach(function (p, i) {
      var y = yOf(i, peers.length);
      var bps = (p.down || 0) + (p.up || 0);
      var cls = "map-link axis";
      if (!p.enabled) { cls += " off"; } else if (bps > 0) { cls += " live s" + mapTier(bps); }
      var path = svgEl("path", cls);
      path.setAttribute("d", mapPath(MAP_X_DEV + 8, y, MAP_X_PI - 16, yPi));
      path.setAttribute("data-dev", p.name);
      /* Intensite et epaisseur portent le debit : elles se transitionnent proprement,
         contrairement a la duree d animation. Un lien au repos n est pas anime du tout —
         un point qui circule sur une liaison inactive serait un mensonge visuel. */
      var k = bps > 0 ? Math.min(1, Math.log(1 + bps / 1000) / 9.2) : 0;
      /* stroke-opacity, et surtout pas opacity : un style inline l emporte sur la
         feuille de style, donc une opacite inline bloquerait l estompage du mode focus.
         Les deux proprietes se composent au lieu de se concurrencer. */
      path.style.strokeOpacity = String(0.25 + 0.6 * k);
      path.style.strokeWidth = String(1.2 + 2.3 * k);
      liens.appendChild(path);
    });

    /* --- liens Pi vers destination : la POLITIQUE, jamais le trafic -------------- */
    dests.forEach(function (d, j) {
      var y = yOf(j, dests.length);
      groupes.forEach(function (g) {
        var f = (g.flux || []).filter(function (x) { return x.dest === d; })[0];
        if (!f) { return; }
        var cls = "map-link pol " + mapGroupClass(groupes, g.id);
        /* Epaisseur : ports listes contre tous les ports. Gros tuyau = large ouvert. */
        if (!f.ports) { cls += " wide"; }
        if (f.sens !== "deux") { cls += " oneway"; }
        var path = svgEl("path", cls);
        path.setAttribute("d", mapPath(MAP_X_PI + 16, yPi, MAP_X_DEST - 8, y));
        path.setAttribute("data-grp", g.id);
        path.setAttribute("data-dest", d);
        var titre = svgEl("title");
        titre.textContent = g.libelle + " vers " + f.label + " (" + fluxTexte(f) + ")";
        path.appendChild(titre);
        liens.appendChild(path);
      });
    });
    svg.appendChild(liens);

    /* --- colonne des appareils -------------------------------------------------- */
    var gdev = svgEl("g", "map-devs");
    peers.forEach(function (p, i) {
      var y = yOf(i, peers.length);
      var cls = "map-node dev";
      if (p.connected) { cls += " on"; }
      if (!p.enabled) { cls += " off"; }
      var n = svgEl("g", cls);
      n.setAttribute("data-dev", p.name);
      n.appendChild(svgText(MAP_X_DEV - 16, y, "lbl", p.name, "end"));
      var dot = svgEl("circle", "dot");
      dot.setAttribute("cx", MAP_X_DEV);
      dot.setAttribute("cy", y);
      dot.setAttribute("r", 4.5);
      n.appendChild(dot);
      /* Pastilles de groupe : la couleur relie l appareil a ses aretes de politique. */
      var k = 0;
      (p.groupes || []).forEach(function (gid) {
        if (gid === "tous") { return; }
        var b = svgEl("circle", "gdot " + mapGroupClass(groupes, gid));
        b.setAttribute("cx", MAP_X_DEV - 8 - k * 7);
        b.setAttribute("cy", y - 10);
        b.setAttribute("r", 2.6);
        n.appendChild(b);
        k++;
      });
      var bps = (p.down || 0) + (p.up || 0);
      if (bps > 0) { n.appendChild(svgText(MAP_X_DEV + 14, y, "rate", humanRate(bps), "start")); }
      gdev.appendChild(n);
    });
    svg.appendChild(gdev);

    /* --- le Pi, au centre ------------------------------------------------------- */
    var gpi = svgEl("g", "map-pi");
    var pi = svgEl("circle", "pi");
    pi.setAttribute("cx", MAP_X_PI);
    pi.setAttribute("cy", yPi);
    pi.setAttribute("r", 13);
    gpi.appendChild(pi);
    gpi.appendChild(svgText(MAP_X_PI, yPi + 28, "lbl pi-lbl", "votre Pi", "middle"));
    svg.appendChild(gpi);

    /* --- colonne des destinations ----------------------------------------------- */
    var gdest = svgEl("g", "map-dests");
    dests.forEach(function (d, j) {
      var y = yOf(j, dests.length);
      var n = svgEl("g", "map-node dest");
      n.setAttribute("data-dest", d);
      var dot = svgEl("circle", "dot");
      dot.setAttribute("cx", MAP_X_DEST);
      dot.setAttribute("cy", y);
      dot.setAttribute("r", 4.5);
      n.appendChild(dot);
      n.appendChild(svgText(MAP_X_DEST + 14, y, "lbl", destLabels[d], "start"));
      /* Les ports vont en BOUT d arete, chaque arrivee ayant son creneau : a un point
         fixe sur la courbe, toutes les aretes convergeant vers une meme destination
         feraient se chevaucher leurs pastilles. */
      var ports = [];
      groupes.forEach(function (g) {
        var f = (g.flux || []).filter(function (x) { return x.dest === d; })[0];
        if (f) { ports.push(f.ports ? f.ports : "tout"); }
      });
      if (ports.length) {
        n.appendChild(svgText(MAP_X_DEST + 14, y + 13, "ports", ports.join(" / "), "start"));
      }
      gdest.appendChild(n);
    });
    svg.appendChild(gdest);

    box.appendChild(svg);
    applyMapFocus(svg);
    svg.addEventListener("click", onMapClick);

    /* La légende ne décrit que ce qui est RÉELLEMENT à l'écran. Sans aucune règle il n'y a
       pas d'arête de politique : parler de leur épaisseur et de leurs pointillés enverrait
       le lecteur chercher quelque chose qui n'existe pas. */
    var leg = $("map-legend");
    if (leg) {
      var t = "À gauche vos appareils, au centre le Pi. Le trait animé suit le débit réel de"
        + " l'appareil ; un appareil au repos n'est pas animé.";
      if (dests.length) {
        t += " À droite, ce qu'ils peuvent joindre : un trait épais signifie tous les ports,"
          + " un trait pointillé que seul l'appareil peut engager la connexion."
          + " Cliquez sur un appareil ou une destination pour n'afficher que ce qui le concerne.";
      } else {
        t += " La colonne de droite se remplira quand vous aurez créé des règles d'accès.";
      }
      leg.textContent = t;
      leg.hidden = false;
    }
  }

  /* Mode focus : sans lui, douze aretes sont illisibles. Un clic sur un appareil ou une
     destination estompe tout ce qui ne lui est pas lie ; un second clic retablit. */
  function mapKeyOf(node) {
    var n = node, i = 0, dev, dest;
    while (n && i < 6) {
      if (n.getAttribute) {
        dev = n.getAttribute("data-dev");
        dest = n.getAttribute("data-dest");
        if (dev) { return "dev:" + dev; }
        if (dest) { return "dest:" + dest; }
      }
      n = n.parentNode;
      i++;
    }
    return null;
  }
  function onMapClick(ev) {
    var key = mapKeyOf(ev.target);
    if (!key) { return; }
    mapFocus = mapFocus === key ? null : key;
    renderMap();
  }
  /* Le focus suit le CHEMIN COMPLET, et pas seulement le segment clique.

     Les liens de gauche portent « data-dev », ceux de droite « data-grp » et
     « data-dest » : ne filtrer que sur l'attribut du type clique arretait donc la mise
     en evidence au Pi. Or la question que l'on se pose en cliquant sur un appareil est
     precisement « et ensuite, qu'est-ce qu'il atteint ? » — s'arreter au Pi laissait
     croire qu'elle n'avait pas de reponse. La symetrie vaut dans l'autre sens : cliquer
     sur une destination montre quels appareils peuvent l'atteindre. */
  function applyMapFocus(svg) {
    if (!mapFocus) { return; }
    var kind = mapFocus.indexOf("dev:") === 0 ? "dev" : "dest";
    var val = mapFocus.slice(kind.length + 1);
    var groupes = (state && state.acces && state.acces.groupes) || [];
    var devs = Object.create(null), dests = Object.create(null), grps = Object.create(null);

    if (kind === "dev") {
      devs[val] = true;
      groupes.forEach(function (g) {
        if ((g.appareils || []).indexOf(val) < 0) { return; }
        grps[g.id] = true;
        (g.flux || []).forEach(function (f) { dests[f.dest] = true; });
      });
    } else {
      dests[val] = true;
      groupes.forEach(function (g) {
        var mene = (g.flux || []).filter(function (f) { return f.dest === val; }).length > 0;
        if (!mene) { return; }
        grps[g.id] = true;
        (g.appareils || []).forEach(function (d) { devs[d] = true; });
      });
    }

    /* « sel » et non « on » : « on » marque deja les appareils connectes, et le
       reutiliser rendrait opaque tout appareil connecte en mode focus. */
    function balayer(attr, retenu) {
      var lies = svg.querySelectorAll("[" + attr + "]") || [];
      Array.prototype.forEach.call(lies, function (e) {
        if (retenu(e.getAttribute(attr), e)) {
          e.setAttribute("class", (e.getAttribute("class") || "") + " sel");
        }
      });
    }
    balayer("data-dev", function (v) { return !!devs[v]; });
    /* Un lien de politique n'est retenu que si SES DEUX bouts le sont. Sans cette
       condition, selectionner un appareil allumerait aussi la regle d'un AUTRE groupe
       vers la meme destination, et donnerait a lire un droit qu'il n'a pas. */
    balayer("data-grp", function (v, e) {
      return !!grps[v] && !!dests[e.getAttribute("data-dest")];
    });
    /* Les liens de politique portent AUSSI « data-dest » : ils viennent d'etre traites,
       on ne garde ici que les noeuds de destination, pour ne pas marquer deux fois. */
    balayer("data-dest", function (v, e) {
      return e.getAttribute("data-grp") == null && !!dests[v];
    });
  }

  /* Debit lisible. Le panneau parle d octets ailleurs ; ici il s agit d un debit. */
  function humanRate(bps) {
    if (bps > 1000000) { return (bps / 1000000).toFixed(1) + " Mo/s"; }
    if (bps > 1000) { return Math.round(bps / 1000) + " ko/s"; }
    return Math.round(bps) + " o/s";
  }


  /* ---- Fiche d'accès d'un appareil ---- */
  /* Répond à la seule question que se pose vraiment un non-technicien : « qu'est-ce que
     la tablette de ma fille peut joindre ? ». Le panneau n'évalue rien — il expanse
     groupe → appareils, ce qui est de l'affichage, et lit des flux déjà résolus en bash. */
  function groupesNommes(p) {
    return (p.groupes || []).filter(function (g) { return g !== "tous"; });
  }
  /* Les flux qui s'appliquent à cet appareil : ceux de chacun de ses groupes, « tous »
     compris puisqu'il en fait toujours partie. */
  function fluxSortants(nom) {
    var a = state.acces || {}, mes = Object.create(null), out = [];
    var p = (state.peers || []).filter(function (x) { return x.name === nom; })[0];
    if (!p) { return out; }
    (p.groupes || []).forEach(function (g) { mes[g] = true; });
    (a.groupes || []).forEach(function (g) {
      if (!mes[g.id]) { return; }
      (g.flux || []).forEach(function (f) { out.push({groupe: g, flux: f}); });
    });
    return out;
  }
  /* Ce qui peut joindre cet appareil : les règles dont la destination est un groupe dont
     il fait partie. Le sens compte — « aller » signifie que seule la source initie. */
  function fluxEntrants(nom) {
    var a = state.acces || {}, mes = Object.create(null), out = [];
    var p = (state.peers || []).filter(function (x) { return x.name === nom; })[0];
    if (!p) { return out; }
    (p.groupes || []).forEach(function (g) { mes[g] = true; });
    (a.groupes || []).forEach(function (g) {
      (g.flux || []).forEach(function (f) {
        if (f.dest.indexOf("grp:") !== 0) { return; }
        if (!mes[f.dest.slice(4)]) { return; }
        out.push({groupe: g, flux: f});
      });
    });
    return out;
  }
  function ligneFlux(e, principal, secondaire, detail) {
    var l = el("div", "fiche-l");
    l.append(el("b", null, principal));
    if (secondaire) { l.append(el("span", "via", secondaire)); }
    if (detail) { l.append(el("span", "det", detail)); }
    e.appendChild(l);
  }
  function openAcces(nom) {
    openDialog("Accès de « " + nom + " »", function (b) {
      var a = state.acces || {}, mode = a.mode || "ouvert", noyau = a.noyau || "inconnu";
      var p = (state.peers || []).filter(function (x) { return x.name === nom; })[0] || {};
      var box = el("div", "fiche");

      /* L'avertissement d'abord : sans lui, la liste se lirait comme une restriction
         appliquée, alors que rien ne filtre encore. */
      if (mode !== "filtre") {
        var n = el("div", "fiche-note");
        n.textContent = "Aucun cloisonnement pour l'instant : cet appareil atteint tout, "
          + "quelles que soient les règles ci-dessous. Elles ne s'appliqueront qu'une fois "
          + "le filtrage activé sur le Pi.";
        box.appendChild(n);
      } else if (noyau !== "actif") {
        var n2 = el("div", "fiche-note bad");
        n2.textContent = "Les règles sont demandées mais ne sont PAS appliquées en ce moment : "
          + "cet appareil atteint tout.";
        box.appendChild(n2);
      }

      var g = groupesNommes(p);
      box.appendChild(el("h4", null, "Groupes"));
      if (g.length) {
        var lg = el("div", "fiche-badges");
        g.forEach(function (id, i) {
          var lib = ((a.groupes || []).filter(function (x) { return x.id === id; })[0] || {}).libelle || id;
          lg.appendChild(el("span", "badge grp " + mapGroupClass(a.groupes || [], id), lib));
          if (i === 0) { lg.title = ""; }
        });
        box.appendChild(lg);
      } else {
        box.appendChild(el("div", "fiche-vide", "Aucun groupe nommé. Cet appareil ne dépend que des règles qui portent sur « tous les appareils »."));
      }

      box.appendChild(el("h4", null, "Peut joindre"));
      var sortants = fluxSortants(nom);
      if (sortants.length) {
        sortants.forEach(function (x) {
          ligneFlux(box, x.flux.label, "par « " + x.groupe.libelle + " »", fluxTexte(x.flux));
        });
      } else {
        box.appendChild(el("div", "fiche-vide", mode === "filtre"
          ? "Rien. Avec le filtrage actif, cet appareil ne peut joindre aucune destination."
          : "Aucune règle ne concerne cet appareil."));
      }

      box.appendChild(el("h4", null, "Peut être joint par"));
      var entrants = fluxEntrants(nom);
      if (entrants.length) {
        entrants.forEach(function (x) {
          ligneFlux(box, "Le groupe « " + x.groupe.libelle + " »",
            x.flux.sens === "deux" ? "dans les deux sens" : "qui initie la connexion",
            fluxTexte(x.flux));
        });
      } else {
        box.appendChild(el("div", "fiche-vide", "Aucun autre appareil n'a de règle vers lui."));
      }

      /* Ce que le filtrage ne couvre pas, dit ici plutôt que découvert à ses frais. */
      var pi = el("div", "fiche-note");
      pi.textContent = "Les services qui tournent sur le Pi lui-même — SSH, ce panneau, "
        + "un conteneur Docker — restent joignables par tous vos appareils, quelles que "
        + "soient ces règles.";
      box.appendChild(pi);

      b.appendChild(box);
      var bar = el("div", "dlg-actions"), fermer = el("button", "btn ghost", "Fermer");
      fermer.type = "button";
      fermer.addEventListener("click", closeDialog);
      bar.appendChild(fermer);
      b.appendChild(bar);
    });
  }

  /* Couture de test. Dans un navigateur « module » n'existe pas, cette ligne est donc
     inerte ; sous node elle permet d'EXÉCUTER le rendu, et pas seulement de le parser.
     C'est ce qui attrape une variable non déclarée, qu'un simple « node --check » laisse
     passer et qui ne casserait qu'au premier rafraîchissement, chez l'utilisateur. */
  if (typeof module !== "undefined" && module.exports) {
    module.exports = {
      renderAcces: renderAcces,
      renderGroupes: renderGroupes,
      renderRegles: renderRegles,
      renderConfirmation: renderConfirmation,
      majBascule: majBascule,
      ouvrirAjoutMembre: ouvrirAjoutMembre,
      renderMap: renderMap,
      openAcces: openAcces,
      fluxSortants: fluxSortants,
      fluxEntrants: fluxEntrants,
      groupesNommes: groupesNommes,
      destRang: destRang,
      fluxTexte: fluxTexte,
      humanRate: humanRate,
      mapTier: mapTier,
      setState: function (d) { state = d; },
      mapReset: function () { mapFocus = null; },
      mapClick: function (node) { onMapClick({target: node}); },
      mapFocusKey: function () { return mapFocus; }
    };
  }

  /* ---- Accès ---- */
  /* Le panneau n'évalue RIEN : il affiche ce que « wg-pi json » a déjà résolu. Dupliquer
     ici l'évaluation des règles ferait dériver les deux implémentations, et la vue
     finirait par annoncer un cloisonnement que le pare-feu n'applique pas. */
  var DEST_RANG = {internet: 1, maison: 2, pi: 3};
  function destRang(d) {
    if (DEST_RANG[d]) { return DEST_RANG[d]; }
    return d.indexOf("res:") === 0 ? 4 : 5;
  }
  function fluxTexte(f) {
    var t = f.proto === "any" ? "tout" : f.proto;
    if (f.ports) { t += " " + f.ports; }
    if (f.sens === "deux") { t += " ⇄"; }
    return t;
  }
  function renderAcces() {
    var a = state.acces || {}, sect = $("p-acc");
    if (!sect) { return; }
    var groupes = a.groupes || [], pill = $("acc-state"), warn = $("acc-warn");

    /* L'état affiché vient du noyau, jamais d'un fichier de réglages : un panneau qui
       annonce « filtrage actif » sur la foi d'un fichier mentirait dès qu'un « ufw reload »
       ou un redémarrage de Docker a effacé les chaînes. */
    var mode = a.mode || "ouvert", noyau = a.noyau || "inconnu";
    warn.hidden = true;
    if (mode !== "filtre") {
      pill.textContent = "Aucun cloisonnement";
      pill.className = "pill";
    } else if (noyau === "actif") {
      pill.textContent = "Filtrage actif";
      pill.className = "pill ok";
    } else if (noyau === "inconnu") {
      pill.textContent = "Filtrage demandé";
      pill.className = "pill";
      warn.textContent = "L'état du pare-feu n'a pas pu être lu : impossible de confirmer que vos règles sont appliquées.";
      warn.hidden = false;
    } else {
      pill.textContent = "Règles non appliquées";
      pill.className = "pill bad";
      warn.textContent = "Vos règles ne sont PAS appliquées en ce moment : tous vos appareils peuvent se joindre. Lancez « sudo wg-pi access on » sur le Pi.";
      warn.hidden = false;
    }

    /* Colonnes : l'ensemble des destinations citées par au moins une règle. La matrice est
       donc en O(groupes x destinations) — quelques dizaines de cellules au plus, quel que
       soit le nombre d'appareils. */
    var dests = Object.create(null);
    groupes.forEach(function (g) {
      (g.flux || []).forEach(function (f) { dests[f.dest] = f.label; });
    });
    var cols = Object.keys(dests).sort(function (x, y) {
      var r = destRang(x) - destRang(y);
      return r !== 0 ? r : (dests[x] < dests[y] ? -1 : 1);
    });

    var box = $("acc-matrix");
    box.textContent = "";
    if (!cols.length) {
      var vide = el("div", "empty");
      vide.append(el("div", null, mode === "filtre"
        ? "Aucune règle : avec le filtrage actif, rien ne passerait."
        : "Aucune règle d'accès. Créez des groupes et des règles depuis le Pi : sudo wg-pi access allow"));
      box.appendChild(vide);
    } else {
      var tbl = el("table", "matrix"), thead = el("thead"), trh = el("tr");
      trh.appendChild(el("th", "corner", "Groupe"));
      cols.forEach(function (d) {
        var th = el("th", null, dests[d]);
        th.title = d;
        trh.appendChild(th);
      });
      thead.appendChild(trh);
      tbl.appendChild(thead);
      var tb = el("tbody");
      groupes.forEach(function (g) {
        var tr = el("tr"), nb = (g.appareils || []).length;
        var th = el("th");
        th.appendChild(el("b", null, g.libelle));
        th.appendChild(el("small", null, nb + (nb === 1 ? " appareil" : " appareils")));
        if (g.auto) { th.appendChild(el("small", "auto", "automatique")); }
        th.title = (g.appareils || []).join(", ");
        tr.appendChild(th);
        cols.forEach(function (d) {
          var f = (g.flux || []).filter(function (x) { return x.dest === d; })[0];
          var td = el("td");
          if (f) {
            td.className = "yes";
            td.appendChild(el("span", null, fluxTexte(f)));
            td.title = f.titre || "";
          } else {
            td.className = "no";
            td.setAttribute("aria-label", "aucune règle");
          }
          tr.appendChild(td);
        });
        tb.appendChild(tr);
      });
      tbl.appendChild(tb);
      box.appendChild(tbl);
    }

    /* Les ports en écoute sur le Pi : la partie « les accès derrière » que personne ne
       voit. Un service publié sur toutes les interfaces, par exemple un conteneur Docker,
       est atteignable par chacun des appareils du VPN. */
    var note = $("acc-listen"), ports = a.ecoute || [];
    if (ports.length) {
      note.textContent = "Ports en écoute sur le Pi, joignables depuis le VPN : " + ports.join(", ")
        + " — un service publié sur toutes les interfaces, par exemple un conteneur Docker, est atteignable par chacun de vos appareils.";
      note.hidden = false;
    } else {
      note.hidden = true;
    }
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
    r.spark = svgEl("svg", "spark");
    r.spark.setAttribute("viewBox", "0 0 100 30");
    r.spark.setAttribute("preserveAspectRatio", "none");
    r.spark.setAttribute("aria-hidden", "true");
    r.area = svgEl("path");
    r.spark.appendChild(r.area);
    r.avatar = el("div", "avatar");
    r.ini = el("span");
    r.avatar.append(r.ini, el("span", "dot"));
    var info = el("div", "info"), l1 = el("div", "l1");
    r.nameEl = el("span", "name"); r.mode = el("span", "badge"); r.off = el("span", "badge off", "Désactivé");
    r.grp = el("span", "badge grp");
    l1.append(r.nameEl, r.mode, r.grp, r.off);
    r.ips = el("span", "ips mono"); r.status = el("span", "status");
    var l2 = el("div", "l2"); l2.append(r.ips, r.status);
    info.append(l1, l2);
    r.traffic = el("div", "traffic"); r.rates = el("div", "rates"); r.totals = el("div", "totals");
    r.traffic.append(r.rates, r.totals);
    var act = el("div", "actions"), sw = el("label", "switch");
    r.toggle = el("input"); r.toggle.type = "checkbox";
    sw.append(r.toggle, el("span", "slider"));
    r.acc = iconBtn("acces", "Ce que cet appareil peut joindre");
    r.acc.addEventListener("click", function () { openAcces(r.name); });
    r.qr = iconBtn("qr", "QR code"); r.ren = iconBtn("edit", "Renommer");
    r.dl = el("a", "icon-btn"); r.dl.innerHTML = ICONS.download;
    r.dl.title = "Télécharger le fichier .conf"; r.dl.setAttribute("aria-label", r.dl.title);
    r.del = iconBtn("trash", "Supprimer", "danger");
    /* Marquées « data-admin » : masquées pour un compte de consultation, parce qu'elles
       ne feraient rien. Le refus réel est côté serveur — la garde unique de do_POST pour
       les mutations, et le refus des deux GET pour le .conf et le QR code, qui
       contiennent la clé privée de l'appareil. */
    [sw, r.qr, r.ren, r.dl, r.del].forEach(function (e) { e.setAttribute("data-admin", ""); });
    act.append(sw, r.acc, r.qr, r.ren, r.dl, r.del);
    /* Le sparkline est POSE EN SUPERPOSITION, hors de la grille : « r.main » porte seul
       la mise en colonnes. Si « position:absolute » venait a ne pas s appliquer, la
       grille resterait intacte au lieu de se decaler d une colonne. */
    r.main = el("div", "row-main");
    r.main.append(r.avatar, info, r.traffic, act);
    r.el.append(r.spark, r.main);
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
    /* La pastille ne montre que les groupes NOMMÉS : « tous » contient tout le monde, donc
       l'afficher sur chaque ligne n'apprendrait rien. */
    var gs = groupesNommes(p), acc = state.acces || {};
    r.grp.hidden = !gs.length;
    if (gs.length) {
      r.grp.textContent = gs.map(function (id) {
        return ((acc.groupes || []).filter(function (x) { return x.id === id; })[0] || {}).libelle || id;
      }).join(" · ");
      r.grp.className = "badge grp " + mapGroupClass(acc.groupes || [], gs[0]);
      r.grp.title = gs.length === 1 ? "Groupe de cet appareil" : "Groupes de cet appareil";
    }
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
          b.setAttribute("data-admin", "");
          b.addEventListener("click", openNew); empty.append(b);
        }
      }
      if (empty.parentNode !== list) { list.appendChild(empty); }
    } else if (empty) { empty.remove(); }
    /* ne réordonne le DOM que si l'ordre a changé (évite de perdre le focus) */
    var current = Array.prototype.filter.call(list.children, function (c) { return c.id !== "empty"; });
    var same = current.length === wanted.length && wanted.every(function (e, i) { return current[i] === e; });
    if (!same) { wanted.forEach(function (e) { list.appendChild(e); }); }
    $("count").textContent = state.peers.length ? String(state.peers.length) : "";
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

  /* ---- Groupes, ressources et règles ---- */
  /* Tout passe par les routes du panneau, qui appellent wg-pi. Rien n'est écrit ici :
     le JavaScript propose, le script dispose — et c'est lui qui tient le verrou. */
  function acces() { return (state && state.acces) || {}; }
  function groupesTous() { return acces().groupes || []; }
  function groupesNommesListe() {
    return groupesTous().filter(function (g) { return !g.auto; });
  }
  function regleToutes() {
    var out = [];
    groupesTous().forEach(function (g) {
      (g.flux || []).forEach(function (f) { out.push({groupe: g, flux: f}); });
    });
    return out;
  }
  function libelleProto(f) {
    if (f.proto === "any" || !f.proto) { return "tous les ports"; }
    if (!f.ports) { return f.proto.toUpperCase(); }
    return f.proto.toUpperCase() + " " + f.ports;
  }
  /* « data-admin » va sur le BOUTON de retrait, jamais sur la pastille : posé sur la
     pastille, il masquait le nom de l'appareil lui-même, et un compte de consultation
     voyait tous les groupes vides — c'est-à-dire un mensonge, pas une restriction. */
  function puce(texte, surRetrait) {
    var c = el("span", "chip" + (surRetrait ? "" : " plain"), texte);
    if (surRetrait) {
      var x = el("button", null, "×");
      x.type = "button"; x.title = "Retirer"; x.setAttribute("aria-label", "Retirer " + texte);
      x.setAttribute("data-admin", "");
      x.addEventListener("click", function () { surRetrait(x); });
      c.append(x);
    }
    return c;
  }
  /* Un envoi en cours désactive son bouton. Sans cela, deux clics rapides font deux
     écritures — et chacune réarme le minuteur d'annulation de deux minutes. */
  function envoiUnique(bouton, lancer) {
    if (!bouton || bouton.disabled) { return; }
    bouton.disabled = true;
    lancer().catch(function (x) {
      if (x && x.message !== "session") { toast(x.message, true); }
    }).then(function () { bouton.disabled = false; });
  }
  /* Un rendu qui reconstruit son conteneur alors que rien n'a changé vole le focus et
     avale les clics : le relevé tourne toutes les deux secondes, et il suffit de viser
     « Supprimer » au mauvais moment. On ne redessine que sur changement réel. */
  var signatures = Object.create(null);
  function inchange(cle, valeur) {
    if (signatures[cle] === valeur) { return true; }
    signatures[cle] = valeur;
    return false;
  }
  function boutonTexte(libelle, classe, action) {
    var b = el("button", "btn " + classe, libelle);
    b.type = "button";
    b.setAttribute("data-admin", "");
    b.addEventListener("click", function () { action(b); });
    return b;
  }
  /* Une écriture a abouti : on prévient, on signale une application ratée, et on
     rafraîchit. L'avertissement n'est PAS avalé : une règle enregistrée mais non
     appliquée doit se voir, sinon le panneau laisserait croire qu'elle protège. */
  function apresEcriture(d, message) {
    toast(message);
    if (d && d.avertissement) { toast(d.avertissement, true); }
    /* Le bandeau de confirmation se déduit de l'état renvoyé par le serveur, donc il
       apparaîtra au prochain relevé. Le dire tout de suite évite deux secondes pendant
       lesquelles un minuteur est armé sans que rien à l'écran ne le laisse voir. */
    if (d && d.aconfirmer) {
      toast("Règles appliquées : confirmez dans les deux minutes, sinon tout revient en arrière.");
    }
    poll();
  }

  function renderGroupes() {
    var box = $("grp-list"), rbox = $("res-list");
    if (!box || !rbox) { return; }
    var nommes = groupesNommesListe(), res = acces().ressources || [];
    $("c-grp").textContent = nommes.length ? String(nommes.length) : "";
    $("c-acc").textContent = regleToutes().length ? String(regleToutes().length) : "";
    if (inchange("groupes", JSON.stringify([nommes, res]))) { return; }

    box.textContent = "";
    if (!nommes.length) {
      box.append(el("p", "regle-vide", "Aucun groupe pour l instant. Créez-en un, puis glissez-y des appareils."));
    }
    nommes.forEach(function (g) {
      var tuile = el("div", "tile"), tete = el("div");
      tete.append(el("b", null, g.libelle), el("div", "sub", g.id));
      var ch = el("div", "chips");
      (g.appareils || []).forEach(function (d) {
        ch.append(puce(d, function (bouton) { quitterGroupe(d, g, bouton); }));
      });
      if (!(g.appareils || []).length) { ch.append(puce("aucun appareil", null)); }
      var fin = el("div", "push");
      fin.append(boutonTexte("Ajouter un appareil", "ghost", function () { ouvrirAjoutMembre(g); }),
                 boutonTexte("Supprimer", "ghost danger", function () { ouvrirSupprGroupe(g); }));
      tuile.append(tete, ch, fin);
      box.append(tuile);
    });

    rbox.textContent = "";
    if (!res.length) {
      rbox.append(el("p", "regle-vide", "Aucune ressource. Nommez une machine de la maison pour pouvoir y donner accès."));
    }
    res.forEach(function (r) {
      var tuile = el("div", "tile"), tete = el("div");
      tete.append(el("b", null, r.libelle), el("div", "sub mono", r.cible + " · " + r.id));
      var fin = el("div", "push");
      fin.append(boutonTexte("Supprimer", "ghost danger", function () { ouvrirSupprRessource(r); }));
      tuile.append(tete, fin);
      rbox.append(tuile);
    });
  }

  function renderRegles() {
    var box = $("acc-rules");
    if (!box) { return; }
    var toutes = regleToutes();
    if (inchange("regles", JSON.stringify(toutes))) { return; }
    box.textContent = "";
    if (!toutes.length) {
      box.append(el("p", "regle-vide", "Aucune règle. Tant qu il n y en a pas, activer le filtrage couperait tout."));
      return;
    }
    toutes.forEach(function (x) {
      var l = el("div", "regle");
      l.append(el("span", "chip plain", x.groupe.libelle), el("span", "fleche", "→"),
               el("b", null, x.flux.label), el("span", "chip plain", libelleProto(x.flux)));
      if (x.flux.sens === "deux") { l.append(el("span", "chip plain", "les deux sens")); }
      var fin = el("div", "push");
      fin.append(boutonTexte("Supprimer", "ghost danger", function () { ouvrirSupprRegle(x); }));
      l.append(fin);
      box.append(l);
    });
  }

  /* ---- Fenêtres de création ---- */
  function champ(id, libelle, aide, valeur, gabarit) {
    var enveloppe = el("div"), lab = el("label", "field", libelle), inp = el("input");
    lab.htmlFor = id;
    inp.id = id; inp.type = "text"; inp.value = valeur || ""; inp.autocomplete = "off";
    inp.spellcheck = false; inp.setAttribute("autocapitalize", "off");
    if (gabarit) { inp.pattern = gabarit; }
    enveloppe.append(lab, inp);
    if (aide) { enveloppe.append(el("div", "hint", aide)); }
    return {bloc: enveloppe, input: inp};
  }
  function liste(id, libelle, options, valeur) {
    var enveloppe = el("div"), lab = el("label", "field", libelle), sel = el("select");
    lab.htmlFor = id; sel.id = id;
    options.forEach(function (o) {
      var op = el("option", null, o.texte);
      op.value = o.valeur;
      if (o.valeur === valeur) { op.selected = true; }
      sel.append(op);
    });
    enveloppe.append(lab, sel);
    return {bloc: enveloppe, select: sel};
  }

  function ouvrirNouveauGroupe() {
    openDialog("Nouveau groupe", function (b) {
      var f = el("form", "form");
      var nom = champ("grp-id", "Nom court", "1 à 15 caractères : lettres, chiffres, - et _.", "",
                      "[A-Za-z0-9_][A-Za-z0-9_-]{0,14}");
      nom.input.required = true; nom.input.maxLength = 15; nom.input.placeholder = "ex. famille, invites";
      var lib = champ("grp-lib", "Libellé affiché", "Facultatif. Ce que vous lirez dans le panneau.", "");
      lib.input.maxLength = 60; lib.input.placeholder = "ex. Ma famille";
      var err = errorBox(), act = actionsBar("Annuler", "Créer le groupe", "primary");
      f.append(nom.bloc, lib.bloc, err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", "/api/groupes", {id: nom.input.value.trim(), libelle: lib.input.value.trim()})
          .then(function (d) {
            if (f.isConnected) { closeDialog(); }
            apresEcriture(d, "Groupe créé");
          }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
      setTimeout(function () { nom.input.focus(); }, 30);
    });
  }

  function ouvrirNouvelleRessource() {
    openDialog("Nouvelle ressource", function (b) {
      var f = el("form", "form");
      var nom = champ("res-id", "Nom court", "1 à 15 caractères : lettres, chiffres, - et _.", "",
                      "[A-Za-z0-9_][A-Za-z0-9_-]{0,14}");
      nom.input.required = true; nom.input.maxLength = 15; nom.input.placeholder = "ex. nas, imprimante";
      var cible = champ("res-ip", "Adresse ou réseau", "Exemples : 192.168.1.20 ou 192.168.1.64/28.", "");
      cible.input.required = true; cible.input.placeholder = "192.168.1.20";
      var lib = champ("res-lib", "Libellé affiché", "Facultatif.", "");
      lib.input.maxLength = 60; lib.input.placeholder = "ex. Le NAS";
      var err = errorBox(), act = actionsBar("Annuler", "Créer la ressource", "primary");
      f.append(nom.bloc, cible.bloc, lib.bloc, err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", "/api/ressources", {id: nom.input.value.trim(), cible: cible.input.value.trim(),
                                        libelle: lib.input.value.trim()})
          .then(function (d) {
            if (f.isConnected) { closeDialog(); }
            apresEcriture(d, "Ressource créée");
          }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
      setTimeout(function () { nom.input.focus(); }, 30);
    });
  }

  function destinationsPossibles() {
    var out = [{valeur: "internet", texte: "Internet"},
               {valeur: "maison", texte: "Le réseau de la maison"},
               {valeur: "pi", texte: "Le Pi lui-même"}];
    (acces().ressources || []).forEach(function (r) {
      out.push({valeur: "res:" + r.id, texte: "Ressource : " + r.libelle});
    });
    groupesTous().forEach(function (g) {
      out.push({valeur: "grp:" + g.id, texte: "Groupe : " + g.libelle});
    });
    return out;
  }

  function ouvrirNouvelleRegle() {
    openDialog("Nouvelle règle d accès", function (b) {
      var f = el("form", "form");
      var sources = groupesTous().map(function (g) { return {valeur: g.id, texte: g.libelle}; });
      if (!sources.length) {
        b.append(el("p", null, "Créez d abord un groupe : une règle part toujours d un groupe d appareils."));
        return;
      }
      var src = liste("reg-src", "Qui ?", sources, sources[0].valeur);
      var dst = liste("reg-dst", "Peut joindre quoi ?", destinationsPossibles(), "internet");
      var proto = liste("reg-proto", "Protocole", [
        {valeur: "any", texte: "Tous (et tous les ports)"},
        {valeur: "tcp", texte: "TCP"}, {valeur: "udp", texte: "UDP"}, {valeur: "icmp", texte: "ICMP (ping)"}
      ], "any");
      var ports = champ("reg-ports", "Ports", "Avec TCP ou UDP. Exemples : 445 ou 445,5000-5001. Vide = tous.", "");
      ports.input.placeholder = "445,5000-5001";
      ports.input.maxLength = 120;   /* le corps des requêtes est borné à 4096 octets */
      var sens = liste("reg-sens", "Sens", [
        {valeur: "aller", texte: "Aller simple : la source appelle"},
        {valeur: "deux", texte: "Les deux sens (entre groupes seulement)"}
      ], "aller");
      var lib = champ("reg-lib", "Libellé affiché", "Facultatif.", "");
      lib.input.maxLength = 60;
      var grille = el("div", "grid-form");
      grille.append(src.bloc, dst.bloc, proto.bloc, ports.bloc, sens.bloc);
      var note = el("div", "hint");
      /* « deux sens » n'a de sens qu'entre groupes : vers Internet ou la maison, le
         retour ne repasse pas par le VPN et wg-pi ne peut rien en promettre. */
      function majSens() {
        var versGroupe = dst.select.value.indexOf("grp:") === 0;
        sens.select.disabled = !versGroupe;
        if (!versGroupe) { sens.select.value = "aller"; }
        var avecPorts = proto.select.value === "tcp" || proto.select.value === "udp";
        ports.input.disabled = !avecPorts;
        if (!avecPorts) { ports.input.value = ""; }
        note.textContent = versGroupe ? "" :
          "Les deux sens ne sont proposés qu entre groupes : ailleurs, le trafic de retour ne passe pas par le VPN.";
      }
      dst.select.addEventListener("change", majSens);
      proto.select.addEventListener("change", majSens);
      majSens();
      var err = errorBox(), act = actionsBar("Annuler", "Créer la règle", "primary");
      f.append(grille, note, lib.bloc, err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", "/api/regles", {source: src.select.value, destination: dst.select.value,
                                    proto: proto.select.value, ports: ports.input.value.trim(),
                                    sens: sens.select.value, libelle: lib.input.value.trim()})
          .then(function (d) {
            if (f.isConnected) { closeDialog(); }
            apresEcriture(d, "Règle créée");
          }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
    });
  }

  function ouvrirAjoutMembre(g) {
    /* Object.create(null) et non « {} » : un appareil nomme « constructor » ou
       « toString » heritait d une valeur vraie du prototype, et n etait donc jamais
       propose a l ajout. */
    var dedans = Object.create(null);
    (g.appareils || []).forEach(function (d) { dedans[d] = true; });
    var libres = ((state && state.peers) || []).filter(function (p) { return !dedans[p.name]; });
    openDialog("Ajouter un appareil à « " + g.libelle + " »", function (b) {
      if (!libres.length) {
        b.append(el("p", null, "Tous vos appareils sont déjà dans ce groupe."));
        return;
      }
      var f = el("form", "form");
      var sel = liste("grp-dev", "Appareil", libres.map(function (p) {
        return {valeur: p.name, texte: p.name};
      }), libres[0].name);
      var err = errorBox(), act = actionsBar("Annuler", "Ajouter", "primary");
      f.append(sel.bloc, err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", "/api/groupes/" + encodeURIComponent(g.id) + "/join", {appareil: sel.select.value})
          .then(function (d) {
            if (f.isConnected) { closeDialog(); }
            apresEcriture(d, "Appareil ajouté");
          }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
    });
  }

  function quitterGroupe(appareil, g, bouton) {
    envoiUnique(bouton, function () {
      return api("POST", "/api/groupes/" + encodeURIComponent(g.id) + "/leave", {appareil: appareil})
        .then(function (d) { apresEcriture(d, "« " + appareil + " » retiré de « " + g.libelle + " »"); });
    });
  }

  /* « corps » n'est pas facultatif par confort : /api/filtrage EXIGE une action, et
     l'oublier faisait répondre 400 « Action inconnue. » au bouton « Couper le filtrage »
     — le seul moyen, depuis le navigateur, de défaire un cloisonnement qui vous enferme. */
  function confirmer(titre, texte, bouton, url, message, corps) {
    openDialog(titre, function (b) {
      var f = el("form", "form"), err = errorBox(), act = actionsBar("Annuler", bouton, "danger");
      f.append(el("p", null, texte), err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", url, corps || {}).then(function (d) {
          if (f.isConnected) { closeDialog(); }
          apresEcriture(d, message);
        }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
    });
  }
  function ouvrirSupprGroupe(g) {
    confirmer("Supprimer le groupe « " + g.libelle + " » ?",
              "Les appareils ne sont pas supprimés : ils sortent simplement du groupe. " +
              "Un groupe encore cité par une règle ne peut pas être supprimé.",
              "Supprimer le groupe", "/api/groupes/" + encodeURIComponent(g.id) + "/delete",
              "Groupe supprimé");
  }
  function ouvrirSupprRessource(r) {
    confirmer("Supprimer la ressource « " + r.libelle + " » ?",
              "La machine n est pas touchée : seul son nom dans wg-pi disparaît. " +
              "Une ressource encore citée par une règle ne peut pas être supprimée.",
              "Supprimer la ressource", "/api/ressources/" + encodeURIComponent(r.id) + "/delete",
              "Ressource supprimée");
  }
  function ouvrirSupprRegle(x) {
    confirmer("Supprimer cette règle ?",
              "« " + x.groupe.libelle + " » ne pourra plus joindre « " + x.flux.label + " ».",
              "Supprimer la règle", "/api/regles/" + encodeURIComponent(x.flux.id) + "/delete",
              "Règle supprimée");
  }

  /* ---- Activer ou couper le filtrage ---- */
  function ouvrirBascule() {
    var actif = acces().mode === "filtre";
    if (actif) {
      confirmer("Couper le filtrage ?",
                "Tous vos appareils pourront de nouveau se joindre entre eux et joindre la maison. " +
                "Vos groupes et vos règles sont conservés : vous pourrez les réactiver.",
                "Couper le filtrage", "/api/filtrage", "Filtrage coupé", {action: "off"});
      return;
    }
    openDialog("Activer le filtrage ?", function (b) {
      var f = el("form", "form"), err = errorBox();
      var act = actionsBar("Annuler", "Activer le filtrage", "primary");
      f.append(el("p", null, "À partir de maintenant, seules vos règles passeront : tout le reste sera refusé " +
                             "entre appareils."),
               el("p", null, "wg-pi arme un retour arrière automatique de deux minutes. Si vous perdez la main, " +
                             "ne touchez à rien : l état précédent revient tout seul. Si tout va bien, confirmez " +
                             "avec le bouton qui apparaîtra."),
               err, act.bar);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        if (act.ok.disabled) { return; }
        act.ok.disabled = true; err.hidden = true;
        api("POST", "/api/filtrage", {action: "on"}).then(function (d) {
          if (f.isConnected) { closeDialog(); }
          apresEcriture(d, "Filtrage activé : confirmez dans les deux minutes.");
        }).catch(function (x) { showError(f, err, act.ok, x); });
      });
      b.append(f);
    });
  }

  /* Bandeau de confirmation : il doit survivre à un rechargement de page, donc son
     affichage est déduit de l'état renvoyé par le serveur, jamais d'une variable locale. */
  function renderConfirmation() {
    var box = $("acc-confirm");
    if (!box) { return; }
    var a = acces();
    box.textContent = "";
    if (a.mode !== "filtre" || a.confirme !== false) { box.hidden = true; return; }
    var l = el("div", "alert-ligne");
    l.append(el("b", null, "Filtrage en attente de confirmation."),
             el("span", null, "Sans confirmation, wg-pi rétablira tout seul l état précédent."),
             boutonTexte("Tout va bien, confirmer", "primary", function (bouton) {
               envoiUnique(bouton, function () {
                 return api("POST", "/api/filtrage", {action: "confirm"})
                   .then(function (d) { apresEcriture(d, "Filtrage confirmé"); });
               });
             }));
    box.append(l);
    box.hidden = false;
  }

  function majBascule() {
    var b = $("acc-switch");
    if (!b) { return; }
    var actif = acces().mode === "filtre";
    b.textContent = actif ? "Couper le filtrage" : "Activer le filtrage";
    b.className = "btn " + (actif ? "ghost danger" : "ghost");
  }

  /* ---- Onglets ---- */
  var ONGLETS = ["app", "grp", "acc", "map", "srv"], ongletCourant = "app";
  function montrerOnglet(cle) {
    if (ONGLETS.indexOf(cle) < 0) { cle = "app"; }
    ongletCourant = cle;
    ONGLETS.forEach(function (c) {
      var b = $("t-" + c), p = $("p-" + c), actif = (c === cle);
      b.setAttribute("aria-selected", String(actif));
      b.tabIndex = actif ? 0 : -1;
      p.hidden = !actif;
    });
    try { localStorage.setItem("wgpi-onglet", cle); } catch (e) { /* navigation privee */ }
    /* La carte se mesure a l affichage : la dessiner pendant que son volet est
       cache donnerait une largeur nulle et une carte vide. */
    if (cle === "map" && state) { renderMap(); }
  }
  ONGLETS.forEach(function (c) {
    $("t-" + c).addEventListener("click", function () { montrerOnglet(c); });
  });
  $("tabs").addEventListener("keydown", function (ev) {
    var d = ev.key === "ArrowRight" ? 1 : (ev.key === "ArrowLeft" ? -1 : 0);
    if (!d) { return; }
    ev.preventDefault();
    var i = (ONGLETS.indexOf(ongletCourant) + d + ONGLETS.length) % ONGLETS.length;
    montrerOnglet(ONGLETS[i]);
    $("t-" + ONGLETS[i]).focus();
  });
  try { montrerOnglet(localStorage.getItem("wgpi-onglet") || "app"); }
  catch (e) { montrerOnglet("app"); }

  /* ---- Barre d'outils ---- */
  $("new").addEventListener("click", openNew);
  $("grp-new").addEventListener("click", ouvrirNouveauGroupe);
  $("res-new").addEventListener("click", ouvrirNouvelleRessource);
  $("rule-new").addEventListener("click", ouvrirNouvelleRegle);
  $("acc-switch").addEventListener("click", ouvrirBascule);
  $("search").addEventListener("input", function (e) { query = e.target.value; if (state) { renderList(); } });
  $("sort").addEventListener("change", function (e) { sortKey = e.target.value; if (state) { renderList(); } });
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
    # data-role est PUREMENT COSMETIQUE : il sert à masquer des boutons qui ne feraient
    # rien. La vraie application est la garde unique de do_POST et le refus des deux GET
    # qui exposent une clé privée. Masquer un bouton n'a jamais protégé une route.
    role = sess.get("role", "lecture")
    return head("Appareils", sess["csrf"]) + f"""<body data-role="{esc(role)}">
<header class="top"><div class="wrap bar">
<a class="brand" href="/">{LOGO}<b>wg-pi</b><small>VPN WireGuard®</small></a>
<div class="tools">
<button type="button" class="icon-btn" id="theme" aria-label="Changer de thème"></button>
<button type="button" class="btn ghost" id="logout" data-icon="logout"><span class="hide-sm">Déconnexion</span></button>
</div></div></header>
<main class="wrap">
<div class="alert" id="alert" role="alert" hidden></div>
<p class="ro-note">Compte de consultation : vous pouvez tout voir, mais rien modifier. Les configurations et les QR codes ne sont pas téléchargeables, car ils contiennent la clé privée de l'appareil.</p>
<section class="card server" aria-label="Serveur">
<div class="srv-main">
<span class="pill ok" id="srv-state">Chargement…</span>
<div class="kv"><span>Adresse publique</span><b class="mono" id="srv-endpoint">…</b></div>
<div class="kv"><span>Réseau du VPN</span><b class="mono" id="srv-net">…</b></div>
<div class="kv"><span>Connectés</span><b id="srv-online">…</b></div>
<span class="pill push" id="srv-filtre" hidden>…</span>
</div></section>
<nav class="tabs" id="tabs" role="tablist" aria-label="Sections du panneau">
<button type="button" role="tab" id="t-app" aria-controls="p-app" aria-selected="true">Appareils<span class="tcount" id="count"></span></button>
<button type="button" role="tab" id="t-grp" aria-controls="p-grp" aria-selected="false" tabindex="-1">Groupes<span class="tcount" id="c-grp"></span></button>
<button type="button" role="tab" id="t-acc" aria-controls="p-acc" aria-selected="false" tabindex="-1">Accès<span class="tcount" id="c-acc"></span></button>
<button type="button" role="tab" id="t-map" aria-controls="p-map" aria-selected="false" tabindex="-1">Carte</button>
<button type="button" role="tab" id="t-srv" aria-controls="p-srv" aria-selected="false" tabindex="-1">Serveur</button>
</nav>
<section class="card clients pan" id="p-app" role="tabpanel" aria-labelledby="t-app">
<div class="clients-head"><h2>Appareils</h2>
<div class="clients-tools">
<label class="search" data-icon="search"><input type="search" id="search" placeholder="Rechercher…" aria-label="Rechercher un appareil" autocomplete="off"></label>
<select id="sort" aria-label="Trier les appareils"><option value="name">Nom</option><option value="seen">Dernière connexion</option><option value="traffic">Trafic</option></select>
<button type="button" class="btn primary" id="new" data-icon="plus" data-admin><span>Nouvel appareil</span></button>
</div></div>
<div id="list"></div>
</section>
<section class="card pan" id="p-grp" role="tabpanel" aria-labelledby="t-grp" hidden>
<div class="secbox">
<div class="sec-head"><h3>Groupes</h3>
<button type="button" class="btn primary" id="grp-new" data-icon="plus" data-admin><span>Nouveau groupe</span></button></div>
<p class="acc-note">Un groupe rassemble des appareils pour leur donner les mêmes droits. Le groupe « tous » existe toujours et contient chaque appareil.</p>
<div id="grp-list"></div>
</div>
<div class="secbox">
<div class="sec-head"><h3>Ressources</h3>
<button type="button" class="btn primary" id="res-new" data-icon="plus" data-admin><span>Nouvelle ressource</span></button></div>
<p class="acc-note">Une ressource est une machine ou un réseau de la maison que vous nommez une fois pour y donner accès ensuite : le NAS, une imprimante, la box…</p>
<div id="res-list"></div>
</div>
</section>
<section class="card acces pan" id="p-acc" role="tabpanel" aria-labelledby="t-acc" hidden>
<div class="clients-head"><h2>Règles d accès <span class="pill" id="acc-state">…</span></h2>
<div class="clients-tools">
<button type="button" class="btn ghost" id="acc-switch" data-admin><span>…</span></button>
<button type="button" class="btn primary" id="rule-new" data-icon="plus" data-admin><span>Nouvelle règle</span></button>
</div></div>
<div class="alert" id="acc-warn" role="status" hidden></div>
<div class="alert" id="acc-confirm" role="status" hidden></div>
<div id="acc-matrix"></div>
<div id="acc-rules"></div>
<p class="acc-note" id="acc-listen" hidden></p>
</section>
<section class="card pan" id="p-map" role="tabpanel" aria-labelledby="t-map" hidden>
<div class="clients-head"><h2>Carte des accès</h2></div>
<div id="map-box" aria-label="Carte des accès"></div>
<p class="acc-note" id="map-legend" hidden></p>
</section>
<section class="card pan" id="p-srv" role="tabpanel" aria-labelledby="t-srv" hidden>
<div class="clients-head"><h2>Serveur</h2></div>
<div class="srv-details" id="srv-details">
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
            # Par défaut « lecture » et non « admin » : une session sans rôle explicite,
            # par exemple créée par une version antérieure, ne doit pas donner les pleins
            # pouvoirs.
            return {"token": token, "csrf": s["csrf"], "role": s.get("role", "lecture")}

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
            # Les deux seuls GET à protéger : le fichier .conf et le QR code contiennent la
            # CLÉ PRIVÉE de l'appareil. Un compte de consultation qui pourrait les
            # télécharger pourrait connecter un nouvel appareil, ce qui n'est pas « regarder ».
            # /api/state, lui, convient aux deux rôles.
            if sess.get("role") != "admin":
                return self.send(403, "Compte de consultation : cette configuration contient une clé privée.\n",
                                 "text/plain; charset=utf-8")
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
            # En JSON : le panneau lit « error ». Un texte brut lui faisait afficher
            # « Erreur 413 », qui n apprend rien a personne.
            return self.send_json(413, {"error": "Requête trop volumineuse : raccourcissez votre saisie."})
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
        # UN SEUL point d'application : toutes les mutations du panneau sont des POST, et
        # tous les POST franchissent cette ligne. Elle couvre donc les routes actuelles ET
        # toutes celles à venir, sans qu'il faille y penser. Ne JAMAIS disséminer de
        # vérification par route : c'est ainsi qu'on finit par en oublier une.
        if sess.get("role") != "admin" and path != "/api/logout":
            return self.send_json(403, {"error": "Compte de consultation : modification impossible."})
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

        # ---- Groupes, ressources et règles ----
        # Toutes passent par le CLI : le panneau n'écrit JAMAIS access.conf lui-même.
        # Une seconde écriture du même fichier dériverait de la première au premier
        # changement de format, et le verrou de wg-pi ne protégerait plus rien.
        if path == "/api/groupes":
            gid = str(body.get("id", "")).strip()
            lib = str(body.get("libelle", "")).strip()
            if not ACCES_ID_RE.fullmatch(gid):
                return self.send_json(400, {"error": "Nom de groupe invalide : 1 à 15 caractères parmi "
                                                     "lettres, chiffres, - et _ (sans tiret au début)."})
            if not libelle_ok(lib):
                return self.send_json(400, {"error": "Libellé invalide : au plus 60 caractères, sans barre verticale."})
            # « group add » est un enregistrement : sur un nom déjà pris, il remplace le
            # libellé sans rien demander. En ligne de commande c'est pratique ; derrière
            # un bouton « Nouveau groupe », c'est une surprise. On refuse.
            if any(g.get("id") == gid for g in acces_vue().get("groupes", [])):
                return self.send_json(409, {"error": f"Un groupe « {gid} » existe déjà."})
            args = ["group", "add", gid] + (["--libelle=" + lib] if lib else [])
            return self.mutate_acces(args, f"groupe « {gid} » créé")
        m = re.fullmatch(r"/api/groupes/([A-Za-z0-9_][A-Za-z0-9_-]{0,14})/(delete|join|leave)", path)
        if m:
            gid, action = m.groups()
            if action == "delete":
                return self.mutate_acces(("group", "rm", gid), f"groupe « {gid} » supprimé")
            dev = str(body.get("appareil", "")).strip()
            if not NAME_RE.fullmatch(dev) or dev.startswith("-"):
                return self.send_json(400, {"error": "Appareil invalide."})
            quoi = "ajouté au" if action == "join" else "retiré du"
            return self.mutate_acces(("group", action, dev, gid), f"« {dev} » {quoi} groupe « {gid} »")
        if path == "/api/ressources":
            rid = str(body.get("id", "")).strip()
            cible = str(body.get("cible", "")).strip()
            lib = str(body.get("libelle", "")).strip()
            if not ACCES_ID_RE.fullmatch(rid):
                return self.send_json(400, {"error": "Nom de ressource invalide : 1 à 15 caractères parmi "
                                                     "lettres, chiffres, - et _ (sans tiret au début)."})
            if not CIBLE_RE.fullmatch(cible):
                return self.send_json(400, {"error": "Adresse invalide (exemples : 192.168.1.20 ou 192.168.1.64/28)."})
            if not libelle_ok(lib):
                return self.send_json(400, {"error": "Libellé invalide : au plus 60 caractères, sans barre verticale."})
            # Plus grave encore que pour un groupe : réutiliser un nom de ressource
            # repointerait TOUTES les règles « res:<nom> » vers une autre machine, sans
            # que la liste des règles change d'un caractère.
            if any(r.get("id") == rid for r in acces_vue().get("ressources", [])):
                return self.send_json(409, {"error": f"Une ressource « {rid} » existe déjà. "
                                                     f"Supprimez-la d'abord si vous voulez la faire pointer ailleurs."})
            args = ["resource", "add", rid, cible] + (["--libelle=" + lib] if lib else [])
            return self.mutate_acces(args, f"ressource « {rid} » créée")
        m = re.fullmatch(r"/api/ressources/([A-Za-z0-9_][A-Za-z0-9_-]{0,14})/delete", path)
        if m:
            return self.mutate_acces(("resource", "rm", m.group(1)), f"ressource « {m.group(1)} » supprimée")
        if path == "/api/regles":
            src = str(body.get("source", "")).strip()
            dst = str(body.get("destination", "")).strip()
            proto = str(body.get("proto", "any")).strip() or "any"
            ports = str(body.get("ports", "")).strip()
            sens = str(body.get("sens", "aller")).strip() or "aller"
            lib = str(body.get("libelle", "")).strip()
            if not ACCES_ID_RE.fullmatch(src):
                return self.send_json(400, {"error": "Groupe source invalide."})
            if not DEST_RE.fullmatch(dst):
                return self.send_json(400, {"error": "Destination invalide."})
            if proto not in ("any", "tcp", "udp", "icmp"):
                return self.send_json(400, {"error": "Protocole invalide."})
            if sens not in ("aller", "deux"):
                return self.send_json(400, {"error": "Sens invalide."})
            if ports and not PORTS_RE.fullmatch(ports):
                return self.send_json(400, {"error": "Liste de ports invalide. Exemples : 445 ou 445,5000-5001."})
            if not libelle_ok(lib):
                return self.send_json(400, {"error": "Libellé invalide : au plus 60 caractères, sans barre verticale."})
            args = ["access", "allow", src, dst, "--proto=" + proto, "--sens=" + sens]
            if ports:
                args.append("--ports=" + ports)
            if lib:
                args.append("--libelle=" + lib)
            return self.mutate_acces(args, f"règle « {src} vers {dst} » créée")
        m = re.fullmatch(r"/api/regles/([A-Za-z0-9_-]{1,16})/delete", path)
        if m:
            rid = m.group(1)
            if rid.startswith("-"):
                return self.send_json(404, {"error": "Règle introuvable."})
            return self.mutate_acces(("access", "rm", rid), f"règle « {rid} » supprimée")
        if path == "/api/filtrage":
            action = str(body.get("action", "")).strip()
            if action not in ("on", "off", "confirm"):
                return self.send_json(400, {"error": "Action inconnue."})
            # « on » et « off » ne repassent PAS par mutate_acces : ce sont eux qui
            # appliquent, il n'y a rien à réappliquer derrière.
            libelles = {"on": "filtrage activé", "off": "filtrage désactivé", "confirm": "filtrage confirmé"}
            r = run_wgpi("access", action, timeout=180)
            invalidate()
            if r.returncode != 0:
                return self.send_json(400, {"error": clean_message(r.stderr or r.stdout)})
            log(f"{self.client_address[0]} : {libelles[action]}")
            return self.send_json(200, {"ok": True, "aconfirmer": action == "on"})
        return self.send_json(404, {"error": "Action inconnue."})

    def mutate_acces(self, args, what):
        """Écrit par le CLI, puis REPOUSSE les règles dans le noyau si le filtrage tourne.

        Sans cela, le panneau afficherait une règle que le pare-feu n'applique pas : la
        vue mentirait, ce qui est pire que de ne rien afficher. La réapplication arme le
        retour arrière de deux minutes de wg-pi — c'est voulu : une règle maladroite posée
        à distance se défait toute seule au lieu de couper l'accès pour de bon."""
        r = run_wgpi(*args)
        invalidate()
        if r.returncode != 0:
            return self.send_json(400, {"error": clean_message(r.stderr or r.stdout)})
        log(f"{self.client_address[0]} : {what}")
        avert = avertissements(r.stdout)
        if not acces_actif():
            return self.send_json(200, {"ok": True, "applique": False, "avertissement": avert})
        # --modifie : ce n'est plus la configuration validée, il faut la revalider.
        a = run_wgpi("access-apply", "--modifie", timeout=180)
        invalidate()
        if a.returncode != 0:
            # L'écriture a réussi, l'application NON. Répondre « ok » laisserait le panneau
            # afficher une règle que le pare-feu n'applique pas, sous une pastille verte :
            # access_kernel_state ne juge que la topologie des sauts, pas le contenu des
            # chaînes, et l'ancien jeu de règles est toujours en vigueur. Une erreur reste
            # à l'écran ; un message passager, non.
            return self.send_json(409, {
                "error": "Enregistré, mais le pare-feu a refusé de l'appliquer : "
                         + clean_message(a.stderr or a.stdout)
                         + " Le cloisonnement en vigueur est toujours le précédent."})
        return self.send_json(200, {"ok": True, "applique": True, "aconfirmer": True,
                                    "avertissement": avert})

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
            role = check_password_role(password) if password else None
        if role:
            token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            with lock:
                failures.pop(ip, None)
                for t in [t for t, s in sessions.items() if s["expires"] < now]:
                    del sessions[t]
                sessions[token] = {"expires": now + SESSION_TTL, "csrf": csrf, "role": role}
            log(f"{ip} : connexion réussie ({role})")
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
        "   7) Accès : qui peut joindre quoi" \
        "   8) Diagnostic : ça ne marche pas ?" \
        "   9) Aide pour configurer la box" \
        "  10) Changer l'adresse publique (IP, DuckDNS…)" \
        "  11) Sauvegarder la configuration" \
        "  12) Interface web (gérer depuis le navigateur)" \
        "  13) Mettre à jour wg-pi" \
        "  14) Désinstaller" \
        "   0) Quitter" ""
    ask c "Votre choix" "0"
    case $c in
      1) (cmd_add) ;;
      2) (cmd_remove) ;;
      3) (cmd_toggle) ;;
      4) (cmd_rename) ;;
      5) (cmd_list) ;;
      6) (cmd_qr) ;;
      7) (cmd_access) ;;
      8) (cmd_check) ;;
      9) (cmd_box) ;;
      10) (cmd_endpoint) ;;
      11) (cmd_backup) ;;
      12) (cmd_web) ;;
      13) (cmd_update) ;;
      14) (cmd_uninstall); is_installed || return 0 ;;
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
  web lecture-seule [off]
                        second mot de passe qui permet de regarder, pas de modifier

  ${BOLD}Accès : qui peut joindre quoi${RESET}
  group list            groupes d'appareils et leur contenu
  group add <nom> [--libelle="..."]
                        créer un groupe (ex. « invites », « confiance »)
  group rm <nom>        supprimer un groupe
  group join <appareil> <groupe>
  group leave <appareil> <groupe>
  group set <appareil> <g1,g2,...>
                        fixer la liste des groupes d'un appareil (vide = aucun)
  resource list         appareils de la maison déclarés (NAS, Home Assistant…)
  resource add <nom> <ip|réseau> [--libelle="..."]
  resource rm <nom>
  access show           ce que chaque groupe peut joindre
  access list           les règles, une par une
  access allow <groupe> <destination> [--proto=] [--ports=] [--sens=] [--libelle=]
                        autoriser un accès. Destinations : internet, maison, pi,
                        res:<ressource>, grp:<groupe>
  access rm <id>        supprimer une règle
  access check          vérifier la cohérence du fichier d'accès
  access plan           essai à blanc : les règles qui seraient posées
  access on             activer le filtrage (annulation automatique en 2 minutes)
  access confirm        confirmer après activation, sinon tout revient en arrière
  access off            désactiver le filtrage (groupes et règles conservés)
  update                mettre à jour wg-pi depuis le dépôt GitHub
  fw-sync               régénérer les règles du pare-feu après une mise à jour
                        (le diagnostic vous le dit s'il en a besoin)
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
    group|groupe)            cmd_group "$@" ;;
    resource|ressource)      cmd_resource "$@" ;;
    access|acces)            cmd_access "$@" ;;
    web)                     cmd_web "$@" ;;
    web-serve)               cmd_web_serve ;;
    json)                    cmd_json ;;
    fw-sync)                 cmd_fw_sync ;;
    access-apply)            cmd_access_apply "$@" ;;
    access-rollback)         cmd_access_rollback ;;
    uninstall|desinstaller)  cmd_uninstall ;;
    ddns-update)             cmd_ddns_update ;;
    upnp-refresh)            cmd_upnp_refresh ;;
    *) fail "Commande inconnue : $cmd"; echo; usage; return 1 ;;
  esac
}

main "$@"
