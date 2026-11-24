#!/usr/bin/env bash
# Panne : le proxy n'est configuré que pour les shells. Depuis le nouveau pare-feu de sortie, seul le proxy
# d'entreprise peut joindre Internet. Ses variables sont dans /etc/profile.d/proxy.sh : un shell de connexion
# les a, et curl passe. Le service des expéditions, lancé par systemd, ne lit pas /etc/profile.d : il appelle
# le transporteur en direct, et le routeur jette ses paquets (timeout).
# Pièges pour la réparation : HTTP_PROXY ne vaut pas pour les URL https (il faut https_proxy) ; et une fois le
# proxy en place, les appels internes (stock.interne) et locaux (localhost) partent aussi vers lui, qui les
# refuse : il faut no_proxy.
# Fausses pistes : le transporteur (curl passe), le DNS, le certificat.
set -euo pipefail

routeur() { ip netns exec "$1" sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0; }
lien() { # netns-hôte adresse-hôte/masque adresse-routeur/masque interface-routeur
  ip netns add "$1"
  ip -n "$1" link set lo up
  ip -n routeur link add "$4" type veth peer name eth0 netns "$1"
  ip -n routeur addr add "$3" dev "$4"
  ip -n routeur link set "$4" up
  ip -n "$1" addr add "$2" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" route add default via "${3%/*}"
}

# Le routeur : LAN des serveurs, proxy, services internes, et Internet. Vers Internet, seul le proxy sort.
ip netns add routeur
ip -n routeur link set lo up
routeur routeur
ip link add eth1 type veth peer name serveurs netns routeur
ip -n routeur addr add 10.40.0.1/24 dev serveurs
ip -n routeur link set serveurs up
ip addr add 10.40.0.10/24 dev eth1
ip link set eth1 up
ip route del default 2>/dev/null || true
ip route add default via 10.40.0.1
lien proxy 10.41.0.3/24 10.41.0.1/24 vers-proxy
lien stock 10.42.0.20/24 10.42.0.1/24 vers-stock
lien internet 198.51.100.20/24 198.51.100.1/24 wan
ip netns exec routeur nft -f - <<'EOF'
table inet filtre {
    chain transit {
        type filter hook forward priority filter; policy accept;
        # Politique de sécurité #4860 : vers Internet, seul le proxy d'entreprise sort.
        oifname "wan" ip saddr != 10.41.0.3 drop
    }
}
EOF
cat >> /etc/hosts <<'EOF'
10.41.0.3 proxy.interne
10.42.0.20 stock.interne
198.51.100.20 api.transporteur.example
EOF
install -d /etc/netns/proxy
printf '127.0.0.1 localhost\n10.42.0.20 stock.interne\n198.51.100.20 api.transporteur.example\n' > /etc/netns/proxy/hosts

# Le transporteur, sur Internet, en HTTPS. Son AC est dans le magasin de confiance du serveur.
install -d -m 700 /opt/labo/transporteur
cd /opt/labo/transporteur
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ac.key -out ac.pem -days 3650 \
  -subj "/CN=AC Transporteur" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout api.key -subj "/CN=api.transporteur.example" -out api.csr 2>/dev/null
openssl x509 -req -in api.csr -CA ac.pem -CAkey ac.key -set_serial 0x1001 -days 365 -out api.pem \
  -extfile <(printf '%s\n' "subjectAltName=DNS:api.transporteur.example" "extendedKeyUsage=serverAuth") 2>/dev/null
cd /
install -d /etc/ssl/certs
cat /opt/labo/transporteur/ac.pem >> /etc/ssl/certs/ca-certificates.crt

install -d /opt/labo
cat > /opt/labo/transporteur.py <<'EOF'
#!/usr/bin/env python3
# Labo : l'API du transporteur, sur Internet (198.51.100.20:443).
import http.server, json, ssl

class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        self.repondre(200, {"api": "transporteur", "etat": "ok"})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.repondre(201, {"etiquette": "TR-2026-118734"})

serveur = http.server.ThreadingHTTPServer(("198.51.100.20", 443), Api)
contexte = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
contexte.load_cert_chain("/opt/labo/transporteur/api.pem", "/opt/labo/transporteur/api.key")
serveur.socket = contexte.wrap_socket(serveur.socket, server_side=True)
serveur.serve_forever()
EOF

# Le proxy d'entreprise : il ne laisse sortir que vers Internet, et journalise tout ce qu'il voit.
cat > /opt/labo/proxy.py <<'EOF'
#!/usr/bin/env python3
# Labo : le proxy d'entreprise (10.41.0.3:3128). Destinations internes refusées, tout est journalisé.
import datetime, http.client, http.server, ipaddress, select, socket, urllib.parse

JOURNAL = "/var/log/labo-proxy.log"
INTERNES = [ipaddress.ip_network(r) for r in ("10.0.0.0/8", "127.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]


def interne(hote):
    try:
        adresse = ipaddress.ip_address(socket.gethostbyname(hote))
    except OSError:
        return True
    return any(adresse in reseau for reseau in INTERNES)


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def journal(self, texte):
        with open(JOURNAL, "a") as f:
            f.write(f"{datetime.datetime.now():%H:%M:%S} {self.client_address[0]} {texte}\n")

    def refuser(self, demande):
        self.journal(f"{demande} REFUSÉ : destination interne")
        self.send_error(403, "Destination interne interdite par la politique du proxy")

    def do_CONNECT(self):
        hote, _, port = self.path.partition(":")
        if interne(hote):
            return self.refuser(f"CONNECT {self.path}")
        try:
            amont = socket.create_connection((hote, int(port or 443)), timeout=5)
        except OSError:
            return self.send_error(502)
        self.journal(f"CONNECT {self.path}")
        self.send_response(200, "Connection established")
        self.end_headers()
        self.close_connection = True
        paires = {self.connection: amont, amont: self.connection}
        while True:
            lisibles, _, _ = select.select(list(paires), [], [], 30)
            if not lisibles:
                break
            for s in lisibles:
                donnees = s.recv(65536)
                if not donnees:
                    amont.close()
                    return
                paires[s].sendall(donnees)

    def relayer(self):
        url = urllib.parse.urlsplit(self.path)
        if interne(url.hostname or ""):
            return self.refuser(f"{self.command} {self.path}")
        self.journal(f"{self.command} {self.path}")
        corps = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        amont = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=5)
        amont.request(self.command, url.path or "/", corps, {"Content-Type": self.headers.get("Content-Type", "")})
        reponse = amont.getresponse()
        donnees = reponse.read()
        self.send_response(reponse.status)
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)

    do_GET = do_POST = relayer


http.server.ThreadingHTTPServer(("10.41.0.3", 3128), Proxy).serve_forever()
EOF

# Le stock (service interne) et les tarifs (service local au serveur).
cat > /opt/labo/service-json.py <<'EOF'
#!/usr/bin/env python3
# Labo : un petit service JSON. Usage : service-json.py <adresse> <port> <contenu>
import http.server, sys

adresse, port, contenu = sys.argv[1], int(sys.argv[2]), (sys.argv[3] + "\n").encode()

class Service(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(contenu)))
        self.end_headers()
        self.wfile.write(contenu)

http.server.ThreadingHTTPServer((adresse, port), Service).serve_forever()
EOF
unite() { # nom description commande
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=Labo : $2 (ne pas toucher)

[Service]
ExecStart=$3
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}
unite lab-proxy "proxy d'entreprise, proxy.interne:3128" "/usr/sbin/ip netns exec proxy /usr/bin/python3 /opt/labo/proxy.py"
unite lab-transporteur "API du transporteur, sur Internet" "/usr/sbin/ip netns exec internet /usr/bin/python3 /opt/labo/transporteur.py"
unite lab-stock "service de stock, stock.interne:8080" "/usr/sbin/ip netns exec stock /usr/bin/python3 /opt/labo/service-json.py 10.42.0.20 8080 '{\"article\": \"CHAISE-ORME\", \"stock\": 42}'"
unite lab-tarifs "service des tarifs, local au serveur, 127.0.0.1:8090" "/usr/bin/python3 /opt/labo/service-json.py 127.0.0.1 8090 '{\"tarif\": 7.90}'"
touch /var/log/labo-proxy.log

# Les variables du proxy, posées pour les shells lors de la mise en place du pare-feu de sortie.
cat > /etc/profile.d/proxy.sh <<'EOF'
# Proxy d'entreprise (politique de sécurité #4860) : toute sortie vers Internet passe par lui.
export http_proxy=http://proxy.interne:3128
export https_proxy=http://proxy.interne:3128
export no_proxy=localhost,127.0.0.1,.interne
EOF

# Le service des expéditions.
useradd --system --no-create-home --shell /usr/sbin/nologin expeditions
install -d /opt/expeditions
cat > /opt/expeditions/expeditions.py <<'EOF'
#!/usr/bin/env python3
# Service des expéditions : POST /expedier. Vérifie le stock (service interne), lit le tarif du jour (service
# local), puis demande une étiquette au transporteur (API sur Internet).
import http.server, json, urllib.request

STOCK = "http://stock.interne:8080/stock"
TARIFS = "http://localhost:8090/tarif"
TRANSPORTEUR = "https://api.transporteur.example/v1/etiquettes"


def appel(nom, url, donnees=None):
    corps = json.dumps(donnees).encode() if donnees is not None else None
    requete = urllib.request.Request(url, data=corps, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(requete, timeout=4) as reponse:
            return json.load(reponse)
    except Exception as erreur:
        raise RuntimeError(f"{nom} injoignable ({url}) : {erreur}")


class Service(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu, ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/expedier":
            return self.repondre(404, {"erreur": "inconnu"})
        try:
            appel("stock", STOCK)
            appel("tarifs", TARIFS)
            etiquette = appel("transporteur", TRANSPORTEUR, {"colis": 1})["etiquette"]
        except RuntimeError as erreur:
            print(f"ERREUR {erreur}", flush=True)
            return self.repondre(502, {"erreur": str(erreur)})
        self.repondre(201, {"expedition": "créée", "etiquette": etiquette})


http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Service).serve_forever()
EOF
cat > /etc/systemd/system/expeditions.service <<'EOF'
[Unit]
Description=Service des expéditions de la boutique
After=network-online.target

[Service]
User=expeditions
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ExecStart=/usr/bin/python3 /opt/expeditions/expeditions.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-proxy lab-transporteur lab-stock lab-tarifs expeditions 2>/dev/null

# Depuis un shell de connexion, le transporteur répond ; le service, lui, n'y arrive pas.
timeout 15 bash -lc 'until curl -fs -o /dev/null https://api.transporteur.example/v1/sante; do sleep 0.3; done'
timeout 10 bash -c 'until curl -s -o /dev/null http://localhost:8000/; do sleep 0.3; done'
code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -X POST http://localhost:8000/expedier)
if [[ $code != 502 ]]; then
  echo "L'expédition aurait dû échouer (HTTP $code)" >&2
  exit 1
fi
