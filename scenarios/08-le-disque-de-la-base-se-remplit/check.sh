#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pg() { runuser -u postgres -- psql -X -q -At "$@"; }
attendre() { for _ in {1..120}; do runuser -u postgres -- pg_isready -q -p "$1" && return 0; sleep 0.5; done; return 1; }
utilise() { df --output=pcent /srv/pg_wal | tail -1 | tr -dc 0-9; }
reglage() { pg -c "SELECT setting FROM pg_settings WHERE name = '$1'"; }

# Les WAL normaux (max_wal_size) et ceux qu'un slot peut retenir doivent tenir à 90 % du volume.
plafond() {
  local garde
  garde=$(reglage max_slot_wal_keep_size)
  (( garde >= 0 && garde + $(reglage max_wal_size) <= 384 * 90 / 100 ))
}

slot_lyon() { [[ $(pg -c "SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'replica_lyon'") =~ ^(reserved|extended)$ ]]; }

rattrape() {
  local id
  id=$(pg -d boutique -c "INSERT INTO commandes (client, montant) VALUES ('témoin du check', 1) RETURNING id")
  for _ in {1..60}; do
    [[ $(runuser -u postgres -- psql -X -At -p 5433 -d boutique -c "SELECT count(*) FROM commandes WHERE id = $id" 2>/dev/null) == 1 ]] && return 0
    sleep 0.5
  done
  return 1
}

# Un slot qui décroche : au-delà du plafond, il doit être invalidé avant que le volume ne se remplisse.
decrochage() {
  local etat=reserved
  pg -c "SELECT pg_create_physical_replication_slot('check_decroche', true)" || return 1
  for _ in {1..80}; do
    pg -d boutique -c "INSERT INTO commandes (client, montant) SELECT 'check', 1 FROM generate_series(1, 50000)"
    pg -c "CHECKPOINT"
    (( $(utilise) < 92 )) || break
    etat=$(pg -c "SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'check_decroche'")
    [[ $etat == lost ]] && break
  done
  pg -c "SELECT pg_drop_replication_slot('check_decroche')"
  [[ $etat == lost ]] && (( $(utilise) < 92 ))
}

echo "  Redémarrage de la base, comme samedi, puis point de contrôle..."
systemctl restart postgresql@17-main
attendre 5432
pg -c "CHECKPOINT" >/dev/null 2>&1

ok "la base tourne et accepte les commandes" pg -d boutique -c "INSERT INTO commandes (client, montant) VALUES ('check', 1)"
ok "le volume pg_wal n'a pas été agrandi (384 Mo)" test "$(df --output=size -m /srv/pg_wal | tail -1 | tr -dc 0-9)" -eq 384
ok "pg_wal est redescendu sous 60 %" test "$(utilise)" -lt 60
ok "le slot de la réplique décommissionnée n'existe plus" test "$(pg -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name = 'replica_secours'")" -eq 0
ok "le slot de la réplique de Lyon est intact" slot_lyon
ok "un slot ne peut plus retenir plus que la place libre (max_slot_wal_keep_size)" plafond

# Sans plafond, le test de décrochage remplirait le volume pour de bon.
if (( fail == 0 )); then
  echo "  Fin de la maintenance à Lyon : la réplique repart..."
  systemctl start postgresql@17-lyon
  attendre 5433
  ok "la réplique de Lyon rattrape son retard par le flux" rattrape
  echo "  Un slot de test décroche, pendant que Lyon suit..."
  ok "au-delà du plafond, le slot est invalidé et le volume reste sous 92 %" decrochage
else
  echo "  [KO] réplique et décrochage non testés tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
