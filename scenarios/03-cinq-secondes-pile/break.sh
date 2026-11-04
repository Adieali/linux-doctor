#!/usr/bin/env bash
# Panne : le DHCP annonce un premier résolveur mort. glibc repart du premier serveur à chaque requête DNS
# et lui laisse 5 secondes : chaque nom coûte 5 s, ou 10 s quand la liste de recherche ajoute une requête.
# dhcpcd réécrit resolv.conf à chaque renouvellement : le corriger à la main ne tient pas.
# Fausses pistes : proxy_connect_timeout 5s dans nginx, timeout=5 et une reprise dans le code de l'API.
set -euo pipefail

# Le reste du réseau dans un netns : routeur, DHCP, résolveur secondaire, services internes.
# 10.30.0.2 passe par une route blackhole. Sans elle, le routeur répondrait en ICMP selon l'ip_forward
# de l'hôte, et glibc basculerait tout de suite une fois sur deux. Un vrai serveur mort ne répond rien.
ip netns add infra
ip link add eth1 type veth peer name lan netns infra
ip -n infra link set lo up
ip -n infra link set lan up
ip -n infra addr add 10.20.0.1/24 dev lan
for a in 10.30.0.3 10.30.0.50 10.30.0.51 10.30.0.52; do ip -n infra addr add $a/32 dev lo; done
ip -n infra route add blackhole 10.30.0.2/32
ip link set eth1 up

cat > /etc/systemd/system/lab-reseau.service <<'EOF'
[Unit]
Description=Labo : DHCP et DNS du reste du réseau (machines distantes, ne pas toucher)

[Service]
NetworkNamespacePath=/run/netns/infra
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --log-facility=- --no-resolv --no-hosts \
  --bind-interfaces --listen-address=10.20.0.1,10.30.0.3 --address=/#/ \
  --host-record=stock.interne.lan,10.30.0.50 \
  --host-record=paiement.interne.lan,10.30.0.51 \
  --host-record=controle.interne.lan,10.30.0.52 \
  --host-record=srv-prod-01.interne.lan,10.20.0.10 \
  --dhcp-range=10.20.0.10,10.20.0.10,255.255.255.0,5m \
  --dhcp-option=3 \
  --dhcp-option=6,10.30.0.2,10.30.0.3 \
  --dhcp-option=119,corp.lan,interne.lan \
  --dhcp-option=121,10.30.0.0/24,10.20.0.1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lab-services.service <<'EOF'
[Unit]
Description=Labo : services internes stock et paiement (machines distantes, ne pas toucher)

[Service]
NetworkNamespacePath=/run/netns/infra
WorkingDirectory=/usr/share/nginx/html
ExecStart=/usr/bin/python3 -m http.server --bind 0.0.0.0 8081
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Client DHCP du serveur.
cat >> /etc/dhcpcd.conf <<'EOF'

allowinterfaces eth1
ipv4only
noipv4ll
EOF

cat > /etc/systemd/system/dhcpcd.service <<'EOF'
[Unit]
Description=Client DHCP sur eth1
After=lab-reseau.service

[Service]
ExecStart=/usr/sbin/dhcpcd --nobackground eth1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# L'API : les commandes sont locales, le stock et le paiement passent par les services internes.
cat > /usr/local/bin/app-api <<'EOF'
#!/usr/bin/python3
# API commandes.
import logging, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AMONT = {'stock': 'http://stock.interne.lan:8081/', 'paiement': 'http://paiement:8081/'}
logging.basicConfig(level=logging.INFO, format='%(message)s')

def appel(nom):
    debut = time.monotonic()
    for essai in (1, 2):
        try:
            with urllib.request.urlopen(AMONT[nom], timeout=5) as r:
                r.read()
            logging.info('%s : réponse en %d ms, essai %d', nom, (time.monotonic() - debut) * 1000, essai)
            return 200
        except OSError as e:
            logging.warning('%s : échec à l\'essai %d : %s', nom, essai, e)
    return 502

class Api(BaseHTTPRequestHandler):
    def do_GET(self):
        nom = self.path.split('/')[2] if self.path.count('/') >= 2 else ''
        code = appel(nom) if nom in AMONT else 200
        self.send_response(code)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', 8000), Api).serve_forever()
EOF
chmod +x /usr/local/bin/app-api

cat > /etc/systemd/system/app-api.service <<'EOF'
[Unit]
Description=API commandes
After=network.target

[Service]
ExecStart=/usr/local/bin/app-api
Environment=PYTHONUNBUFFERED=1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-enabled/default <<'EOF'
log_format temps '$remote_addr [$time_local] "$request" $status rt=$request_time urt=$upstream_response_time';

server {
    listen 80 default_server;
    access_log /var/log/nginx/access.log temps;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }
}
EOF

# sudo et sshd font eux aussi des résolutions de noms.
cat > /etc/sudoers.d/fqdn <<'EOF'
# Les règles sudo de l'annuaire sont écrites avec des noms complets.
Defaults fqdn
EOF
chmod 440 /etc/sudoers.d/fqdn

# Docker inscrit le nom du serveur dans /etc/hosts : sans cette ligne, sudo doit le demander au DNS.
# Le fichier est monté par Docker, on réécrit son contenu au lieu de le remplacer.
grep -v srv-prod-01 /etc/hosts > /opt/hosts
cat /opt/hosts > /etc/hosts
rm /opt/hosts

cat > /etc/ssh/sshd_config.d/50-audit.conf <<'EOF'
# Les journaux d'audit veulent des noms de machines, pas des adresses.
UseDNS yes
EOF
install -d -m 700 /root/.ssh
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
printf 'StrictHostKeyChecking accept-new\n' > /root/.ssh/config

systemctl daemon-reload
systemctl enable --now lab-reseau lab-services dhcpcd app-api 2>/dev/null
systemctl restart ssh nginx
timeout 30 bash -c 'until grep -q 10.30.0.2 /etc/resolv.conf; do sleep 0.2; done'

# L'historique d'accès montre le décrochage d'hier à 17 h 02.
debut=$(date -d 'yesterday 17:02:00' +%s)
for i in $(seq 0 10 1200); do
  t=$(date -d "@$((debut - 600 + i))" '+%d/%b/%Y:%H:%M:%S %z')
  if (( i < 600 )); then s=0; p=0; else s=5; p=10; fi
  m=$((i / 10 % 8 + 1))
  printf '10.20.0.1 [%s] "GET /api/orders/%d HTTP/1.1" 200 rt=0.00%d urt=0.00%d\n' "$t" $((70000 + i)) $m $m
  printf '10.20.0.1 [%s] "GET /api/stock/%d HTTP/1.1" 200 rt=%d.01%d urt=%d.00%d\n' "$t" $((3100 + i)) $s $m $s $m
  (( i % 30 )) || printf '10.20.0.1 [%s] "GET /api/paiement/%d HTTP/1.1" 200 rt=%d.01%d urt=%d.00%d\n' "$t" $((9000 + i)) $p $m $p $m
done > /var/log/nginx/access.log
