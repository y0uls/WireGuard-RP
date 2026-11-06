#!/usr/bin/env bash
# Test de bout en bout, à lancer DANS un conteneur Debian avec systemd et NET_ADMIN.
#
# Il installe réellement, monte une vraie interface wg0, pose de vraies règles iptables,
# active le filtrage, le confirme, redémarre le tunnel, puis désinstalle et vérifie qu'il
# ne reste rien. C'est le seul test qui prouve l'application des règles sur un noyau.
#
# Depuis Windows, voir test/e2e-lancer.md.
#
# Usage (dans le conteneur) : ./e2e.sh /chemin/vers/wg-pi.sh
set -uo pipefail
SRC=${1:-/repo/wg-pi.sh}
[[ -f $SRC ]] || { echo "Script introuvable : $SRC" >&2; exit 2; }

pass=0 fail=0
ok() { echo "  OK   $1"; pass=$((pass + 1)); }
ko() { echo "  KO   $1"; fail=$((fail + 1)); }
eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1"; echo "       obtenu  : [$2]"; echo "       attendu : [$3]"; fi
}
ge() {  # au moins N
  if [[ ${2:-0} -ge ${3:-0} ]]; then ok "$1"; else ko "$1 (obtenu $2, attendu au moins $3)"; fi
}

WG=/root/wg-pi-e2e.sh
tr -d '\r' < "$SRC" > "$WG" && chmod +x "$WG"

echo "-- prerequis de l environnement"
eq "systemd operationnel" "$(systemctl is-system-running 2>/dev/null | head -1)" "running"
if ip link add dev wgprobe type wireguard 2>/dev/null; then
  ok "le noyau sait creer une interface wireguard"
  ip link del wgprobe
else
  ko "le noyau ne sait pas creer d interface wireguard : le test ne peut pas aboutir"
  exit 1
fi
if systemd-run --quiet --collect --unit=e2eprobe --on-active=600 /bin/true 2>/dev/null; then
  ok "systemd-run --on-active disponible (minuteur d annulation)"
  systemctl stop e2eprobe.timer 2>/dev/null
else
  ko "systemd-run --on-active indisponible : l annulation automatique ne sera pas testee"
fi

echo "-- installation neuve"
if timeout 900 bash "$WG" install --yes --endpoint 203.0.113.10 --client telephone >/tmp/e2e-install.log 2>&1; then
  ok "l installation se termine sans erreur"
else
  ko "l installation a echoue (voir /tmp/e2e-install.log)"
  tail -20 /tmp/e2e-install.log
  exit 1
fi
eq "le service est actif" "$(systemctl is-active wg-quick@wg0)" "active"
eq "wg0 porte l adresse du serveur" "$(ip -4 -br addr show wg0 | awk '{ print $3 }')" "10.8.0.1/24"
eq "un pair est configure" "$(wg show wg0 peers | wc -l)" "1"
eq "cle pre-partagee presente" "$(wg show wg0 preshared-keys | awk '{ print ($2 != "(none)") }')" "1"
# La generation est LUE dans le script teste, jamais ecrite en dur : un nombre fige se
# perime a la version suivante sans que rien ne le signale, et l assertion passe alors a
# cote de ce qu elle surveille. C est ce qui avait rendu e2e-migration.sh inoperant.
GEN_ATTENDUE=$(grep -m1 '^readonly FW_GEN=' "$SRC" | cut -d= -f2)
[[ $GEN_ATTENDUE =~ ^[0-9]+$ ]] || { echo "  KO   generation illisible dans $SRC" >&2; exit 2; }
eq "generation du pare-feu" "$(sed -n '2p' /etc/wg-pi/firewall.sh | awk '{ print $3 }')" "$GEN_ATTENDUE"
# La fuite corrigee : sans « ! -i wg0 », un flux etabli entre deux appareils du VPN
# contourne tout filtrage a venir.
eq "la regle conntrack porte ! -i wg0" "$(iptables -S FORWARD | grep -c '! -i wg0')" "1"
eq "acceptation generale posee hors filtrage" "$(iptables -S FORWARD | grep -c '^-A FORWARD -i wg0 -j ACCEPT')" "1"
eq "NAT en place" "$(iptables -t nat -S POSTROUTING | grep -c 'MASQUERADE')" "1"
eq "port du VPN ouvert en INPUT" "$(iptables -S INPUT | grep -c 'dport 51820')" "1"
eq "port SSH determinable" "$(bash -c "source <(head -n -1 $WG); access_ssh_known && echo oui || echo non")" "oui"

