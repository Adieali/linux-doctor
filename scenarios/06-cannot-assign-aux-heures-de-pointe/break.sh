#!/usr/bin/env bash
# Panne : nginx ouvre une connexion par requête vers le catalogue (HTTP/1.0, pas de keepalive) et la ferme
# le premier. Chaque fermeture laisse un port local en TIME_WAIT pendant 60 s, pour cette destination.
# La plage éphémère a été réduite à 1000 ports après un vieil incident : au-delà de 16 requêtes par seconde
# vers le catalogue, connect() n'a plus de port à donner (EADDRNOTAVAIL) et nginx renvoie 502.
# Fausses pistes : les adresses IP et le listen de nginx (le message parle d'adresse), tcp_fin_timeout
# (il ne règle pas TIME_WAIT), le catalogue lui-même.
set -euo pipefail

# Le reste du réseau dans un netns : le catalogue d'une autre équipe, et les clients du site.
ip netns add infra
ip link add eth1 type veth peer name lan netns infra
ip -n infra link set lo up
ip -n infra link set lan up
ip -n infra addr add 10.20.0.1/24 dev lan
ip -n infra addr add 10.30.0.60/32 dev lo
ip addr add 10.20.0.10/24 dev eth1
ip link set eth1 up
ip route add 10.30.0.0/24 via 10.20.0.1

install -d /opt/labo
cat > /opt/labo/catalogue <<'EOF'
#!/usr/bin/python3
# Service catalogue (machine distante). Comme son serveur d'applications, il attend un peu avant de
# fermer une connexion terminée : le client a le temps de fermer en premier.
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Catalogue(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        corps = json.dumps({'produit': self.path.rsplit('/', 1)[-1], 'prix': 19.9}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def handle(self):
        super().handle()
        time.sleep(0.5)

    def log_message(self, *args):
        pass

class Serveur(ThreadingHTTPServer):
    request_queue_size = 1024

Serveur(('10.30.0.60', 8080), Catalogue).serve_forever()
EOF

# Navigateurs : une connexion par requête. Trafic normal, et pointe de 30 secondes sur demande.
cat > /opt/labo/clients <<'EOF'
#!/usr/bin/python3
import random, sys, threading, time, urllib.request

fils, pause, duree = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
fin = time.monotonic() + duree

def client():
    while time.monotonic() < fin:
        try:
            urllib.request.urlopen(f'http://10.20.0.10/catalogue/{random.randint(1, 5000)}', timeout=3).read()
        except Exception:
            pass
        time.sleep(pause)

t = [threading.Thread(target=client) for _ in range(fils)]
for x in t: x.start()
for x in t: x.join()
EOF
chmod +x /opt/labo/catalogue /opt/labo/clients

cat > /etc/systemd/system/lab-catalogue.service <<'EOF'
[Unit]
Description=Labo : service catalogue (machine distante, ne pas toucher)

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/catalogue
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lab-clients.service <<'EOF'
[Unit]
Description=Labo : visiteurs du site, trafic normal (machines distantes, ne pas toucher)
After=nginx.service

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/clients 2 0.4 inf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lab-pointe.service <<'EOF'
[Unit]
Description=Labo : 30 secondes de pointe, 60 à 80 requêtes par seconde (machines distantes)

[Service]
Type=oneshot
NetworkNamespacePath=/run/netns/infra
ExecStart=/opt/labo/clients 8 0.1 30
EOF

# Le service de rapports de ce serveur, sur son port historique.
cat > /etc/systemd/system/app-rapports.service <<'EOF'
[Unit]
Description=Rapports internes (port 45000)

[Service]
User=nobody
WorkingDirectory=/usr/share/nginx/html
ExecStart=/usr/bin/python3 -m http.server --bind 0.0.0.0 45000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sysctl.d/60-ports-ephemeres.conf <<'EOF'
# Incident #2291 (2023) : app-rapports n'a pas pu redémarrer, une connexion sortante avait pris son port 45000.
# La plage éphémère passe au-dessus. Mille ports, largement de quoi faire.
net.ipv4.ip_local_port_range = 50000 50999
EOF
sysctl -q -p /etc/sysctl.d/60-ports-ephemeres.conf

cat > /etc/nginx/sites-enabled/default <<'EOF'
server {
    listen 80 default_server;

    location /catalogue/ {
        proxy_pass http://10.30.0.60:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 2s;
    }
}
EOF

systemctl daemon-reload
systemctl enable --now lab-catalogue app-rapports 2>/dev/null
systemctl restart nginx
timeout 30 bash -c 'until curl -fs localhost/catalogue/1 >/dev/null; do sleep 0.2; done'
systemctl enable --now lab-clients 2>/dev/null

# La pointe de ce matin.
systemctl start lab-pointe
grep -q 'Cannot assign requested address' /var/log/nginx/error.log
