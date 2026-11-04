#!/usr/bin/env bash
# Panne : l'export de la nuit tourne dans base.slice, la tranche limitée à 400 Mo sans swap qui contient
# PostgreSQL. psql charge tout le résultat en mémoire avant d'écrire une ligne, et la tranche déborde.
# Dans un cgroup, l'OOM killer tue le processus au plus gros score : c'était psql, jusqu'à ce qu'un
# ticket le protège avec OOMScoreAdjust=-900. Depuis, la victime est le processus PostgreSQL qui sert
# l'export, et OOMPolicy=stop, la valeur par défaut de systemd, arrête alors toute la base.
# Fausses pistes : free (la machine a de la mémoire), shared_buffers, ajouter de la RAM.
set -euo pipefail

cat > /etc/systemd/system/base.slice <<'EOF'
[Unit]
Description=Base de données : budget mémoire validé par le DBA

[Slice]
MemoryMax=400M
MemorySwapMax=0
EOF

install -d /etc/systemd/system/postgresql@17-main.service.d
cat > /etc/systemd/system/postgresql@17-main.service.d/10-tranche.conf <<'EOF'
[Service]
Slice=base.slice
EOF

attendre_base() {
  for _ in {1..120}; do runuser -u postgres -- pg_isready -q && return 0; sleep 0.5; done
  return 1
}

systemctl daemon-reload
systemctl enable --now postgresql 2>/dev/null
attendre_base

# Un million de commandes, un peu plus de 200 Mo sur disque.
runuser -u postgres -- createdb boutique
runuser -u postgres -- psql -X -q -d boutique <<'EOF'
CREATE TABLE commandes (
  id bigint PRIMARY KEY,
  client text NOT NULL,
  adresse text NOT NULL,
  montant numeric(10,2) NOT NULL,
  cree_le timestamptz NOT NULL
);
INSERT INTO commandes
SELECT i, 'client-' || (i % 50000), i || ', ' || repeat('rue de la Gare ', 8), (i % 9973) / 100.0,
       timestamptz '2026-11-04 02:00+01' - i * interval '1 minute'
FROM generate_series(1, 1000000) i;
EOF

install -d -o postgres -g postgres /srv/exports
cat > /usr/local/bin/export-compta <<'EOF'
#!/bin/bash
# Export comptable de la nuit : toutes les commandes, importées par l'ERP à 6 h.
set -euo pipefail
fichier=/srv/exports/commandes-$(date +%F).csv
psql -X -At -F ';' -d boutique -c 'SELECT id, client, adresse, montant, cree_le FROM commandes ORDER BY id' > "$fichier.tmp"
mv "$fichier.tmp" "$fichier"
EOF
chmod +x /usr/local/bin/export-compta

cat > /etc/systemd/system/export-nuit.service <<'EOF'
[Unit]
Description=Export comptable de la nuit vers l'ERP
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/export-compta
# Demande DBA #3982 : l'export travaille pour la base, il compte dans le budget de la base.
Slice=base.slice
# Ticket #4120 : l'export était tué certaines nuits par l'OOM killer. Il ne doit plus l'être.
OOMScoreAdjust=-900
EOF

cat > /etc/systemd/system/export-nuit.timer <<'EOF'
[Unit]
Description=Export comptable, chaque nuit à 2 h

[Timer]
OnCalendar=*-*-* 02:00:00

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now export-nuit.timer 2>/dev/null

# L'astreinte rejoue la nuit à la main, la base tombe, elle la relance.
if systemctl start export-nuit 2>/dev/null; then
  echo "L'export aurait dû faire tomber la base" >&2
  exit 1
fi
# systemd arrête toute la base quand il voit l'oom-kill : attendre la fin de cet arrêt avant de relancer.
for _ in {1..120}; do
  [[ $(systemctl show -p ActiveState --value postgresql@17-main) =~ ^(inactive|failed)$ ]] && break
  sleep 0.5
done
systemctl start postgresql@17-main
attendre_base