echo "-- groupes, ressources et regles"
wg-pi add pc-salon --split >/dev/null 2>&1
wg-pi add tablette-amis --split >/dev/null 2>&1
eq "trois appareils" "$(wg show wg0 peers | wc -l)" "3"
wg-pi group add famille --libelle="Ma famille" >/dev/null 2>&1
wg-pi group add invites --libelle="Invites" >/dev/null 2>&1
wg-pi group join telephone famille >/dev/null 2>&1
wg-pi group join pc-salon famille >/dev/null 2>&1
wg-pi group join tablette-amis invites >/dev/null 2>&1
wg-pi resource add nas 192.168.99.20 --libelle="Le NAS" >/dev/null 2>&1
wg-pi access allow famille internet >/dev/null 2>&1
wg-pi access allow famille maison >/dev/null 2>&1
wg-pi access allow famille res:nas --proto=tcp --ports=445,5000-5001 >/dev/null 2>&1
wg-pi access allow invites internet >/dev/null 2>&1
wg-pi access allow famille grp:famille --sens=deux >/dev/null 2>&1
# Un groupe d administration qui joint TOUT, en une seule regle. Pose ici pour que l essai
# a blanc le soumette a un VRAI noyau : c est la seule preuve que « -d 0.0.0.0/0 » passe.
wg-pi group add admin --libelle="Administration" >/dev/null 2>&1
wg-pi group join pc-salon admin >/dev/null 2>&1
wg-pi access allow admin tout >/dev/null 2>&1
eq "six regles enregistrees" "$(wg-pi access list 2>/dev/null | grep -cE '^   p[0-9]')" "6"
eq "le mode reste ouvert : rien n est applique" "$(bash -c "source <(head -n -1 $WG); load_settings; access_mode")" "ouvert"
eq "aucune chaine du moteur avant activation" "$(iptables -S | grep -c '^-N WGPI')" "0"

echo "-- essai a blanc sur un vrai noyau"
if wg-pi access plan >/tmp/e2e-plan.log 2>&1; then
  ok "toutes les regles sont acceptees par le noyau"
else
  ko "au moins une regle est refusee par ce noyau"
  tail -8 /tmp/e2e-plan.log
fi
ge "le plan contient des regles" "$(grep -c 'iptables -' /tmp/e2e-plan.log)" "20"
eq "l essai a blanc ne branche rien" "$(iptables -S FORWARD | grep -c 'WGPI-FWD')" "0"
eq "l essai a blanc ne laisse aucune chaine" "$(iptables -S | grep -c '^-N WGPI')" "0"

echo "-- activation"
wg-pi access on >/tmp/e2e-on.log 2>&1
eq "l activation reussit" "$(grep -c 'Filtrage actif' /tmp/e2e-on.log)" "1"
# Le piege du DNS : « Internet seulement » exclut le reseau de la maison, donc la box.
eq "l avertissement DNS se declenche" "$(grep -c 'aucun nom de site' /tmp/e2e-on.log)" "1"
# Une version anterieure rangeait son instantane a la racine de /run, et lui appliquait
# « install -d -m 700 » : cela revenait a faire « chmod 700 /run », ce qui casse Docker
# sans privileges, la session de l utilisateur, mDNS et la resolution de noms. GNU install
# applique bien le mode a un dossier DEJA existant : le defaut etait reel.
eq "/run garde ses droits normaux" "$(stat -c %a /run)" "755"
eq "l instantane a son propre dossier, prive" "$(stat -c %a /run/wg-pi)" "700"
LOAD="source <(head -n -1 $WG); load_settings"
eq "etat lu dans le noyau" "$(bash -c "$LOAD; access_kernel_state")" "actif"
# iptables normalise « -d 0.0.0.0/0 » en l effacant : la regle du groupe admin apparait
# donc SANS aucune contrainte, ce qui est exactement le sens voulu.
eq "la regle tout est posee, sans restriction" \
   "$(iptables -S | grep -cE '^-A WGPI-S-admin-[AB] -m comment --comment "?wgpi:pol:[A-Za-z0-9]+"? -j ACCEPT')" "1"
