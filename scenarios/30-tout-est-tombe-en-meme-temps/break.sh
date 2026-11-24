#!/usr/bin/env bash
# Panne en cascade, puis post-mortem.
# 1. Hier soir, changement #4987 : l'API passe en LOG_LEVEL=DEBUG pour une enquête sur les paniers, « à retirer
#    demain matin ». Personne ne l'a retiré. En DEBUG, chaque requête écrit une dizaine de Ko de journal.
# 2. Les journaux de l'API sont sur le même disque que PostgreSQL (/srv/donnees, 192 Mo).
# 3. Ce matin, le trafic de la campagne pré-Black Friday : le disque se remplit en quelques minutes, PostgreSQL ne
#    peut plus écrire son WAL et s'arrête (PANIC), sans pouvoir redémarrer tant qu'il n'y a pas de place.
# 4. L'API renvoie des 500, les clients réessaient, et chaque erreur écrit sa pile d'appels : le disque reste plein.
# Pièges : supprimer api.log pendant que l'API le tient ouvert (la place ne revient pas) ; supprimer des fichiers de
# pg_wal (la base perd des commandes validées, ou ne redémarre plus) ; libérer de la place sans couper le DEBUG
# (le disque se remplit de nouveau en quelques minutes) ; un post-mortem sans chronologie ni cause racine.
set -euo pipefail

pg() { runuser -u postgres -- psql -X -q -At "$@"; }

# Le disque de données : 192 Mo, pour la base et (erreur de conception) les journaux de l'API.
systemctl stop postgresql
install -d /srv/donnees
mount -t tmpfs -o size=192m tmpfs /srv/donnees
install -d -o postgres -g postgres -m 700 /srv/donnees/postgresql
cp -a /var/lib/postgresql/17/main/. /srv/donnees/postgresql/
rm -rf /var/lib/postgresql/17/main
ln -s /srv/donnees/postgresql /var/lib/postgresql/17/main
cat > /etc/postgresql/17/main/conf.d/10-wal.conf <<'EOF'
# Dimensionné pour le disque de données (/srv/donnees, 192 Mo).
max_wal_size = 64MB
min_wal_size = 32MB
EOF
systemctl enable --now postgresql 2>/dev/null
timeout 30 bash -c 'until runuser -u postgres -- pg_isready -q; do sleep 0.5; done'
pg -c "CREATE ROLE api LOGIN"
runuser -u postgres -- createdb -O api boutique
pg -d boutique <<'EOF'
CREATE TABLE produits (id int PRIMARY KEY, nom text, prix numeric(10,2), stock int);
INSERT INTO produits SELECT i, 'Produit ' || i, (random() * 200)::numeric(10,2), 100 FROM generate_series(1, 400) i;
CREATE TABLE commandes (id bigserial PRIMARY KEY, produit int REFERENCES produits, quantite int,
                        cree_le timestamptz DEFAULT now());
ALTER TABLE produits OWNER TO api;
ALTER TABLE commandes OWNER TO api;
EOF

# L'API de la boutique, derrière nginx.
useradd --system --home-dir /var/lib/api --shell /usr/sbin/nologin api
install -d -o api -g api /srv/donnees/logs
install -d /opt/api /etc/boutique
cat > /opt/api/api.py <<'EOF'
#!/usr/bin/env python3
# API de la boutique (127.0.0.1:8080). Journal : /srv/donnees/logs/api.log, niveau LOG_LEVEL.
import http.server, json, logging, os, random
import psycopg2

