#!/usr/bin/env bash
# Panne : health check menteur. HAProxy répartit les commandes entre trois serveurs d'application, avec un
# simple check TCP. app2 a perdu sa base (pool de connexions épuisé) : il accepte toujours les connexions,
# donc il reste vert, et répond 500 à une commande sur trois. L'application a deux URL de santé : /sante dit
# seulement que le processus vit (toujours 200), /pret vérifie la base. Un check HTTP sur /sante ment autant.
# Fausses pistes : les stats HAProxy (tout est UP), la base (elle va bien pour app1 et app3), redémarrer app2.
set -euo pipefail

# Les serveurs d'application. Leur état (ok, ou base-ko) est dans /run/labo/app<N>.etat.
install -d /opt/labo /run/labo /srv/app
cat > /opt/labo/app <<'EOF'
#!/usr/bin/env python3
# Labo : un serveur d'application de la boutique, sur le port 8080 + N.
import http.server, json, pathlib, sys, threading

n = sys.argv[1]
etat = pathlib.Path(f"/run/labo/app{n}.etat")
verrou, compteur = threading.Lock(), {"commandes": 0}

class Requete(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu, ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def malade(self):
        return etat.read_text().strip() == "base-ko"

    def do_GET(self):
        if self.path == "/sante":
            self.repondre(200, {"processus": "ok"})
        elif self.path == "/pret":
            if self.malade():
                self.repondre(503, {"base": "pool de connexions épuisé"})
            else:
                self.repondre(200, {"base": "ok"})
        elif self.path == "/labo/commandes":
            self.repondre(200, compteur)
        else:
            self.repondre(404, {"erreur": "inconnu"})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/api/commande":
            return self.repondre(404, {"erreur": "inconnu"})
        with verrou:
            compteur["commandes"] += 1
        if self.malade():
            print(f"app{n} ERREUR base : pool de connexions épuisé (20/20 occupées), commande refusée", file=sys.stderr, flush=True)
            return self.repondre(500, {"erreur": "erreur interne"})
        self.repondre(201, {"commande": "enregistrée", "serveur": f"app{n}"})

http.server.ThreadingHTTPServer(("127.0.0.1", 8080 + int(n)), Requete).serve_forever()
EOF
chmod +x /opt/labo/app
cat > /etc/systemd/system/lab-app@.service <<'EOF'
[Unit]
Description=Labo : serveur d'application app%i de la boutique (ne pas toucher)

[Service]
ExecStart=/opt/labo/app %i
Restart=always

[Install]
WantedBy=multi-user.target
EOF
for i in 1 2 3; do echo ok > "/run/labo/app$i.etat"; done
cat > /srv/app/LISEZMOI <<'EOF'
Boutique, serveurs d'application (équipe dev)

Ports : app1 8081, app2 8082, app3 8083, en écoute sur 127.0.0.1.

Santé :
  GET /sante   le processus répond (liveness). Ne regarde pas la base.
  GET /pret    prêt à servir : base joignable, pool de connexions disponible (readiness).
               200 si prêt, 503 sinon. C'est celle-là qui dit si on peut envoyer du trafic.

API :
  POST /api/commande   enregistre une commande. 201 si c'est fait.
EOF
systemctl daemon-reload
systemctl enable --now lab-app@1 lab-app@2 lab-app@3 2>/dev/null

# HAProxy devant les trois serveurs, à la place de nginx.
systemctl disable --now nginx 2>/dev/null
cat > /etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 2s
    timeout client  30s
    timeout server  30s

frontend boutique
    bind :80
    default_backend app

backend app
    balance roundrobin
    server app1 127.0.0.1:8081 check
    server app2 127.0.0.1:8082 check
    server app3 127.0.0.1:8083 check
EOF
systemctl enable --now haproxy 2>/dev/null
timeout 10 bash -c 'until curl -fs -o /dev/null -X POST http://localhost/api/commande; do sleep 0.2; done'

# 10 h : app2 perd sa base.
echo base-ko > /run/labo/app2.etat
for _ in {1..9}; do curl -s -o /dev/null -X POST http://localhost/api/commande; done

# Repères pour le check : HAProxy et app2 ne doivent pas être redémarrés.
systemctl show -p MainPID --value haproxy > /run/labo/haproxy.pid
systemctl show -p MainPID --value lab-app@2 > /run/labo/app2.pid

erreurs=0
for _ in {1..9}; do
  [[ $(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/api/commande) == 201 ]] || erreurs=$((erreurs + 1))
done
if (( erreurs == 0 )); then
  echo "Une commande sur trois aurait dû échouer" >&2
  exit 1
fi
