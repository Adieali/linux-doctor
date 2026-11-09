#!/usr/bin/env bash
# Panne : la sauvegarde est un tar à chaud du répertoire de données, sans mode sauvegarde. Les fichiers sont
# copiés à des instants différents, sans backup_label, et pg_wal, un lien vers son propre volume, n'est
# archivé que comme lien : la copie n'a aucun WAL. L'exercice de restauration recrée un pg_wal vide, et
# PostgreSQL ne trouve pas de point de contrôle valide. Même avec les WAL, la copie ne serait pas fiable.
# Fausses pistes : la taille des sauvegardes (stable), le contenu de l'archive (tous les fichiers y sont).
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At -d boutique; }

# pg_wal sur son propre volume, comme en prod.
d=/var/lib/postgresql/17/main
install -d -o postgres -g postgres -m 700 /srv/pg_wal
cp -a "$d"/pg_wal/. /srv/pg_wal/
rm -rf "$d"/pg_wal
ln -s /srv/pg_wal "$d"/pg_wal
chown -h postgres:postgres "$d"/pg_wal
useradd -r -s /usr/sbin/nologin boutique
systemctl enable --now postgresql 2>/dev/null
for _ in {1..120}; do runuser -u postgres -- pg_isready -q && break; sleep 0.5; done

runuser -u postgres -- psql -X -q -c "CREATE ROLE boutique LOGIN"
runuser -u postgres -- createdb boutique
pg <<'EOF'
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, montant numeric(10,2) NOT NULL,
                        cree_le timestamptz NOT NULL DEFAULT now());
CREATE INDEX ON commandes (client);
INSERT INTO commandes (client, montant, cree_le)
SELECT 'client-' || (i % 5000), (i % 997) / 10.0, now() - (i || ' minutes')::interval FROM generate_series(1, 300000) i;
GRANT SELECT, INSERT, UPDATE ON commandes TO boutique;
GRANT USAGE ON SEQUENCE commandes_id_seq TO boutique;
EOF

# La sauvegarde, chaque nuit depuis deux ans.
install -d /srv/sauvegardes
cat > /usr/local/bin/sauvegarde-base <<'EOF'
#!/bin/bash
# Sauvegarde nocturne de la base : une archive du répertoire de données.
set -uo pipefail
tar czf "/srv/sauvegardes/base-$(date +%F).tar.gz" -C /var/lib/postgresql/17 main
rc=$?
# 1 : des fichiers ont changé pendant la copie, normal sur une base en service.
(( rc <= 1 ))
EOF
chmod +x /usr/local/bin/sauvegarde-base
cat > /etc/systemd/system/sauvegarde-base.service <<'EOF'
[Unit]
Description=Sauvegarde nocturne de la base
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sauvegarde-base
EOF
cat > /etc/systemd/system/sauvegarde-base.timer <<'EOF'
[Unit]
Description=Sauvegarde de la base, chaque nuit à 1 h

[Timer]
OnCalendar=*-*-* 01:00:00

[Install]
WantedBy=timers.target
EOF

# L'exercice de restauration du PRA : la dernière sauvegarde, démarrée à part, sur le port 5435.
cat > /usr/local/bin/exercice-restauration <<'EOF'
#!/bin/bash
# Exercice de restauration du PRA : la dernière sauvegarde doit démarrer et contenir les commandes.
set -euo pipefail
derniere=$(ls -t /srv/sauvegardes/base-*.tar.gz | head -1)
cible=/srv/exercice
rm -rf "$cible"
install -d -o postgres -m 700 "$cible"
tar xzf "$derniere" -C "$cible" --strip-components=1
# pg_wal est un lien vers le volume de la prod, et postmaster.pid désigne le processus de la prod :
# on ne suit surtout ni l'un ni l'autre.
rm -f "$cible/pg_wal" "$cible/postmaster.pid"
install -d -o postgres -m 700 "$cible/pg_wal"
printf "port = 5435\nlisten_addresses = ''\nunix_socket_directories = '/var/run/postgresql'\n" > "$cible/postgresql.conf"
echo "local all all peer" > "$cible/pg_hba.conf"
touch "$cible/pg_ident.conf"
chown -R postgres:postgres "$cible"
trap 'runuser -u postgres -- /usr/lib/postgresql/17/bin/pg_ctl -D "$cible" -m immediate stop >/dev/null 2>&1 || true' EXIT
runuser -u postgres -- /usr/lib/postgresql/17/bin/pg_ctl -D "$cible" -l "$cible/exercice.log" -w -t 120 start
n=$(runuser -u postgres -- psql -X -At -p 5435 -d boutique -c "SELECT count(*) FROM commandes")
echo "Restauration de $derniere : $n commandes"
EOF
chmod +x /usr/local/bin/exercice-restauration
cat > /etc/systemd/system/exercice-restauration.service <<'EOF'
[Unit]
Description=Exercice de restauration du PRA (dernière sauvegarde)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/exercice-restauration
EOF

# L'application écrit en continu.
install -d /opt/labo
cat > /opt/labo/boutique <<'EOF'
#!/bin/bash
while :; do
  psql -X -q -d boutique -c "INSERT INTO commandes (client, montant) SELECT 'client-web', 42.50 FROM generate_series(1, 200)" \
                         -c "UPDATE commandes SET montant = montant + 1 WHERE id IN (SELECT (random() * 300000)::bigint FROM generate_series(1, 200))" 2>/dev/null
  sleep 0.2
done
EOF
chmod +x /opt/labo/boutique
cat > /etc/systemd/system/lab-boutique.service <<'EOF'
[Unit]
Description=Labo : application boutique (ne pas toucher)
After=postgresql.service

[Service]
User=boutique
ExecStart=/opt/labo/boutique
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sauvegarde-base.timer lab-boutique 2>/dev/null
sleep 2

# La sauvegarde de cette nuit, puis l'exercice de ce matin.
systemctl start sauvegarde-base
if systemctl start exercice-restauration 2>/dev/null; then
  echo "L'exercice aurait dû échouer" >&2
  exit 1
fi
