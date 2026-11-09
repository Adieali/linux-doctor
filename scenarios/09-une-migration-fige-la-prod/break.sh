#!/usr/bin/env bash
# Panne : le rapport de stock ouvre une transaction, lit les commandes, puis appelle l'ERP sans délai
# d'expiration. L'ERP accepte la connexion et ne répond jamais : la session reste « idle in transaction »
# et garde son verrou ACCESS SHARE sur commandes. Le déploiement lance ALTER TABLE ... ADD COLUMN, qui
# demande ACCESS EXCLUSIVE et attend. Toute nouvelle requête sur commandes attend derrière la migration.
# Fausses pistes : la migration elle-même, redémarrer PostgreSQL, CPU et disque (au repos).
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At "$@"; }

# L'ERP, sur un autre réseau : il accepte les connexions et ne répond plus.
ip netns add infra
ip link add eth1 type veth peer name lan netns infra
ip -n infra link set lo up
ip -n infra link set lan up
ip -n infra addr add 10.20.0.1/24 dev lan
ip -n infra addr add 10.30.0.80/32 dev lo
ip addr add 10.20.0.10/24 dev eth1
ip link set eth1 up
ip route add 10.30.0.0/24 via 10.20.0.1
# /etc/hosts est monté par Docker : on ajoute la ligne sans remplacer le fichier.
echo '10.30.0.80 erp.interne' >> /etc/hosts

install -d /opt/labo
cat > /opt/labo/erp <<'EOF'
#!/usr/bin/python3
# ERP (machine distante) : accepte les connexions, puis ne répond plus.
import socket, threading, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('10.30.0.80', 8080))
s.listen(64)
gardees = []
while True:
    c, _ = s.accept()
    gardees.append(c)
EOF
chmod +x /opt/labo/erp
cat > /etc/systemd/system/lab-erp.service <<'EOF'
[Unit]
Description=Labo : ERP (machine distante, ne pas toucher)

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/erp
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Les rôles : l'application, le déploiement (propriétaire du schéma), les rapports.
for u in boutique deploiement rapports; do useradd -r -s /usr/sbin/nologin "$u"; done
systemctl enable --now postgresql 2>/dev/null
for _ in {1..120}; do runuser -u postgres -- pg_isready -q && break; sleep 0.5; done
pg -c "CREATE ROLE boutique LOGIN" -c "CREATE ROLE deploiement LOGIN" -c "CREATE ROLE rapports LOGIN"
runuser -u postgres -- createdb -O deploiement boutique
runuser -u deploiement -- psql -X -q -d boutique <<'EOF'
CREATE TABLE schema_migrations (version text PRIMARY KEY, appliquee_le timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (version) SELECT lpad(i::text, 4, '0') FROM generate_series(1, 41) i;
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, produit int NOT NULL,
                        montant numeric(10,2) NOT NULL, cree_le timestamptz NOT NULL DEFAULT now());
INSERT INTO commandes (client, produit, montant, cree_le)
SELECT 'client-' || (i % 5000), i % 300, (i % 997) / 10.0, now() - (i || ' seconds')::interval
FROM generate_series(1, 200000) i;
CREATE TABLE rapports_envoyes (id serial PRIMARY KEY, envoye_le timestamptz NOT NULL DEFAULT now());
GRANT SELECT, INSERT ON commandes TO boutique;
GRANT USAGE ON SEQUENCE commandes_id_seq TO boutique;
GRANT SELECT ON commandes TO rapports;
GRANT INSERT ON rapports_envoyes TO rapports;
GRANT USAGE ON SEQUENCE rapports_envoyes_id_seq TO rapports;
EOF

# Le rapport de stock, chaque heure.
cat > /usr/local/bin/rapport-stock <<'EOF'
#!/bin/bash
# Rapport de stock : les ventes de la dernière heure par produit, envoyées à l'ERP.
psql -X -q -d boutique <<'SQL'
BEGIN;
CREATE TEMP TABLE rapport AS
  SELECT produit, count(*) AS ventes FROM commandes WHERE cree_le > now() - interval '1 hour' GROUP BY produit;
