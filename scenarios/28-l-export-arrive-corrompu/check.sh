#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

fichier=/srv/echanges/catalogue.csv
unite=export-catalogue.service

# Ce que le partenaire accepte : l'en-tête une fois, 60 000 références de 5 colonnes, rien de coupé.
valide() {
  awk -F';' 'NR == 1 && $0 != "reference;libelle;prix;stock;categorie" {exit 1}
             NR > 1 && (NF != 5 || $1 !~ /^REF-[0-9]+$/) {exit 1}
             END {exit NR != 60001}' "$1"
}
en_cours() { [[ $(systemctl show -p ActiveState --value "$unite") == activating ]]; }
manuel() { runuser -u export -- /usr/local/bin/export-catalogue >/dev/null 2>&1; }

# Une nuit : le minuteur et une relance à la main de l'astreinte, dans l'ordre demandé. Pendant ce temps, le
# check compte les extractions qui tournent ensemble, et lit le fichier comme le partenaire.
nuit() {
  local copie
  copie=$(mktemp)
  max=0 vu_invalide=0
  if [[ $1 == minuteur-d-abord ]]; then
    systemctl start --no-block "$unite"; sleep 0.3; manuel &
  else
    manuel & sleep 0.3; systemctl start --no-block "$unite"
  fi
  sleep 0.2
  while en_cours || [[ -n $(jobs -r) ]]; do
    n=$(pgrep -fc 'python3 /opt/catalogue/extraire.py')
    (( n > max )) && max=$n
    if [[ -e $fichier ]] && cp "$fichier" "$copie" 2>/dev/null && ! valide "$copie"; then vu_invalide=1; fi
    sleep 0.2
  done
  wait
  rm -f "$copie"
}

aucun_cron() { ! grep -rhs '^[^#]*export-catalogue' /etc/crontab /etc/cron.d /var/spool/cron/crontabs; }
durcissement() {
  [[ $(systemctl show -p PrivateTmp --value "$unite") == yes && $(systemctl show -p ProtectSystem --value "$unite") == strict ]]
}
ok "le minuteur systemd est actif" systemctl is-active -q export-catalogue.timer
ok "plus aucune ligne cron pour l'export : un seul planificateur" aucun_cron
ok "l'unité garde son durcissement (PrivateTmp, ProtectSystem=strict)" durcissement

# Un export seul, pour partir d'un fichier sain.
systemctl start "$unite" >/dev/null 2>&1
ok "un export seul produit un fichier que le partenaire accepte" valide "$fichier"
(( fail )) && exit 1

for ordre in minuteur-d-abord main-d-abord; do
  if [[ $ordre == minuteur-d-abord ]]; then echo "  Une nuit : le minuteur lance l'export, l'astreinte le relance à la main pendant qu'il tourne"
  else echo "  Une autre : l'astreinte relance l'export à la main, le minuteur se déclenche pendant ce temps"; fi
  nuit "$ordre"
  seul() { (( max == 1 )); }
  jamais_partiel() { (( vu_invalide == 0 )); }
  ok "jamais deux extractions en même temps" seul
  ok "le partenaire n'a jamais vu de fichier incomplet pendant l'export" jamais_partiel
  ok "le fichier final est accepté par le partenaire" valide "$fichier"
done

exit $fail
