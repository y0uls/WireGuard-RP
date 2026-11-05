#!/usr/bin/env bash
# Test de migration de bout en bout : on installe une version ANTÉRIEURE, puis on met à
# jour vers la version de travail, et on vérifie que l'installation existante est reprise
# correctement — y compris le pare-feu, que l'ancienne commande « update » ne pouvait pas
# régénérer puisqu'elle ignorait la commande qui le fait.
#
# À lancer DANS un conteneur Debian avec systemd et NET_ADMIN.
#
# Usage : ./e2e-migration.sh <ancienne version> <nouvelle version>
set -uo pipefail
V0=${1:?usage : e2e-migration.sh <ancien wg-pi.sh> <nouveau wg-pi.sh>}
V1=${2:?usage : e2e-migration.sh <ancien wg-pi.sh> <nouveau wg-pi.sh>}
[[ -f $V0 && -f $V1 ]] || { echo "Script introuvable" >&2; exit 2; }

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi
}
ge() { if [[ ${2:-0} -ge ${3:-0} ]]; then ok "$1"; else ko "$1 (obtenu $2, attendu au moins $3)"; fi; }

A=/root/v-ancienne.sh B=/root/v-nouvelle.sh
tr -d '\r' < "$V0" > "$A" && chmod +x "$A"
tr -d '\r' < "$V1" > "$B" && chmod +x "$B"

echo "-- installation de la version anterieure"
eq "l ancienne version ne connait pas le marqueur de generation" "$(grep -c 'wg-pi-fw-gen' "$A")" "0"
eq "l ancienne version ne connait pas les groupes" "$(grep -c 'cmd_access_on' "$A")" "0"
if timeout 900 bash "$A" install --yes --endpoint 203.0.113.10 --client telephone >/tmp/m-install.log 2>&1; then
  ok "l ancienne version s installe"
else
  ko "l installation de l ancienne version a echoue"; tail -15 /tmp/m-install.log; exit 1
fi
eq "le service tourne" "$(systemctl is-active wg-quick@wg0)" "active"
eq "pare-feu sans marqueur de generation" "$(grep -c 'wg-pi-fw-gen' /etc/wg-pi/firewall.sh)" "0"
# La fuite que la nouvelle version corrige : sans « ! -i wg0 », un flux etabli entre deux
# appareils du VPN contourne tout filtrage.
eq "la fuite pair-a-pair est presente avant migration" "$(iptables -S FORWARD | grep -c '! -i wg0')" "0"
wg-pi add pc-salon --split >/dev/null 2>&1
eq "deux appareils avant migration" "$(wg show wg0 peers | wc -l)" "2"

echo "-- mise a jour vers la version de travail"
if WGPI_URL="file://$V1" timeout 600 wg-pi update >/tmp/m-update.log 2>&1; then
  ok "la mise a jour se termine sans erreur"
else
  ko "la mise a jour a echoue"; tail -10 /tmp/m-update.log
fi
# La definition ET l appel : au moins deux occurrences.
ge "le binaire est bien la nouvelle version" "$(grep -c 'cmd_access_on' /usr/local/sbin/wg-pi)" "2"
eq "les appareils sont intacts" "$(wg show wg0 peers | wc -l)" "2"
eq "le service tourne toujours" "$(systemctl is-active wg-quick@wg0)" "active"
# Point essentiel : l ancienne commande « update » ne pouvait pas appeler une commande
# qu elle ignorait, donc le pare-feu reste a son ancienne generation. Le diagnostic doit
# le dire, et nommer la reparation.
eq "le pare-feu est reste a l ancienne generation" "$(grep -c 'wg-pi-fw-gen' /etc/wg-pi/firewall.sh)" "0"
wg-pi check >/tmp/m-check.log 2>&1
eq "le diagnostic signale le pare-feu perime" "$(grep -c 'Pare-feu resté en génération' /tmp/m-check.log)" "1"
eq "le diagnostic nomme la reparation" "$(grep -c 'wg-pi fw-sync' /tmp/m-check.log)" "1"

echo "-- reparation du pare-feu"
wg-pi fw-sync >/tmp/m-sync.log 2>&1
eq "la migration annonce la generation" "$(grep -c 'génération 0 → 4' /tmp/m-sync.log)" "1"
eq "le marqueur est pose" "$(sed -n '2p' /etc/wg-pi/firewall.sh | awk '{ print $3 }')" "4"
eq "la fuite pair-a-pair est fermee" "$(iptables -S FORWARD | grep -c '! -i wg0')" "1"
eq "le diagnostic est satisfait" "$(wg-pi check 2>&1 | grep -c 'Règles du pare-feu à jour')" "1"
eq "les appareils sont toujours intacts" "$(wg show wg0 peers | wc -l)" "2"

echo "-- le moteur d acces fonctionne sur l installation migree"
wg-pi group add famille --libelle="Ma famille" >/dev/null 2>&1
wg-pi group join telephone famille >/dev/null 2>&1
wg-pi access allow tous internet >/dev/null 2>&1
wg-pi access allow tous maison >/dev/null 2>&1
if wg-pi access plan >/tmp/m-plan.log 2>&1; then
  ok "l essai a blanc est accepte par le noyau"
else
  ko "l essai a blanc est refuse"; tail -6 /tmp/m-plan.log
fi
wg-pi access on >/tmp/m-on.log 2>&1
wg-pi access confirm >/dev/null 2>&1
ge "les chaines du moteur sont posees" "$(iptables -S | grep -c '^-N WGPI')" "4"
eq "etat lu dans le noyau" "$(bash -c "source <(head -n -1 /usr/local/sbin/wg-pi); load_settings; access_kernel_state")" "actif"
eq "les appareils ont survecu a tout le parcours" "$(wg show wg0 peers | wc -l)" "2"

echo "-- une seconde mise a jour migre toute seule"
# La nouvelle version, elle, appelle la migration depuis sa propre commande « update ».
sed 's/^readonly FW_GEN=4$/readonly FW_GEN=5/' "$B" > /root/v-suivante.sh
if WGPI_URL="file:///root/v-suivante.sh" timeout 600 wg-pi update >/tmp/m-update2.log 2>&1; then
  ok "la seconde mise a jour se termine"
else
  ko "la seconde mise a jour a echoue"; tail -8 /tmp/m-update2.log
fi
eq "le pare-feu a migre SANS intervention" "$(sed -n '2p' /etc/wg-pi/firewall.sh | awk '{ print $3 }')" "5"
eq "le filtrage est toujours applique" "$(bash -c "source <(head -n -1 /usr/local/sbin/wg-pi); load_settings; access_kernel_state")" "actif"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
