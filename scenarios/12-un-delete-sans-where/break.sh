#!/usr/bin/env bash
# Panne : depuis la console SQL du back-office, le support lance DELETE FROM commandes sans sa clause WHERE.
# La clé étrangère des paiements est en ON DELETE CASCADE : ils partent aussi. La boutique continue de
# prendre des commandes. Il faut une restauration à un instant précis, à côté de la prod, à partir de la
# sauvegarde de la nuit et des WAL archivés. Piège : le segment de WAL qui contient les dernières minutes
# avant l'incident n'est pas encore archivé. Et les commandes de test, elles, devaient bien disparaître.
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }

install -d -o postgres -g postgres /srv/archives/wal /srv/sauvegardes
cat > /etc/postgresql/17/main/conf.d/10-sauvegarde.conf <<'EOF'
# Archivage continu des WAL, pour la restauration à un instant précis.
archive_mode = on
archive_command = 'test ! -f /srv/archives/wal/%f && cp %p /srv/archives/wal/%f'
# Audit : toutes les requêtes qui modifient des données sont journalisées.
log_statement = 'mod'
EOF
for u in boutique support; do useradd -r -s /usr/sbin/nologin "$u"; done
systemctl enable --now postgresql 2>/dev/null
for _ in {1..120}; do runuser -u postgres -- pg_isready -q && break; sleep 0.5; done

runuser -u postgres -- psql -X -q -c "CREATE ROLE boutique LOGIN" -c "CREATE ROLE support LOGIN"
runuser -u postgres -- createdb boutique
pg <<'EOF'
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, montant numeric(10,2) NOT NULL,
                        cree_le timestamptz NOT NULL DEFAULT now());
CREATE TABLE paiements (id bigserial PRIMARY KEY,
                        commande bigint NOT NULL REFERENCES commandes ON DELETE CASCADE,
                        montant numeric(10,2) NOT NULL, moyen text NOT NULL);
GRANT SELECT, INSERT ON commandes, paiements TO boutique;
GRANT USAGE ON SEQUENCE commandes_id_seq, paiements_id_seq TO boutique;
-- La console du back-office : le support corrige les commandes à la main.
GRANT SELECT, UPDATE, DELETE ON commandes, paiements TO support;
-- Les commandes jusqu'à hier soir, et quelques commandes de test.
INSERT INTO commandes (client, montant, cree_le)
SELECT CASE WHEN i % 1000 = 0 THEN 'test' ELSE 'client-' || (i % 3000) END, (i % 997) / 10.0,
       now() - interval '1 day' - (i || ' seconds')::interval
FROM generate_series(1, 20000) i;
INSERT INTO paiements (commande, montant, moyen)
SELECT id, montant, CASE WHEN id % 3 = 0 THEN 'virement' ELSE 'carte' END FROM commandes;
EOF

# La sauvegarde de cette nuit.
runuser -u postgres -- pg_basebackup -D "/srv/sauvegardes/base-$(date +%F)" -Ft -z -X fetch -c fast

# La journée : des commandes, dont une de test, et leurs paiements.
pg <<'EOF'
WITH c AS (
  INSERT INTO commandes (client, montant)
  SELECT CASE WHEN i = 777 THEN 'test' ELSE 'client-' || (i % 3000) END, (i % 499) / 10.0
  FROM generate_series(1, 3000) i RETURNING id, montant)
INSERT INTO paiements (commande, montant, moyen) SELECT id, montant, 'carte' FROM c;
SELECT pg_switch_wal();
EOF
pg <<'EOF'
WITH c AS (
  INSERT INTO commandes (client, montant)
  SELECT 'client-' || (i % 3000), (i % 499) / 10.0 FROM generate_series(1, 400) i RETURNING id, montant)
INSERT INTO paiements (commande, montant, moyen) SELECT id, montant, 'carte' FROM c;
EOF

# L'application : des commandes, chacune notée dans son journal.
install -d /opt/labo
install -d -o boutique /var/log/boutique
cat > /opt/labo/boutique <<'EOF'
#!/bin/bash
while :; do
  id=$(psql -X -q -At -d boutique -c "WITH c AS (INSERT INTO commandes (client, montant) VALUES ('client-web', 42.50) RETURNING id, montant) INSERT INTO paiements (commande, montant, moyen) SELECT id, montant, 'carte' FROM c RETURNING commande" 2>/dev/null) &&
  echo "$(date '+%F %T') commande $id" >> /var/log/boutique/commandes.log
  sleep 0.3
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
systemctl enable --now lab-boutique 2>/dev/null
sleep 3

# Les commandes à retrouver, notées avant l'incident pour le check.
systemctl stop lab-boutique
sleep 1
install -d -m 700 /var/lib/linux-doctor
{
  echo "dernier=$(pg -c "SELECT max(id) FROM commandes")"
  echo "commandes=$(pg -c "SELECT md5(string_agg(id || ':' || client || ':' || montant || ':' || cree_le, ',' ORDER BY id)) FROM commandes WHERE client <> 'test'")"
  echo "paiements=$(pg -c "SELECT md5(string_agg(p.id || ':' || p.commande || ':' || p.montant || ':' || p.moyen, ',' ORDER BY p.id)) FROM paiements p JOIN commandes c ON c.id = p.commande WHERE c.client <> 'test'")"
} > /var/lib/linux-doctor/12

# Le nettoyage des commandes de test, depuis la console. La ligne du WHERE n'est pas partie.
runuser -u support -- psql -X -q -d boutique -c "DELETE FROM commandes"
echo "incident=$(date '+%F %T.%N %z')" >> /var/lib/linux-doctor/12
systemctl start lab-boutique
sleep 3
(( $(pg -c "SELECT count(*) FROM commandes WHERE id <= $(sed -n 's/^dernier=//p' /var/lib/linux-doctor/12)") == 0 ))