logging.basicConfig(filename="/srv/donnees/logs/api.log", level=os.environ.get("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("api")


class Api(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def traiter(self, requete):
        log.debug("requête %s %s, en-têtes : %s", self.command, self.path, dict(self.headers))
        try:
            with psycopg2.connect("dbname=boutique user=api host=/run/postgresql", connect_timeout=2) as conn:
                with conn.cursor() as cur:
                    code, contenu = requete(cur)
            conn.close()
        except psycopg2.Error:
            log.exception("base injoignable pendant %s %s", self.command, self.path)
            return self.repondre(500, {"erreur": "erreur interne"})
        log.info("%s %s %d", self.command, self.path, code)
        self.repondre(code, contenu)

    def do_GET(self):
        if self.path == "/sante":
            return self.repondre(200, {"api": "ok"})

        def produits(cur):
            cur.execute("SELECT id, nom, prix, stock FROM produits ORDER BY id")
            lignes = cur.fetchall()
            log.debug("SQL : SELECT id, nom, prix, stock FROM produits ORDER BY id -> %s", lignes)
            return 200, {"produits": len(lignes)}
        self.traiter(produits)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))

        def commande(cur):
            produit = random.randint(1, 400)
            cur.execute("INSERT INTO commandes (produit, quantite) VALUES (%s, 1) RETURNING id", (produit,))
            numero = cur.fetchone()[0]
            log.debug("SQL : INSERT INTO commandes (produit, quantite) VALUES (%s, 1) -> commande %s", produit, numero)
            return 201, {"commande": numero}
        self.traiter(commande)


http.server.ThreadingHTTPServer(("127.0.0.1", 8080), Api).serve_forever()
EOF
cat > /etc/boutique/api.env <<'EOF'
# Configuration de l'API de la boutique.
# Ticket #4987 : DEBUG temporaire pour l'enquête sur les paniers vides, à retirer demain matin.
LOG_LEVEL=DEBUG
EOF
touch -d 'yesterday 18:05' /etc/boutique/api.env
cat > /etc/systemd/system/api.service <<'EOF'
[Unit]
Description=API de la boutique
After=postgresql.service

[Service]
User=api
EnvironmentFile=/etc/boutique/api.env
ExecStart=/usr/bin/python3 /opt/api/api.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
EOF

# Les clients : la campagne pré-Black Friday. Chaque commande acceptée (201) est notée par le labo.
install -d /opt/labo
cat > /opt/labo/trafic.py <<'EOF'
#!/usr/bin/env python3
# Labo : les clients de la boutique. Rapide pendant la campagne, puis le trafic d'une matinée ordinaire.
# Chaque commande acceptée est notée dans /var/log/labo-commandes.log ; une erreur est réessayée, comme le fait le site.
import json, os, threading, time, urllib.request

def appel(methode, chemin):
    try:
        with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1" + chemin, method=methode, data=b"" if methode == "POST" else None), timeout=5) as r:
            return r.status, json.loads(r.read())
    except Exception:
        return 0, None

def client():
    while True:
        lent = os.path.exists("/run/labo-trafic-lent")
        for _ in range(4):
            appel("GET", "/produits")
        code, contenu = appel("POST", "/commandes")
        if code == 201:
            with open("/var/log/labo-commandes.log", "a") as f:
                f.write(f"{contenu['commande']}\n")
        time.sleep(0.5 if lent else 0.01)

for _ in range(4):
    threading.Thread(target=client, daemon=True).start()
while True:
    time.sleep(60)
EOF
cat > /etc/systemd/system/lab-clients.service <<'EOF'
[Unit]
Description=Labo : les clients de la boutique (ne pas toucher)

[Service]
ExecStart=/usr/bin/python3 /opt/labo/trafic.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
cat > /root/post-mortem-modele.md <<'EOF'
# Post-mortem : <titre de l'incident>

Ticket : <numéro>. Rédigé par : <nom>, le <date>. Sans recherche de coupable : on décrit des faits et des
mécanismes, pas des personnes.

## Résumé

<Trois ou quatre phrases : ce qui s'est passé, combien de temps, ce qui a ramené le service.>

## Impact

<Qui a été touché, combien de temps, ce qui a été perdu ou ne l'a pas été.>

## Chronologie

<Une ligne par événement, avec son heure (HH:MM), tirée des journaux.>

## Cause racine

<Le premier maillon de la chaîne : ce qui, corrigé, aurait évité l'incident.>

## Causes contributives

<Ce qui a laissé la cause racine produire une panne, ou l'a aggravée.>

## Ce qui a bien marché

## Actions

<Une ligne par action : quoi, qui, pour quand.>
EOF

systemctl daemon-reload
systemctl enable --now api nginx lab-clients 2>/dev/null
systemctl restart nginx
: > /var/log/labo-commandes.log

# La campagne : le disque se remplit, PostgreSQL s'arrête.
journal_pg=/var/log/postgresql/postgresql-17-main.log
timeout 240 bash -c "until grep -q 'No space left' $journal_pg; do sleep 1; done"
# Disque plein : le prochain segment de WAL ne peut plus être créé, et PostgreSQL s'arrête.
for _ in {1..60}; do
  grep -q PANIC "$journal_pg" && break
  pg -c 'SELECT pg_switch_wal()' >/dev/null 2>&1 || true
  pg -c 'CHECKPOINT' >/dev/null 2>&1 || true
  sleep 1
done
grep -q PANIC "$journal_pg"
touch /run/labo-trafic-lent
sleep 5
if curl -fs -o /dev/null -X POST http://localhost/commandes; then
  echo "La boutique aurait dû être en panne" >&2
  exit 1
fi
