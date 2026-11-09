#!/usr/bin/env bash
# Panne : la nouvelle version du worker export-factures ouvre une connexion par lot et la garde dans une
# liste « pour la réutiliser », sans jamais la réutiliser ni la fermer. Les connexions s'accumulent, inactives,
# jusqu'à occuper les 37 places ordinaires de max_connections = 40. Il ne reste que les 3 places réservées
# aux superutilisateurs : l'application reçoit « remaining connection slots are reserved », le DBA entre.
# Fausses pistes : monter max_connections, redémarrer PostgreSQL ou le worker (la fuite recommence).
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At "$@"; }

cat > /etc/postgresql/17/main/conf.d/10-connexions.conf <<'EOF'
# Dimensionné sur la mémoire du serveur : 40 connexions de work_mem 32 Mo, et le cache.
max_connections = 40
work_mem = 32MB
EOF
for u in boutique factures; do useradd -r -s /usr/sbin/nologin "$u"; done
systemctl enable --now postgresql 2>/dev/null
for _ in {1..120}; do runuser -u postgres -- pg_isready -q && break; sleep 0.5; done

pg -c "CREATE ROLE boutique LOGIN" -c "CREATE ROLE factures LOGIN"
runuser -u postgres -- createdb boutique
pg -d boutique <<'EOF'
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, montant numeric(10,2) NOT NULL,
                        cree_le timestamptz NOT NULL DEFAULT now());
CREATE TABLE factures_a_exporter (id bigserial PRIMARY KEY, commande bigint NOT NULL,
                                  statut text NOT NULL DEFAULT 'a_faire');
CREATE TABLE factures_exportees (facture bigint PRIMARY KEY, exportee_le timestamptz NOT NULL DEFAULT now());
GRANT SELECT, INSERT ON commandes, factures_a_exporter TO boutique;
GRANT USAGE ON SEQUENCE commandes_id_seq, factures_a_exporter_id_seq TO boutique;
GRANT SELECT, UPDATE ON factures_a_exporter TO factures;
GRANT INSERT ON factures_exportees TO factures;
EOF

# Le worker, version livrée hier.
cat > /usr/local/bin/export-factures <<'EOF'
#!/usr/bin/python3
# Export des factures vers la comptabilité : traite la file factures_a_exporter, une facture par lot.
import logging, time
import psycopg2

logging.basicConfig(level=logging.INFO, format='%(message)s')

# Connexions déjà ouvertes, gardées pour les lots suivants (v2.3 : moins de connexions par seconde).
connexions = []

def connexion():
    c = psycopg2.connect(dbname='boutique')
    connexions.append(c)
    return c

while True:
    try:
        c = connexion()
        with c, c.cursor() as cur:
            cur.execute("SELECT id FROM factures_a_exporter WHERE statut = 'a_faire'"
                        " ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED")
            facture = cur.fetchone()
            if facture:
                cur.execute("INSERT INTO factures_exportees (facture) VALUES (%s)", facture)
                cur.execute("UPDATE factures_a_exporter SET statut = 'faite' WHERE id = %s", facture)
                logging.info('facture %s exportée', facture[0])
        if not facture:
            time.sleep(2)
    except psycopg2.Error as e:
        logging.warning('export : %s', str(e).strip())
        time.sleep(1)
EOF
chmod +x /usr/local/bin/export-factures
cat > /etc/systemd/system/export-factures.service <<'EOF'
[Unit]
Description=Export des factures vers la comptabilité (v2.3)
After=postgresql.service

[Service]
User=factures
ExecStart=/usr/local/bin/export-factures
Environment=PYTHONUNBUFFERED=1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# L'application : une connexion par requête, des commandes, et leur facture à exporter.
install -d /opt/labo
install -d -o boutique /var/log/boutique
cat > /opt/labo/boutique <<'EOF'
#!/bin/bash
while :; do
  if ! sortie=$(psql -X -q -d boutique -c "WITH c AS (INSERT INTO commandes (client, montant) VALUES ('client-web', 42.50) RETURNING id) INSERT INTO factures_a_exporter (commande) SELECT id FROM c" 2>&1); then
    echo "$(date '+%F %T') $sortie" >> /var/log/boutique/erreurs.log
  fi
  sleep 0.5
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
systemctl enable --now export-factures lab-boutique@1 lab-boutique@2 2>/dev/null

# La fuite occupe les places ordinaires : l'application ne se connecte plus.
for _ in {1..240}; do
  grep -qs 'remaining connection slots are reserved' /var/log/boutique/erreurs.log && break
  sleep 0.5
done
grep -q 'remaining connection slots are reserved' /var/log/boutique/erreurs.log
