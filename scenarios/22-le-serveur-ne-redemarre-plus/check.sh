#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Le check redémarre le serveur pour de vrai : il note sur le disque qu'il attend un redémarrage, et dans /run
# (effacé au démarrage) que ce redémarrage n'a pas encore eu lieu.
etape=/var/lib/labo-check/22-redemarrage
avant=/run/labo-check-22

boutique() { [[ $(curl -s -o /dev/null --max-time 5 -w '%{http_code}' http://localhost/) == 200 ]]; }
facture() {
  local f
  f=$(curl -s --max-time 15 -X POST http://localhost/api/factures | sed -n 's/.*"facture": "\(.*\)".*/\1/p')
  [[ -n $f && -s $f ]]
}
# Le dossier où le générateur s'extrait et s'exécute : celui de TMPDIR, sinon /tmp.
dossier_prive() {
  local pid tmpdir
  pid=$(systemctl show -p MainPID --value boutique)
  (( pid > 0 )) || return 1
  tmpdir=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^TMPDIR=//p')
  [[ -z $tmpdir ]] && return 0   # /tmp : il faut alors un /tmp privé au service, sinon la facture échoue
  [[ -d $tmpdir && $tmpdir != /var/tmp* && $tmpdir != /dev/shm* && $tmpdir != /tmp* ]] || return 1
  (( (8#$(stat -c %a "$tmpdir") & 2) == 0 ))   # personne d'autre ne peut y écrire
}
tmp_cis() { findmnt -no OPTIONS /tmp | tr , '\n' | grep -qx noexec && findmnt -no OPTIONS /tmp | grep -q nosuid && findmnt -no OPTIONS /tmp | grep -q nodev; }
# Dans un conteneur, l'identifiant de démarrage est celui du noyau de l'hôte : journalctl -b mélange les
# redémarrages du serveur. On lit le journal depuis le démarrage de systemd (PID 1).
depuis_le_demarrage() { journalctl --no-pager --since "@$(( $(date +%s) - $(ps -o etimes= -p 1) ))"; }
sans_attente() { ! depuis_le_demarrage | grep -q 'Timed out waiting for device'; }
aucun_echec() { [[ -z $(systemctl list-units --failed --no-legend --plain) ]]; }

if [[ -f $etape && ! -f $avant ]]; then
  rm -f "$etape"
  echo "  Après le redémarrage :"
  ok "il a fini de démarrer, sans passer par le mode urgence" test "$(systemctl is-system-running)" = running
  ok "sans attendre un disque" sans_attente
  ok "aucune unité en échec" aucun_echec
  ok "/tmp reste en noexec, nosuid, nodev (CIS)" tmp_cis
  ok "la boutique répond" boutique
  ok "une facture est générée" facture
  ok "le générateur s'exécute dans un dossier à lui, pas dans un dossier partagé" dossier_prive
  exit $fail
fi
rm -f "$etape"

etat=$(systemctl is-system-running)
demarre() { [[ $etat == running || $etat == degraded ]]; }
ok "le serveur a fini de démarrer (état : $etat)" demarre
ok "la boutique répond" boutique
ok "une facture est générée" facture
(( fail )) && exit 1

mkdir -p "${etape%/*}"
touch "$etape" "$avant"
exit 3
