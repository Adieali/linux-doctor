#!/usr/bin/env bash
# Panne : premier redémarrage depuis neuf mois, et deux changements qui attendaient ce moment.
# 1. /etc/fstab monte toujours le disque de sauvegarde USB, retiré du serveur en octobre (les sauvegardes partent
#    sur le NAS depuis). Au démarrage, systemd attend ce disque 1 min 30, puis local-fs.target échoue : mode urgence.
# 2. Le durcissement CIS a ajouté /tmp en tmpfs noexec dans fstab il y a trois semaines (Ansible, état « present » :
#    la ligne est écrite, rien n'est monté). Il prend effet à ce démarrage. Le générateur de factures est une archive
#    autoextractible qui se décompresse dans TMPDIR (/tmp par défaut) et s'y exécute : Permission denied.
# Pièges pour la réparation : nofail laisse une unité en échec à chaque démarrage (la supervision alerte) et,
# sans délai, 1 min 30 d'attente ; remonter /tmp en exec ou retirer noexec casse le CIS ; TMPDIR=/var/tmp ou
# /dev/shm donne un dossier partagé, écrit par tous, et exécutable ; PrivateTmp=yes hérite du noexec de /tmp.
# Fausses pistes : le noyau mis à jour, nginx (il ne démarre pas en mode urgence, rien à voir).
set -euo pipefail

useradd --system --home-dir /var/lib/boutique --shell /usr/sbin/nologin boutique
install -d -o boutique -g boutique /var/lib/boutique /var/lib/boutique/factures
install -d /opt/boutique /opt/facturation /srv/sauvegardes

# Le générateur de factures de l'éditeur : une archive autoextractible, comme celles de makeself.
# Le moteur est décompressé dans un dossier temporaire, exécuté, puis effacé.
moteur=$(mktemp -d)
install -d "$moteur/bin"
cat > "$moteur/bin/generer" <<'EOF'
#!/usr/bin/python3
# Moteur de facturation Factura 4.2 (rendu PDF simplifié pour le labo).
import datetime, pathlib, sys

commande, sortie = sys.argv[1], pathlib.Path(sys.argv[2])
facture = sortie / f"F-{commande}.pdf"
facture.write_text(f"%PDF-1.4\n% Facture de la commande {commande}, {datetime.date.today()}\n")
print(facture)
EOF
chmod 755 "$moteur/bin/generer"
{
  cat <<'EOF'
#!/bin/sh
# Factura 4.2 : générateur de factures PDF. Archive autoextractible, ne pas modifier (signée par l'éditeur).
# Usage : facturation.run <commande> <dossier de sortie>
set -e
dest=$(mktemp -d "${TMPDIR:-/tmp}/facturation.XXXXXX")
trap 'rm -rf "$dest"' EXIT
sed '1,/^__ARCHIVE__$/d' "$0" | base64 -d | tar -xz -C "$dest"
"$dest/bin/generer" "$@"
exit
__ARCHIVE__
EOF
  tar -cz -C "$moteur" bin | base64
} > /opt/facturation/facturation.run
chmod 755 /opt/facturation/facturation.run
rm -rf "$moteur"

cat > /opt/boutique/boutique.py <<'EOF'
#!/usr/bin/env python3
# La boutique (127.0.0.1:8000, derrière nginx) : pages et génération des factures.
import http.server, itertools, json, subprocess, sys

numeros = itertools.count(52031)


class Boutique(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self, code, contenu):
        corps = (json.dumps(contenu, ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        self.repondre(200, {"boutique": "ouverte"})

    def do_POST(self):
        if self.path != "/api/factures":
            return self.repondre(404, {"erreur": "introuvable"})
        commande = next(numeros)
        r = subprocess.run(["/opt/facturation/facturation.run", str(commande), "/var/lib/boutique/factures"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"facture {commande} : échec du générateur ({r.returncode}) : {r.stderr.strip()}", file=sys.stderr, flush=True)
            return self.repondre(500, {"erreur": "génération de la facture impossible"})
        self.repondre(201, {"facture": r.stdout.strip()})


http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Boutique).serve_forever()
EOF
cat > /etc/systemd/system/boutique.service <<'EOF'
[Unit]
Description=Boutique en ligne
After=network.target

[Service]
User=boutique
ExecStart=/usr/bin/python3 /opt/boutique/boutique.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
EOF

# La sauvegarde : sur le NAS depuis octobre. Le script le dit, fstab l'a oublié.
cat > /usr/local/bin/sauvegarde <<'EOF'
#!/bin/sh
# Sauvegarde de nuit de la boutique.
# Depuis le 14 octobre (ticket #4410) : envoyée sur le NAS (sauvegarde.interne) par rsync.
# Le disque USB de /srv/sauvegardes a été débranché et rendu au datacenter le même jour.
set -e
rsync -a --delete /var/lib/boutique/ sauvegarde@sauvegarde.interne:/sauvegardes/srv-prod-01/
EOF
chmod 755 /usr/local/bin/sauvegarde
echo '30 1 * * * root /usr/local/bin/sauvegarde' > /etc/cron.d/sauvegarde

cat > /etc/fstab <<'EOF'
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# Disque de sauvegarde USB (ticket #3920)
UUID=5f3a9c2e-1b7d-4e8a-9c41-2d6b8e0f7a13 /srv/sauvegardes ext4 defaults 0 2
# CIS 1.1.2.1 à 1.1.2.4 : /tmp séparé, nodev, nosuid, noexec (Ansible, rôle durcissement-cis)
tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime,size=512M 0 0
EOF
touch -d '3 weeks ago' /etc/fstab

systemctl daemon-reload
systemctl enable boutique nginx 2>/dev/null

# Avant le redémarrage, tout marche : la facture passe.
systemctl start boutique
systemctl restart nginx
timeout 10 bash -c 'until curl -fs -o /dev/null http://localhost/; do sleep 0.3; done'
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/api/factures)
[[ $code == 201 ]] || { echo "La facture aurait dû passer avant le redémarrage (HTTP $code)" >&2; exit 1; }
rm -f /var/lib/boutique/factures/*

# La maintenance de cette nuit : redémarrage pour le noyau.
exit 3