# Le moteur d acces ne filtre que l IPv4. Laisser passer l IPv6 rendrait ses regles
# contournables : deux appareils se joindraient par leur adresse IPv6 du tunnel sans que
# rien ne l examine. Tant que le filtrage est actif, l IPv6 ne traverse donc pas le VPN.
eq "IPv6 coupee dans les deux sens pendant le filtrage" \
   "$(ip6tables -S FORWARD | grep -cE '^-A FORWARD -[io] wg0 -j REJECT')" "2"
eq "le saut est en premiere position" "$(bash -c "$LOAD; access_jump_first && echo oui || echo non")" "oui"
eq "l acceptation generale a disparu" "$(iptables -S FORWARD | grep -c '^-A FORWARD -i wg0 -j ACCEPT')" "0"
ge "les chaines du moteur sont posees" "$(iptables -S | grep -c '^-N WGPI')" "6"
BUF=$(bash -c "$LOAD; access_active_buffer")
eq "la chaine d entree finit par le refus" \
   "$(iptables -S "WGPI-FWD-$BUF" | tail -1 | grep -c "WGPI-DENY-$BUF")" "1"
eq "la chaine INPUT finit par RETURN" "$(iptables -S "WGPI-IN-$BUF" | tail -1)" "-A WGPI-IN-$BUF -j RETURN"
eq "SSH accepte inconditionnellement" "$(iptables -S "WGPI-IN-$BUF" | grep -c 'wgpi:secours:ssh')" "1"
eq "refus en REJECT et non DROP" "$(iptables -S "WGPI-DENY-$BUF" | grep -c REJECT)" "2"
eq "aucun DROP" "$(iptables -S | grep -c 'WGPI.*-j DROP')" "0"
eq "retour des flux pair-a-pair par --ctdir" "$(iptables -S "WGPI-FWD-$BUF" | grep -c 'ctdir REPLY')" "1"
# L interface de sortie n est pas contrainte la ou elle n a pas a l etre : une ressource
# joignable autrement recevrait sinon une regle qui ne peut jamais correspondre.
eq "la regle vers la ressource ne contraint pas l interface" \
   "$(iptables -S "WGPI-S-famille-$BUF" | grep '192.168.99.20' | grep -c ' -o ')" "0"
eq "le miroir du sens deux est pose" "$(iptables -S "WGPI-S-famille-$BUF" | grep -c 'retour')" "2"
eq "minuteur d annulation arme" "$(systemctl is-active wg-pi-access-rollback.timer)" "active"

echo "-- confirmation et survie au redemarrage"
wg-pi access confirm >/dev/null 2>&1
eq "minuteur desarme apres confirmation" "$(systemctl is-active wg-pi-access-rollback.timer)" "inactive"
eq "la confirmation est persistee hors de /run" "$([[ -f /etc/wg-pi/access-confirme ]] && echo oui || echo non)" "oui"
systemctl restart wg-quick@wg0
sleep 2
ge "les chaines sont reconstruites apres restart" "$(iptables -S | grep -c '^-N WGPI')" "6"
eq "le saut est reposé apres restart" "$(iptables -S FORWARD | grep -c 'WGPI-FWD')" "1"
eq "l acceptation generale reste absente" "$(iptables -S FORWARD | grep -c '^-A FORWARD -i wg0 -j ACCEPT')" "0"
# Une configuration confirmee ne doit PAS rearmer le minuteur a chaque demarrage, sinon le
# filtrage se desactive tout seul des qu un redemarrage passe inapercu deux minutes.
eq "pas de minuteur apres restart, car confirme" "$(systemctl is-active wg-pi-access-rollback.timer)" "inactive"