\copy rapport TO '/tmp/rapport-stock.csv' CSV
\! curl -s -X POST --data-binary @/tmp/rapport-stock.csv http://erp.interne:8080/api/stock
INSERT INTO rapports_envoyes DEFAULT VALUES;
COMMIT;
SQL
EOF
chmod +x /usr/local/bin/rapport-stock
cat > /etc/systemd/system/rapport-stock.service <<'EOF'
[Unit]
Description=Rapport de stock horaire vers l'ERP
After=postgresql.service

[Service]
Type=oneshot
User=rapports
ExecStart=/usr/local/bin/rapport-stock
EOF
cat > /etc/systemd/system/rapport-stock.timer <<'EOF'
[Unit]
Description=Rapport de stock, chaque heure

[Timer]
OnCalendar=hourly

[Install]
WantedBy=timers.target
EOF

# Les migrations, appliquées par le déploiement.
install -d /srv/migrations
cat > /srv/migrations/0042_suivi_colis.sql <<'EOF'
-- Version 2.14 : le numéro de suivi du transporteur.
ALTER TABLE commandes ADD COLUMN suivi_colis text;
EOF
cat > /usr/local/bin/migrer <<'EOF'
#!/bin/bash
# Applique les migrations de /srv/migrations dans l'ordre, chacune une seule fois, dans sa propre transaction.
set -euo pipefail
cd /srv/migrations
for f in [0-9]*.sql; do
  v=${f%%_*}
  [[ -n $(psql -X -At -d boutique -c "SELECT 1 FROM schema_migrations WHERE version = '$v'") ]] && continue
  echo "Migration $f"
  psql -X -q -v ON_ERROR_STOP=1 -d boutique -1 -f "$f" -c "INSERT INTO schema_migrations (version) VALUES ('$v')"
done
EOF
chmod +x /usr/local/bin/migrer
cat > /etc/systemd/system/migration.service <<'EOF'
[Unit]
Description=Migrations du schéma, lancées par le pipeline de déploiement
After=postgresql.service

[Service]
Type=oneshot
User=deploiement
ExecStart=/usr/local/bin/migrer
EOF

# L'application : des lectures et des commandes en continu, avec leur durée.
install -d -o boutique /var/log/boutique
cat > /opt/labo/boutique <<'EOF'
#!/bin/bash
while :; do
  debut=$(date +%s%N)
  psql -X -q -At -d boutique -c "SELECT count(*) FROM commandes WHERE client = 'client-$((RANDOM % 5000))'" >/dev/null 2>&1 &&
  psql -X -q -d boutique -c "INSERT INTO commandes (client, produit, montant) VALUES ('client-web', $((RANDOM % 300)), 42.50)" 2>/dev/null &&
  echo "$(date '+%F %T') commande enregistrée en $(( ($(date +%s%N) - debut) / 1000000 )) ms" >> /var/log/boutique/acces.log
  sleep 0.3
done
EOF
chmod +x /opt/labo/boutique
cat > /etc/systemd/system/lab-boutique@.service <<'EOF'
[Unit]
Description=Labo : application boutique, worker %i (ne pas toucher)
After=postgresql.service

[Service]
User=boutique
ExecStart=/opt/labo/boutique
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now lab-erp rapport-stock.timer lab-boutique@1 lab-boutique@2 lab-boutique@3 2>/dev/null
sleep 3

# Le rapport de l'heure part, puis le déploiement 2.14.
systemctl start --no-block rapport-stock
for _ in {1..40}; do
  [[ $(pg -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'rapports' AND state = 'idle in transaction'") == 1 ]] && break
  sleep 0.25
done
systemctl start --no-block migration
for _ in {1..40}; do
  (( $(pg -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'") >= 4 )) && break
  sleep 0.25
done
(( $(pg -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'") >= 4 ))
