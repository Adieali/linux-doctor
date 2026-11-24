#!/usr/bin/env bash
# Panne en deux couches, l'une cachant l'autre.
# 1. /etc/hosts fige api.paiement.example sur l'ancienne plateforme du prestataire (migration de mars 2025,
#    « temporaire »). Le prestataire l'a éteinte ce matin : No route to host.
# 2. Une fois l'entrée retirée, le nom part dans le DNS, avec le resolv.conf du modèle commun : ndots:5
#    (copié d'un pod Kubernetes) et search prod.boutique.lan. Un nom à moins de 5 points est d'abord essayé
#    avec la liste de recherche : api.paiement.example.prod.boutique.lan, que le joker du DNS interne
#    (*.prod.boutique.lan, pour la recette) envoie sur le frontal d'accueil. Le certificat ne correspond pas.
# dig, qui n'utilise ni /etc/hosts ni la liste de recherche, donne la bonne adresse à chaque fois.
# Fausses pistes : le prestataire, le certificat, le DNS (dig est juste).
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

# Le réseau : le serveur, le DNS interne, le frontal d'accueil, le stock, et Internet.
ip netns add routeur
ip -n routeur link set lo up
routeur routeur
ip link add eth1 type veth peer name serveurs netns routeur
ip -n routeur addr add 10.60.0.1/24 dev serveurs
ip -n routeur link set serveurs up
ip addr add 10.60.0.10/24 dev eth1
ip link set eth1 up
ip route del default 2>/dev/null || true
ip route add default via 10.60.0.1
lien dns 10.61.0.53/24 10.61.0.1/24 vers-dns
lien accueil 10.62.0.80/24 10.62.0.1/24 vers-accueil
lien stock 10.63.0.21/24 10.63.0.1/24 vers-stock
lien internet 198.51.100.30/24 198.51.100.1/24 wan

# Le DNS interne (équipe infra) : la zone interne, son joker, et les noms d'Internet dont le labo a besoin.
install -d /etc/labo
cat > /etc/labo/dns.conf <<'EOF'
# Labo : le DNS interne de l'équipe infra (10.61.0.53).
no-resolv
no-hosts
listen-address=10.61.0.53
bind-interfaces
host-record=stock.prod.boutique.lan,10.63.0.21
host-record=paiements.prod.boutique.lan,10.60.0.10
# Joker : tout autre nom en .prod.boutique.lan arrive sur le frontal d'accueil (environnements de recette).
address=/prod.boutique.lan/10.62.0.80
# Internet, vu par le labo.
host-record=api.paiement.example,198.51.100.30
host-record=transporteur.example,198.51.100.40
EOF

# Les certificats : l'AC d'entreprise (frontal d'accueil) et l'AC du prestataire, toutes deux de confiance.
install -d -m 700 /opt/labo/pki
cd /opt/labo/pki
ac() { # nom sujet
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1-ac.key" -out "$1-ac.pem" -days 3650 \
    -subj "/CN=$2" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
}
certificat() { # ac nom-du-fichier nom-dns
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$2.key" -subj "/CN=$3" -out "$2.csr" 2>/dev/null
  openssl x509 -req -in "$2.csr" -CA "$1-ac.pem" -CAkey "$1-ac.key" -set_serial "0x$(openssl rand -hex 8)" -days 365 -out "$2.pem" \
    -extfile <(printf '%s\n' "subjectAltName=DNS:$3" "extendedKeyUsage=serverAuth") 2>/dev/null
  rm -f "$2.csr"
}
ac entreprise "AC Boutique"
ac paiement "AC Prestataire de paiement"
certificat entreprise accueil "*.prod.boutique.lan"
certificat paiement api "api.paiement.example"
cd /
install -d /etc/ssl/certs
cat /opt/labo/pki/entreprise-ac.pem /opt/labo/pki/paiement-ac.pem >> /etc/ssl/certs/ca-certificates.crt

# Les services du labo.
install -d /opt/labo
cat > /opt/labo/service.py <<'EOF'
#!/usr/bin/env python3
# Labo : un petit service HTTP(S) qui répond toujours la même chose.
# Usage : service.py <adresse> <port> <code> <contenu> [certificat clé]
import http.server, ssl, sys