echo "-- diagnostic"
wg-pi check >/tmp/e2e-check.log 2>&1
eq "le diagnostic voit le filtrage actif" "$(grep -c 'Filtrage des accès actif' /tmp/e2e-check.log)" "1"
eq "le diagnostic voit le pare-feu a jour" "$(grep -c 'Règles du pare-feu à jour' /tmp/e2e-check.log)" "1"
# access check signale a juste titre le piege du DNS tant qu il n est pas traite. On
# applique le remede que le message lui-meme conseille, ce qui le teste par la meme occasion.
eq "le diagnostic d acces signale le piege du DNS" "$(wg-pi access check 2>&1 | grep -c 'aucun nom de site')" "1"
wg-pi resource add dns 172.17.0.1 --libelle="Le DNS de la box" >/dev/null 2>&1
wg-pi access allow invites res:dns --proto=udp --ports=53 >/dev/null 2>&1
wg-pi access allow invites res:dns --proto=tcp --ports=53 >/dev/null 2>&1
wg-pi access allow famille res:dns --proto=udp --ports=53 >/dev/null 2>&1
wg-pi access allow famille res:dns --proto=tcp --ports=53 >/dev/null 2>&1
wg-pi access on >/dev/null 2>&1; wg-pi access confirm >/dev/null 2>&1
eq "apres le remede, plus d avertissement DNS" "$(wg-pi access check 2>&1 | grep -c 'aucun nom de site')" "0"
eq "la coherence du fichier d acces est confirmee" "$(wg-pi access check 2>&1 | grep -c 'cohérent')" "1"

