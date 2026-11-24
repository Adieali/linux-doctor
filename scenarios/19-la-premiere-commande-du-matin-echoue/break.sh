#!/usr/bin/env bash
# Panne : connexion morte en silence. Le service des commandes garde une connexion ouverte vers PostgreSQL,
# de l'autre côté d'un pare-feu à état qui oublie une connexion inactive au bout d'une heure (20 s dans le
# labo). libpq active bien le keepalive TCP, mais avec le délai par défaut de Linux : 2 heures. La nuit, le
# pare-feu oublie la connexion ; le matin, la première requête part sur une connexion qu'il ne connaît plus
# (ce n'est pas un SYN : il la jette), le service attend 5 s (tcp_user_timeout), échoue, puis en rouvre une.
# Piège pour la réparation : un nouveau tcp_keepalive_time ne touche pas les minuteurs déjà armés (2 h).
# Fausses pistes : la base (elle va bien), le réseau (ping OK), le pare-feu (il applique sa politique).
set -euo pipefail

routeur() { ip netns exec "$1" sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0; }

# Le pare-feu de l'équipe réseau, entre les serveurs (10.20.0.0/24) et la base (10.30.0.0/24).
ip netns add pare-feu
ip -n pare-feu link set lo up
routeur pare-feu
ip link add eth1 type veth peer name serveurs netns pare-feu
ip -n pare-feu addr add 10.20.0.1/24 dev serveurs
ip -n pare-feu link set serveurs up
ip addr add 10.20.0.10/24 dev eth1
ip link set eth1 up
ip route add 10.30.0.0/24 via 10.20.0.1
ip netns add base
ip -n pare-feu link add vers-base type veth peer name eth0 netns base
ip -n pare-feu addr add 10.30.0.1/24 dev vers-base
ip -n pare-feu link set vers-base up
ip -n base link set lo up
ip -n base addr add 10.30.0.5/24 dev eth0
ip -n base link set eth0 up
ip -n base route add default via 10.30.0.1
ip netns exec pare-feu nft -f - <<'EOF'
table inet filtre {
    chain transit {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        # Une connexion vers la base commence par un SYN. Le reste doit appartenir à une connexion connue.
        tcp flags & (syn | ack) == syn ip saddr 10.20.0.0/24 ip daddr 10.30.0.5 tcp dport 5432 accept
    }
}
EOF
# Politique de l'équipe réseau : une connexion TCP inactive est oubliée au bout d'une heure. Le labo : 20 s.
ip netns exec pare-feu sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_established=20 net.netfilter.nf_conntrack_tcp_loose=0

# La base, de l'autre côté du pare-feu.
pgbin=$(find /usr/lib/postgresql -maxdepth 2 -name bin -type d | sort | tail -1)
pgconf=$(find /etc/postgresql -mindepth 2 -maxdepth 2 -name main -type d | sort | tail -1)
pgdata=$(find /var/lib/postgresql -mindepth 2 -maxdepth 2 -name main -type d | sort | tail -1)
echo "host boutique commandes 10.20.0.0/24 scram-sha-256" >> "$pgconf/pg_hba.conf"
install -d -o postgres -g postgres /run/postgresql
cat > /etc/systemd/system/lab-base.service <<EOF
[Unit]
Description=Labo : la base de la boutique, de l'autre côté du pare-feu (ne pas toucher)

[Service]
User=postgres
NetworkNamespacePath=/run/netns/base
ExecStart=$pgbin/postgres -D $pgdata -c config_file=$pgconf/postgresql.conf -c listen_addresses=10.30.0.5 -c log_connections=on
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-base 2>/dev/null
timeout 20 bash -c 'until runuser -u postgres -- psql -Atqc "SELECT 1" >/dev/null 2>&1; do sleep 0.3; done'
runuser -u postgres -- psql -q <<'EOF'
CREATE ROLE commandes LOGIN PASSWORD 'commandes';
CREATE DATABASE boutique OWNER commandes;
\c boutique
CREATE TABLE commandes (id serial PRIMARY KEY, client text, montant numeric(10,2), cree_le timestamptz DEFAULT now());
INSERT INTO commandes (client, montant) SELECT 'client-' || i, (i % 200) + 9.90 FROM generate_series(1, 1250) i;
ALTER TABLE commandes OWNER TO commandes;
EOF

# Le service des commandes : une connexion à la base, gardée ouverte, recréée si elle casse.
useradd --system --no-create-home --shell /usr/sbin/nologin commandes
install -d /opt/commandes /etc/commandes
cat > /etc/commandes/commandes.conf <<'EOF'
[base]
# Si la base ne répond pas sous 5 s, la connexion est abandonnée et recréée à la requête suivante.
dsn = host=10.30.0.5 dbname=boutique user=commandes password=commandes connect_timeout=3 tcp_user_timeout=5000 application_name=commandes
EOF
cat > /opt/commandes/commandes.py <<'EOF'
#!/usr/bin/env python3
# Service des commandes de la boutique : GET /commandes. Garde une connexion à la base ouverte entre les
# requêtes (ouvrir une connexion coûte cher, et la base en limite le nombre), et la recrée si elle casse.
import configparser, http.server, json, threading, time
import psycopg2

conf = configparser.ConfigParser()
conf.read("/etc/commandes/commandes.conf")
dsn = conf["base"]["dsn"]
verrou = threading.Lock()
cnx = None


def connexion():
    global cnx
    if cnx is None or cnx.closed:
        cnx = psycopg2.connect(dsn)
        cnx.autocommit = True
    return cnx


class Requete(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        global cnx
        if self.path != "/commandes":
            return self.repondre(404, {"erreur": "inconnu"})
        debut = time.monotonic()
        with verrou:
            try:
                with connexion().cursor() as cur:
                    cur.execute("SELECT count(*) FROM commandes")
                    self.repondre(200, {"commandes": cur.fetchone()[0]})
            except psycopg2.Error as erreur:
                print(f"ERREUR base après {time.monotonic() - debut:.1f} s : {str(erreur).strip()}", flush=True)
                if cnx is not None:
                    cnx.close()
                cnx = None
                self.repondre(503, {"erreur": "base injoignable"})

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu, ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)


http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Requete).serve_forever()
EOF
cat > /etc/systemd/system/commandes.service <<'EOF'
[Unit]
Description=Service des commandes de la boutique
After=network-online.target

[Service]
User=commandes
ExecStart=/usr/bin/python3 /opt/commandes/commandes.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now commandes 2>/dev/null
timeout 10 bash -c 'until curl -fs -o /dev/null http://localhost:8000/commandes; do sleep 0.3; done'

# Une « nuit » du labo : le pare-feu oublie la connexion, et la première commande du matin échoue.
sleep 25
code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' http://localhost:8000/commandes)
if [[ $code != 503 ]]; then
  echo "La première commande après la nuit aurait dû échouer (HTTP $code)" >&2
  exit 1
fi