adresse, port, code, contenu = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), (sys.argv[4] + "\n").encode()

class Service(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(contenu)))
        self.end_headers()
        self.wfile.write(contenu)

    do_GET = do_POST = repondre

serveur = http.server.ThreadingHTTPServer((adresse, port), Service)
if len(sys.argv) > 5:
    contexte = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    contexte.load_cert_chain(sys.argv[5], sys.argv[6])
    serveur.socket = contexte.wrap_socket(serveur.socket, server_side=True)
serveur.serve_forever()
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
pki=/opt/labo/pki
unite lab-dns "DNS interne, 10.61.0.53" "/usr/sbin/ip netns exec dns /usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/labo/dns.conf --pid-file=/run/labo-dns.pid"
unite lab-accueil "frontal d'accueil des environnements de recette, 10.62.0.80" "/usr/sbin/ip netns exec accueil /usr/bin/python3 /opt/labo/service.py 0.0.0.0 443 404 '{\"erreur\": \"environnement inconnu\"}' $pki/accueil.pem $pki/accueil.key"
unite lab-stock "service de stock, stock.prod.boutique.lan" "/usr/sbin/ip netns exec stock /usr/bin/python3 /opt/labo/service.py 0.0.0.0 8080 200 '{\"reserve\": true}'"
unite lab-paiement "API du prestataire de paiement, sur Internet" "/usr/sbin/ip netns exec internet /usr/bin/python3 /opt/labo/service.py 0.0.0.0 443 201 '{\"paiement\": \"accepté\"}' $pki/api.pem $pki/api.key"

# Le résolveur du serveur : le modèle commun, déployé la semaine dernière.
cat > /etc/resolv.conf <<'EOF'
# Résolveur interne (modèle commun de l'équipe infra, v3).
nameserver 10.61.0.53
search prod.boutique.lan boutique.lan
options ndots:5 timeout:1 attempts:2
EOF
# L'entrée posée pendant la migration du prestataire, en mars 2025.
cat >> /etc/hosts <<'EOF'
# Migration PSP (mars 2025) : nouvelle plateforme pas encore dans le DNS. Temporaire, à retirer.
198.51.100.99 api.paiement.example
EOF

# Le service des paiements.
useradd --system --no-create-home --shell /usr/sbin/nologin paiements
install -d /opt/paiements
cat > /opt/paiements/paiements.py <<'EOF'
#!/usr/bin/env python3
# Service des paiements : POST /payer. Réserve le stock (service interne, nom court), puis fait payer par le
# prestataire (API sur Internet).
import http.server, json, urllib.request

STOCK = "http://stock:8080/reserve"
PRESTATAIRE = "https://api.paiement.example/v1/paiements"


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
        if self.path != "/payer":
            return self.repondre(404, {"erreur": "inconnu"})
        try:
            appel("stock", STOCK)
            resultat = appel("paiement", PRESTATAIRE, {"montant": 49.90})
        except RuntimeError as erreur:
            print(f"ERREUR {erreur}", flush=True)
            return self.repondre(502, {"erreur": str(erreur)})
        self.repondre(201, resultat)


http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Service).serve_forever()
EOF
cat > /etc/systemd/system/paiements.service <<'EOF'
[Unit]
Description=Service des paiements de la boutique
After=network-online.target

[Service]
User=paiements
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ExecStart=/usr/bin/python3 /opt/paiements/paiements.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-dns lab-accueil lab-stock lab-paiement paiements 2>/dev/null

for _ in {1..50}; do
  [[ $(dig +short @10.61.0.53 api.paiement.example) == 198.51.100.30 ]] && break
  sleep 0.3
done
timeout 10 bash -c 'until curl -s -o /dev/null http://localhost:8000/; do sleep 0.3; done'
code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -X POST http://localhost:8000/payer)
if [[ $code != 502 ]]; then
  echo "Le paiement aurait dû échouer (HTTP $code)" >&2
  exit 1
fi
