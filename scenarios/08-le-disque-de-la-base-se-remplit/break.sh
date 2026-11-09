#!/usr/bin/env bash
# Panne : un slot de réplication physique créé pour une réplique de secours décommissionnée retient tous
# les WAL depuis des semaines. max_slot_wal_keep_size vaut -1 (aucune limite) : le volume pg_wal se remplit,
# et à 100 % PostgreSQL s'arrête en PANIC. Un second slot, celui de la réplique de Lyon arrêtée pour
# maintenance, doit être gardé : sans lui, la réplique ne rattrape pas son retard.
# Fausses pistes : l'archivage (il marche), CHECKPOINT à la main, supprimer des fichiers dans pg_wal.
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At "$@"; }
attendre() { # port
  for _ in {1..120}; do runuser -u postgres -- pg_isready -q -p "$1" && return 0; sleep 0.5; done
  return 1
}
utilise() { df --output=pcent /srv/pg_wal | tail -1 | tr -dc 0-9; }
# Des commandes par lots, jusqu'à ce que le volume des WAL atteigne le pourcentage voulu.
remplir() {
  while (( $(utilise) < $1 )); do
    pg -d boutique -c "INSERT INTO commandes (client, montant) SELECT 'client-' || (i % 5000), (i % 997) / 10.0 FROM generate_series(1, 20000) i"
  done
}

# Le volume des WAL : 384 Mo, sur son propre point de montage.
install -d -o postgres -g postgres /srv/archives
cat > /etc/postgresql/17/main/conf.d/10-wal.conf <<'EOF'
# Dimensionné pour le volume pg_wal de 384 Mo.
max_wal_size = 128MB
min_wal_size = 32MB
archive_mode = on
archive_command = 'test ! -f /srv/archives/%f && cp %p /srv/archives/%f'
EOF
d=/var/lib/postgresql/17/main
install -d /srv/pg_wal
mount -t tmpfs -o size=384m,mode=700,uid="$(id -u postgres)",gid="$(id -g postgres)" pg_wal /srv/pg_wal
cp -a "$d"/pg_wal/. /srv/pg_wal/
rm -rf "$d"/pg_wal
ln -s /srv/pg_wal "$d"/pg_wal
systemctl enable --now postgresql 2>/dev/null
attendre 5432

pg -c "CREATE ROLE boutique LOGIN"
runuser -u postgres -- createdb -O boutique boutique
pg -d boutique <<'EOF'
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, montant numeric(10,2) NOT NULL,
                        cree_le timestamptz NOT NULL DEFAULT now());
ALTER TABLE commandes OWNER TO boutique;
-- La réplique de secours, décommissionnée depuis, avait son slot.
SELECT pg_create_physical_replication_slot('replica_secours', true);
EOF

# Des semaines de commandes depuis.
remplir 62

# La réplique de Lyon : une copie de base qui crée son slot, puis le flux de réplication.
pg_createcluster 17 lyon --port 5433 >/dev/null
rm -rf /var/lib/postgresql/17/lyon
runuser -u postgres -- pg_basebackup -D /var/lib/postgresql/17/lyon -R -C -S replica_lyon -X stream -c fast
systemctl start postgresql@17-lyon
attendre 5433
for _ in {1..60}; do [[ $(pg -c "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'") == 1 ]] && break; sleep 0.5; done
# Ce matin : arrêtée pour la mise à jour de son système.
systemctl stop postgresql@17-lyon
systemctl disable postgresql@17-lyon 2>/dev/null || true

remplir 86
pg -c "CHECKPOINT"

# L'inventaire du parc.
install -d /srv/doc
cat > /srv/doc/inventaire-bases.md <<'EOF'
# Inventaire des bases PostgreSQL

| Serveur | Rôle | Statut |
|---|---|---|
| srv-prod-01 (ce serveur) | primaire, cluster 17/main, port 5432 | en service |
| srv-lyon-01 (ici : cluster 17/lyon, port 5433) | réplique en flux, lectures des rapports | en service |
| srv-secours-01 | réplique de secours | décommissionnée le 2026-09-30 (ticket #4410), serveur rendu |
EOF

# L'activité de la boutique continue : quelques commandes par seconde.
install -d /opt/labo
cat > /opt/labo/boutique <<'EOF'
#!/bin/bash
while :; do
  psql -X -q -d boutique -c "INSERT INTO commandes (client, montant) VALUES ('client-web', 42.50)" 2>/dev/null
  sleep 0.5
done
EOF
chmod +x /opt/labo/boutique
cat > /etc/systemd/system/lab-boutique.service <<'EOF'
[Unit]
Description=Labo : commandes de la boutique (application distante, ne pas toucher)
After=postgresql.service

[Service]
User=boutique
ExecStart=/opt/labo/boutique
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-boutique 2>/dev/null

utilise=$(df --output=pcent /srv/pg_wal | tail -1 | tr -dc 0-9)
(( utilise >= 80 && utilise <= 95 )) || { echo "pg_wal à $utilise %, hors de la plage voulue" >&2; exit 1; }