echo "-- panneau web et role lecture seule, par HTTP reel"
# Chaque changement de mot de passe redemarre le service : on attend qu il reponde.
attendre_panneau() {
  local i=0
  while (( i < 40 )); do
    [[ $(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$1/login" 2>/dev/null) == 200 ]] && return 0
    sleep 0.5
    i=$(( i + 1 ))
  done
  return 1
}
ADMIN=$(wg-pi web --yes 2>&1 | sed -n 's/.*Mot de passe généré.*: //p' | tr -d '[:space:]')
eq "le panneau est actif" "$(systemctl is-active wg-pi-web)" "active"
PORT=$(sed -n 's/^port=//p' /etc/wg-pi/web.conf)
if attendre_panneau "$PORT"; then ok "le panneau repond en HTTPS"; else ko "le panneau ne repond pas"; fi
eq "la page de connexion repond" "$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/login")" "200"
eq "/api/state refuse sans session" "$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/api/state")" "401"
eq "un mauvais mot de passe est refuse" \
   "$(curl -sk -o /dev/null -w '%{http_code}' -X POST --data-urlencode 'password=faux' "https://127.0.0.1:$PORT/login")" "401"
RO=$(wg-pi web lecture-seule --yes 2>&1 | sed -n 's/.*Mot de passe généré.*: //p' | tr -d '[:space:]')
attendre_panneau "$PORT" || ko "le panneau ne repond plus apres la creation du compte de consultation"
eq "les deux mots de passe sont non vides et differents"    "$([[ -n $ADMIN && -n $RO && $ADMIN != "$RO" ]] && echo oui || echo non)" "oui"

# Ouvre une session et rend « code_state code_post code_conf code_qr role ».
session() {
  local pw=$1 jar csrf
  jar=$(mktemp)
  curl -sk -c "$jar" -o /dev/null -X POST --data-urlencode "password=$pw" "https://127.0.0.1:$PORT/login"
  csrf=$(curl -sk -b "$jar" "https://127.0.0.1:$PORT/" | grep -o 'name="csrf" content="[^"]*"' | sed 's/.*content="//;s/"//')
  printf '%s %s %s %s %s' \
    "$(curl -sk -b "$jar" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/api/state")" \
    "$(curl -sk -b "$jar" -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' \
         -d "{\"name\":\"essai-$2\"}" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/api/peers")" \
    "$(curl -sk -b "$jar" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/device/telephone/conf")" \
    "$(curl -sk -b "$jar" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/device/telephone/qr")" \
    "$(curl -sk -b "$jar" "https://127.0.0.1:$PORT/" | grep -o 'data-role="[a-z]*"' | head -1 | sed 's/.*="//;s/"//')"
  rm -f "$jar"
}
eq "administrateur : tout permis" "$(session "$ADMIN" admin)" "200 200 200 200 admin"
# Le .conf et le QR code contiennent la cle privee de l appareil : les telecharger
# permettrait de connecter un appareil, ce qui n est pas « regarder ».
eq "consultation : lecture seule appliquee" "$(session "$RO" lecture)" "200 403 403 403 lecture"
eq "l appareil refuse n a PAS ete cree" "$(wg show wg0 allowed-ips | grep -c 'essai-lecture')" "0"
eq "l appareil de l administrateur a bien ete cree" "$(wg-pi list 2>/dev/null | grep -c 'essai-admin')" "1"

echo "-- sauvegarde et restauration"
wg-pi backup >/tmp/e2e-backup.log 2>&1
SAUVE=$(sed -n 's/.*Sauvegarde créée : //p' /tmp/e2e-backup.log | tr -d '[:space:]')
eq "la sauvegarde existe" "$([[ -s ${SAUVE:-/nonexistent} ]] && echo oui || echo non)" "oui"
eq "le fichier d acces est dans la sauvegarde" "$(tar tzf "$SAUVE" | grep -c 'access\.conf$')" "1"
eq "la confirmation est dans la sauvegarde" "$(tar tzf "$SAUVE" | grep -c 'access-confirme')" "1"

echo "-- desinstallation : il ne doit rien rester"
# Desinstallation faite PENDANT que le filtrage est actif : c est le cas qui laissait
# derriere lui l acceptation generale, parce qu access_unswitch la remet pour rouvrir et
# que base_down refusait de l enlever tant que le fichier disait « filtre ».
wg-pi uninstall --yes >/tmp/e2e-uninstall.log 2>&1
eq "le service est arrete" "$(systemctl is-active wg-quick@wg0 2>&1)" "inactive"
eq "le panneau web est arrete" "$(systemctl is-active wg-pi-web 2>&1)" "inactive"
eq "l interface wg0 a disparu" "$(ip link show wg0 2>&1 | grep -c 'does not exist')" "1"
eq "le dossier d etat a disparu" "$([[ -d /etc/wg-pi ]] && echo present || echo absent)" "absent"
eq "aucune chaine du moteur ne subsiste" "$(iptables -S | grep -c 'WGPI')" "0"
eq "aucune regle FORWARD ne subsiste" "$(iptables -S FORWARD | grep -c 'wg0')" "0"
eq "aucune regle INPUT ne subsiste" "$(iptables -S INPUT | grep -c '51820')" "0"
# Le retrait est inconditionnel : sans cela la coupure survivrait a une desinstallation
# faite pendant que le filtrage etait actif, et couperait l IPv6 d un Pi sans VPN.
eq "aucune coupure IPv6 ne subsiste" \
   "$(ip6tables -S FORWARD | grep -cE '^-A FORWARD -[io] wg0 -j REJECT')" "0"
eq "aucune regle NAT ne subsiste" "$(iptables -t nat -S POSTROUTING | grep -c 'MASQUERADE')" "0"
eq "aucune unite systemd ne subsiste" "$(ls /etc/systemd/system/ 2>/dev/null | grep -c 'wg-pi')" "0"

echo "-- restauration sur un systeme nettoye"
if timeout 900 bash "$WG" restore "$SAUVE" >/tmp/e2e-restore.log 2>&1; then
  ok "la restauration se termine sans erreur"
else
  ko "la restauration a echoue"
  tail -15 /tmp/e2e-restore.log
fi
eq "le service est reparti" "$(systemctl is-active wg-quick@wg0)" "active"
ge "les appareils sont revenus" "$(wg show wg0 peers | wc -l)" "4"
eq "les groupes sont revenus" "$(wg-pi group list 2>/dev/null | grep -cE 'famille|invites')" "2"
eq "le mode filtre est revenu" "$(bash -c "$LOAD; access_mode")" "filtre"
eq "la confirmation est revenue" "$([[ -f /etc/wg-pi/access-confirme ]] && echo oui || echo non)" "oui"
# Et surtout : le filtrage est reellement reapplique, pas seulement demande.
ge "le filtrage est reapplique" "$(iptables -S | grep -c '^-N WGPI')" "6"
eq "etat lu dans le noyau apres restauration" "$(bash -c "$LOAD; access_kernel_state")" "actif"

echo
echo "  $pass réussi(s), $fail échoué(s)"
(( fail == 0 ))
