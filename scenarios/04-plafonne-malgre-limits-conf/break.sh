#!/usr/bin/env bash
# Panne : l'astreinte a monté nofile dans limits.conf, que seul pam_limits lit, à l'ouverture d'une session.
# Un service systemd n'ouvre pas de session : l'API garde la limite molle de systemd, 1024.
# L'API fuit en plus une connexion vers le stock à chaque article inconnu : le stock la ferme après 1 s
# d'inactivité, elle reste en CLOSE_WAIT et garde son descripteur. Une limite plus haute retarde la panne
# sans l'empêcher. Le durcissement de l'audit plafonne enfin l'API à 64 tâches, et elle lance un thread
# par requête : la pointe ne passe pas.
# Fausses pistes : limits.conf et ulimit -n, fs.file-max, les sysctl TCP (aucun ne libère un CLOSE_WAIT).
set -euo pipefail

# Le reste du réseau dans un netns : le service stock, et les clients du site.
ip netns add infra
ip link add eth1 type veth peer name lan netns infra
ip -n infra link set lo up
ip -n infra link set lan up
ip -n infra addr add 10.20.0.1/24 dev lan
ip -n infra addr add 10.30.0.50/32 dev lo
ip addr add 10.20.0.10/24 dev eth1
ip link set eth1 up
ip route add 10.30.0.0/24 via 10.20.0.1

install -d /opt/labo
cat > /opt/labo/stock <<'EOF'
#!/usr/bin/python3
# Service stock. HTTP/1.1 : une connexion inactive pendant 1 s est fermée de ce côté.
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Stock(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    timeout = 1

    def do_GET(self):
        time.sleep(0.2)
        n = self.path.rsplit('/', 1)[-1]
        article = int(n) if n.isdigit() else 0
        if 1 <= article < 900000:
            code, corps = 200, {'article': article, 'stock': article % 17}
        else:
            code, corps = 404, {'erreur': 'article inconnu'}
        corps = json.dumps(corps).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):
        pass

class Serveur(ThreadingHTTPServer):
    request_queue_size = 1024

Serveur(('10.30.0.50', 8081), Stock).serve_forever()
EOF

# Trafic de fond : un article inconnu sur dix, les vieux liens des moteurs de recherche.
cat > /opt/labo/clients <<'EOF'
#!/usr/bin/python3
import random, threading, time, urllib.request

def client():
    while True:
        n = random.randint(900000, 999999) if random.random() < 0.1 else random.randint(1, 99999)
        try:
            urllib.request.urlopen(f'http://10.20.0.10/api/articles/{n}', timeout=3).read()
        except Exception:
            pass
        time.sleep(0.3)

for _ in range(2):
    threading.Thread(target=client).start()
EOF
chmod +x /opt/labo/stock /opt/labo/clients

cat > /etc/systemd/system/lab-stock.service <<'EOF'
[Unit]
Description=Labo : service stock (machine distante, ne pas toucher)

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/stock
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lab-clients.service <<'EOF'
[Unit]
Description=Labo : clients du site (machines distantes, ne pas toucher)
After=nginx.service

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/clients
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# L'API : chaque fiche article demande le stock au service stock.
useradd -r -s /usr/sbin/nologin api
cat > /usr/local/bin/app-api <<'EOF'
#!/usr/bin/python3
# API commandes : chaque fiche article affiche le stock, demandé au service stock.
import http.client, logging, signal, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STOCK = ('10.30.0.50', 8081)
logging.basicConfig(level=logging.INFO, format='%(message)s')

# Connexions en cours vers le stock, fermées proprement à l'arrêt du service.
ouvertes = set()
verrou = threading.Lock()

def ouvrir():
    conn = http.client.HTTPConnection(*STOCK, timeout=5)
    with verrou:
        ouvertes.add(conn)
    return conn

def fermer(conn):
    conn.close()
    with verrou:
        ouvertes.discard(conn)

def stock(article):
    conn = ouvrir()
    try:
        conn.request('GET', f'/stock/{article}')
        rep = conn.getresponse()
        corps = rep.read()
    except OSError as e:
        logging.warning('stock : article %s : %s', article, e)
        fermer(conn)
        return 502, b''
    if rep.status != 200:
        logging.warning('stock : article %s, réponse %d', article, rep.status)
        return rep.status, corps
    fermer(conn)
    return 200, corps

class Api(BaseHTTPRequestHandler):
    def do_GET(self):
        code, corps = stock(self.path.rsplit('/', 1)[-1])
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):
        pass

class Serveur(ThreadingHTTPServer):
    request_queue_size = 256

def arret(*_):
    with verrou:
        for conn in list(ouvertes):
            conn.close()
    sys.exit(0)

signal.signal(signal.SIGTERM, arret)
Serveur(('127.0.0.1', 8000), Api).serve_forever()
EOF
chmod +x /usr/local/bin/app-api

cat > /etc/systemd/system/app-api.service <<'EOF'
[Unit]
Description=API commandes
After=network.target

[Service]
User=api
ExecStart=/usr/local/bin/app-api
Environment=PYTHONUNBUFFERED=1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

install -d /etc/systemd/system/app-api.service.d
cat > /etc/systemd/system/app-api.service.d/10-durcissement.conf <<'EOF'
# Géré par Ansible (rôle durcissement, audit sécurité de septembre).
# Toute modification locale est écrasée au prochain passage.
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
TasksMax=64
EOF

cat > /etc/nginx/sites-enabled/default <<'EOF'
server {
    listen 80 default_server;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_read_timeout 10s;
    }
}
EOF

# Le changement d'hier soir.
cat >> /etc/security/limits.conf <<'EOF'

# Ticket #4611 : Too many open files sur app-api. Valeur validée par l'architecture : 65535.
*       soft    nofile  65535
*       hard    nofile  65535
root    soft    nofile  65535
root    hard    nofile  65535
EOF

# L'astreinte a vérifié avec ulimit -n dans une session SSH.
install -d -m 700 /root/.ssh
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
printf 'StrictHostKeyChecking accept-new\n' > /root/.ssh/config

systemctl daemon-reload
systemctl enable --now lab-stock app-api 2>/dev/null
systemctl restart ssh nginx
timeout 30 bash -c 'until curl -fs localhost/api/articles/1 >/dev/null; do sleep 0.2; done'

# Requêtes simultanées vers l'API, à travers nginx.
rafale() {
  python3 - "$@" <<'EOF'
import sys, threading, urllib.request
premier, nombre = int(sys.argv[1]), int(sys.argv[2])
def get(n):
    try:
        urllib.request.urlopen(f'http://localhost/api/articles/{n}', timeout=3).read()
    except Exception:
        pass
fils = [threading.Thread(target=get, args=(premier + i,)) for i in range(nombre)]
for f in fils: f.start()
for f in fils: f.join()
EOF
}

# La pointe de 10 h : plus de 64 requêtes en cours, des threads refusés.
rafale 20000 150
rafale 21000 150

# Puis les articles inconnus remplissent les descripteurs. Il en reste un : la connexion entrante le prend,
# l'appel au stock échoue sur EMFILE, et l'API répond 502 à tout.
plein() { [[ $(curl -s -o /dev/null -w '%{http_code}' localhost/api/articles/1) == 502 ]]; }
for _ in {1..40}; do
  plein && break
  rafale $((900000 + RANDOM)) 50
done
plein

systemctl enable --now lab-clients 2>/dev/null
