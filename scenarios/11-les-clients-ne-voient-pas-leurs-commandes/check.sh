#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }
pause() { pg -p 5433 -c "SELECT pg_get_wal_replay_pause_state()"; }

# Une commande écrite sur le primaire apparaît sur la réplique en moins de 2 secondes.
rejoue() {
  local id
  id=$(pg -c "INSERT INTO commandes (client, montant) VALUES ('témoin du check', 1) RETURNING id")
  for _ in {1..20}; do
    [[ $(pg -p 5433 -c "SELECT count(*) FROM commandes WHERE id = $id") == 1 ]] && return 0
    sleep 0.1
  done
  return 1
}

# Une commande passée par l'API apparaît dans « Mes commandes » du client, en moins d'une seconde.
visible() {
  local client=check-$RANDOM id
  id=$(curl -fs -X POST "http://127.0.0.1:8000/api/commandes?client=$client" | tr -dc 0-9)
  [[ -n $id ]] || return 1
  for _ in {1..10}; do
    curl -fs "http://127.0.0.1:8000/api/clients/$client/commandes" | grep -qw "$id" && return 0
    sleep 0.1
  done
  return 1
}

retard_max() { awk -F= '/^[[:space:]]*retard_max_lecture/ { gsub(/[[:space:]]/, "", $2); print $2 }' /etc/boutique/api.ini; }
garde() { local n; n=$(retard_max); [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 10 )); }

# L'extraction échoue de nouveau, faute de montage : le rejeu ne doit pas rester en pause.
extraction_ratee() {
  rm -rf /srv/audit
  ! systemctl start extraction-audit && sleep 1 && [[ $(pause) == 'not paused' ]]
}
extraction_reussie() {
  install -d -o postgres /srv/audit
  systemctl start extraction-audit && [[ -s /srv/audit/commandes-$(date +%F).sql ]] && [[ $(pause) == 'not paused' ]]
}

# La réplique décroche (ici, son rejeu est mis en pause) : au-delà du retard toléré, l'API lit sur le primaire.
replique_en_retard() {
  local attente rc
  attente=$(( $(retard_max) + 2 ))
  pg -p 5433 -c "SELECT pg_wal_replay_pause()"
  sleep "$attente"
  visible
  rc=$?
  pg -p 5433 -c "SELECT pg_wal_replay_resume()"
  return "$rc"
}

ok "la réplique rejoue les WAL du primaire en moins de 2 secondes" rejoue
ok "une commande passée apparaît aussitôt dans « Mes commandes »" visible
ok "l'API tolère 10 secondes de retard de la réplique au plus (retard_max_lecture)" garde
ok "l'extraction pour l'audit tourne toujours chaque mois" systemctl is-active -q extraction-audit.timer

if (( fail == 0 )); then
  echo "  Extraction relancée sans son montage, puis avec..."
  ok "une extraction ratée ne laisse pas le rejeu en pause" extraction_ratee
  ok "une extraction réussie produit son fichier et relance le rejeu" extraction_reussie
  echo "  La réplique prend du retard..."
  ok "un client voit quand même sa commande" replique_en_retard
else
  echo "  [KO] extraction et retard de test non lancés tant que les points ci-dessus ne sont pas réglés"
fi
[[ $(pause) == 'not paused' ]] || pg -p 5433 -c "SELECT pg_wal_replay_resume()" >/dev/null 2>&1

exit $fail
