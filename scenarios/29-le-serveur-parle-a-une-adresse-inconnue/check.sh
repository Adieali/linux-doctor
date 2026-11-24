#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Le check redémarre le serveur : il note sur le disque qu'il attend un redémarrage, et dans /run (effacé au
# démarrage) que ce redémarrage n'a pas encore eu lieu.
etape=/var/lib/labo-check/29-redemarrage
avant=/run/labo-check-29
preuves=/srv/preuves
c2=198.51.100.66

# Les identifiants des charges utiles qui ont appelé le serveur de contrôle : un script copié depuis le
# processus vivant les contient, le dropper qu'on retéléchargerait non.
copie_du_script() {
  local id
  while read -r id; do
    grep -rlx "ID=$id" "$preuves" 2>/dev/null | xargs -r grep -l 'while :; do' | grep -q . && return 0
  done < <(grep -o 'id=[0-9a-f]\{8\}' /var/log/labo-c2.log | cut -d= -f2 | sort -u)
  return 1
}
journal_intrusion() { grep -rlqF 'Accepted password for deploy from 203.0.113.66' "$preuves"; }
sommes() {
  [[ -s $preuves/SHA256SUMS ]] && (cd "$preuves" && sha256sum --quiet -c SHA256SUMS) &&
    [[ $(wc -l < "$preuves/SHA256SUMS") -ge 2 ]]
}
coupe() { ! curl -s -m 3 -o /dev/null "http://$c2:443/"; }
boutique() { [[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost/) == 200 ]]; }
rien_de_cache() { ! awk '$2 ~ "^/proc/[0-9]+$" {f = 1} END {exit !f}' /proc/mounts; }
pas_de_charge_utile() {
  local p
  for p in /proc/[0-9]*; do
    readlink "$p/exe" 2>/dev/null | grep -q kdevtmpfsi && return 1
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q '^\[kworker/1:2-events\]' && return 1
  done
  return 0
}
plus_d_appels() { local n; n=$(wc -l < /var/log/labo-c2.log); sleep 12; [[ $(wc -l < /var/log/labo-c2.log) == "$n" ]]; }
unite() { [[ ! -e /etc/systemd/system/dbus-broker-sync.service ]] && ! systemctl is-enabled -q dbus-broker-sync.service; }
taches_cron() { ! grep -rqs "$c2" /etc/crontab /etc/cron.d /var/spool/cron/crontabs; }
cle_attaquant() { ! grep -rqsF "$(cut -d' ' -f2 /opt/labo/cles/attaquant.pub)" /root/.ssh /home/*/.ssh; }
cle_admin() { grep -qF "$(cut -d' ' -f2 /opt/labo/cles/admin.pub)" /root/.ssh/authorized_keys; }
uid0() { [[ $(awk -F: '$3 == 0' /etc/passwd) == root:* && $(awk -F: '$3 == 0' /etc/passwd | wc -l) == 1 ]]; }
sauvegarde() { [[ -e /etc/cron.d/sauvegarde ]] && id deploy; }
porte_fermee() {
  ! SSH_ASKPASS=/opt/labo/cles/mot-de-passe SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ip netns exec attaquant setsid -w ssh -n -b 203.0.113.77 -o PubkeyAuthentication=no -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 deploy@10.29.0.10 true
}
persistances() {
  ok "plus d'unité dbus-broker-sync" unite
  ok "plus de tâche cron vers le serveur de contrôle" taches_cron
  ok "plus de clé de l'attaquant" cle_attaquant
  ok "plus de compte d'UID 0 à part root" uid0
}

if [[ -f $etape && ! -f $avant ]]; then
  rm -f "$etape"
  echo "  Après le redémarrage, et 30 s pour laisser une persistance oubliée se déclencher :"
  sleep 30
  ok "rien n'est caché sous /proc" rien_de_cache
  ok "aucune charge utile ne tourne" pas_de_charge_utile
  persistances
  ok "le serveur de contrôle reste injoignable" coupe
  ok "la boutique répond" boutique
  exit $fail
fi
rm -f "$etape"

ok "copie du script exécuté par le processus caché, dans $preuves" copie_du_script
ok "extrait du journal montrant l'intrusion, dans $preuves" journal_intrusion
ok "SHA256SUMS des preuves, et il se vérifie" sommes
(( fail )) && { echo "  Les preuves d'abord : le reste ne sera vérifié qu'ensuite."; exit 1; }
ok "le serveur de contrôle est injoignable" coupe
ok "la boutique répond" boutique
ok "rien n'est caché sous /proc" rien_de_cache
ok "aucune charge utile ne tourne" pas_de_charge_utile
ok "plus aucun appel au serveur de contrôle" plus_d_appels
persistances
ok "la clé de l'admin est toujours là" cle_admin
ok "le compte deploy et la sauvegarde de nuit sont toujours là" sauvegarde
ok "le mot de passe de deploy n'ouvre plus de session, depuis une autre adresse de l'attaquant" porte_fermee
(( fail )) && exit 1

mkdir -p "${etape%/*}"
touch "$etape" "$avant"
exit 3
