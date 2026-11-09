#!/usr/bin/env bash
# Panne : l'extraction pour l'audit met le rejeu des WAL en pause sur la réplique de lecture, pour qu'un long
# pg_dump ne soit pas annulé par un conflit de réplication. Cette nuit, le montage /srv/audit manquait :
# pg_dump a échoué, set -e a arrêté le script, et la reprise du rejeu n'a jamais été lancée.
# La réplique reçoit toujours le flux (state = streaming, la sonde est verte) mais ne rejoue plus rien.
# Les lectures des clients partent sur la réplique : leurs commandes de la journée n'y existent pas.
# Fausses pistes : la sonde de supervision, pg_stat_replication.state, le cache de l'application.
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At "$@"; }
attendre() { for _ in {1..120}; do runuser -u postgres -- pg_isready -q -p "$1" && return 0; sleep 0.5; done; return 1; }

useradd -r -s /usr/sbin/nologin boutique
systemctl enable --now postgresql 2>/dev/null
attendre 5432
pg -c "CREATE ROLE boutique LOGIN"
runuser -u postgres -- createdb boutique
pg -d boutique <<'EOF'
CREATE TABLE commandes (id bigserial PRIMARY KEY, client text NOT NULL, montant numeric(10,2) NOT NULL,
                        cree_le timestamptz NOT NULL DEFAULT now());
INSERT INTO commandes (client, montant, cree_le)
SELECT 'client-' || (i % 2000), (i % 997) / 10.0, now() - (i || ' minutes')::interval FROM generate_series(1, 50000) i;
GRANT SELECT, INSERT ON commandes TO boutique;
GRANT USAGE ON SEQUENCE commandes_id_seq TO boutique;
EOF

# La réplique de lecture, en flux.
pg_createcluster 17 lecture --port 5433 >/dev/null
rm -rf /var/lib/postgresql/17/lecture
runuser -u postgres -- pg_basebackup -D /var/lib/postgresql/17/lecture -R -X stream -c fast
systemctl start postgresql@17-lecture
attendre 5433

# La sonde de supervision : elle regarde l'état de la connexion de réplication.
cat > /usr/local/bin/sonde-replication <<'EOF'
#!/bin/bash
# Sonde de supervision : la réplication vers la réplique de lecture (17/lecture).
etat=$(runuser -u postgres -- psql -X -At -c "SELECT state FROM pg_stat_replication WHERE application_name = '17/lecture'")
if [[ $etat == streaming ]]; then
  echo "OK - réplication $etat"
  exit 0
fi
echo "CRITICAL - réplication ${etat:-absente}"
exit 2
EOF
chmod +x /usr/local/bin/sonde-replication

# L'extraction mensuelle pour l'audit.
cat > /usr/local/bin/extraction-audit <<'EOF'
#!/bin/bash
# Extraction mensuelle pour l'audit : les commandes, prises sur la réplique de lecture.
# Le rejeu est mis en pause pendant pg_dump : sinon, au-delà de max_standby_streaming_delay,
# un conflit avec la réplication annule le dump au bout de 30 secondes.
set -euo pipefail
psql -X -q -p 5433 -c "SELECT pg_wal_replay_pause()"
pg_dump -p 5433 -d boutique -t commandes -f "/srv/audit/commandes-$(date +%F).sql"
psql -X -q -p 5433 -c "SELECT pg_wal_replay_resume()"
EOF
chmod +x /usr/local/bin/extraction-audit
cat > /etc/systemd/system/extraction-audit.service <<'EOF'
[Unit]
Description=Extraction mensuelle des commandes pour l'audit
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/extraction-audit
EOF
cat > /etc/systemd/system/extraction-audit.timer <<'EOF'
[Unit]
Description=Extraction pour l'audit, le 4 de chaque mois à 2 h

[Timer]
OnCalendar=*-*-04 02:00:00

[Install]
WantedBy=timers.target
EOF

# L'API : écritures sur le primaire, lectures des clients sur la réplique.
install -d /etc/boutique
cat > /etc/boutique/api.ini <<'EOF'
[bases]
primaire = dbname=boutique port=5432
lecture = dbname=boutique port=5433
# Au-delà de ce retard de la réplique, en secondes, les lectures repartent sur le primaire. 0 : jamais.
retard_max_lecture = 0
EOF
cat > /usr/local/bin/app-boutique <<'EOF'
#!/usr/bin/python3
# API de la boutique : les commandes s'écrivent sur le primaire, les clients les relisent sur la réplique.
import configparser, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import psycopg2

conf = configparser.ConfigParser()
conf.read('/etc/boutique/api.ini')
PRIMAIRE = conf['bases']['primaire']
LECTURE = conf['bases']['lecture']
RETARD_MAX = conf['bases'].getint('retard_max_lecture', 0)

def requete(dsn, sql, *args):
    c = psycopg2.connect(dsn)
    try:
        with c, c.cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall()
    finally:
        c.close()

def base_de_lecture():
    if RETARD_MAX:
        retard = requete(LECTURE, "SELECT coalesce(extract(epoch FROM now() - pg_last_xact_replay_timestamp()), 0)")[0][0]
        if retard > RETARD_MAX:
            return PRIMAIRE
    return LECTURE

class Api(BaseHTTPRequestHandler):
    def repondre(self, code, corps):
        corps = json.dumps(corps).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_POST(self):
        client = parse_qs(urlparse(self.path).query).get('client', ['anonyme'])[0]
        lignes = requete(PRIMAIRE, "INSERT INTO commandes (client, montant) VALUES (%s, 42.50) RETURNING id", client)
        self.repondre(201, {'commande': lignes[0][0]})

    def do_GET(self):
        morceaux = urlparse(self.path).path.strip('/').split('/')
        if len(morceaux) == 4 and morceaux[:2] == ['api', 'clients'] and morceaux[3] == 'commandes':
            lignes = requete(base_de_lecture(), "SELECT id FROM commandes WHERE client = %s ORDER BY id", morceaux[2])
            self.repondre(200, [i for (i,) in lignes])
        else:
            self.repondre(404, {'erreur': 'inconnu'})

    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', 8000), Api).serve_forever()
EOF
chmod +x /usr/local/bin/app-boutique
cat > /etc/systemd/system/app-boutique.service <<'EOF'
[Unit]
Description=API de la boutique
After=postgresql.service

[Service]
User=boutique
ExecStart=/usr/local/bin/app-boutique
Restart=always

[Install]
WantedBy=multi-user.target
EOF

install -d /opt/labo
cat > /opt/labo/clients <<'EOF'
#!/bin/bash
# Les clients commandent, en continu.
while :; do
  curl -s -o /dev/null -X POST "http://127.0.0.1:8000/api/commandes?client=client-$((RANDOM % 2000))"
  sleep 0.5
done
EOF
chmod +x /opt/labo/clients
cat > /etc/systemd/system/lab-clients.service <<'EOF'
[Unit]
Description=Labo : clients de la boutique (ne pas toucher)
After=app-boutique.service

[Service]
ExecStart=/opt/labo/clients
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now extraction-audit.timer app-boutique lab-clients 2>/dev/null

# Cette nuit : l'extraction démarre, le montage de l'audit n'est pas là.
if systemctl start extraction-audit 2>/dev/null; then
  echo "L'extraction aurait dû échouer" >&2
  exit 1
fi
sleep 2
[[ $(runuser -u postgres -- psql -X -At -p 5433 -c "SELECT pg_get_wal_replay_pause_state()") == paused ]]
/usr/local/bin/sonde-replication >/dev/null
