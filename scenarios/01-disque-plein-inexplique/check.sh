#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

archives() {
  for d in {12..27}; do
    cmp -s "/var/lib/disks/archives/compta-2026-10-$d.tar" <(yes "compta 2026-10-$d" | head -c 12M) || return 1
  done
}

ok "/srv est utilisé à moins de 30 %" test "$(df --output=pcent /srv | tail -1 | tr -dc 0-9)" -lt 30
ok "le disque d'archives est toujours monté sur /srv/data/archive" bash -c 'findmnt -n -o SOURCE /srv/data/archive | grep -q /var/lib/disks/archives'
ok "les 16 archives du 12 au 27 octobre sont sur le disque d'archives, intactes" archives

# Test réel : on retire le disque, on lance le job. Il doit soit échouer sans rien écrire, soit remonter le disque lui-même.
# Tant que ce qui précède n'est pas bon, des archives dorment peut-être encore sous le point de montage : on n'y touche pas.
if (( fail == 0 )); then
  echo "  Disque d'archives retiré, job lancé, comme après le redémarrage du 19 octobre..."
  jour=compta-$(date +%F).tar
  job_ok=0
  if umount /srv/data/archive 2>/dev/null; then
    systemctl start archive-compta.service >/dev/null 2>&1; rc=$?
    if mountpoint -q /srv/data/archive; then
      test -f "/var/lib/disks/archives/$jour" && job_ok=1
    else
      (( rc != 0 )) && [[ -z $(ls -A /srv/data/archive) ]] && job_ok=1
      rm -f "/srv/data/archive/$jour"
      mount --bind /var/lib/disks/archives /srv/data/archive
    fi
  fi
  ok "sans son disque, le job d'archivage échoue de façon visible ou remonte le disque" test $job_ok = 1
else
  echo "  [KO] test du job sans son disque non lancé tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
