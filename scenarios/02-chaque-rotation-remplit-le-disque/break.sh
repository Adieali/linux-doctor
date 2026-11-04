#!/usr/bin/env bash
# Panne : l'API écrit son journal par StandardOutput=file: (ouvert sans O_APPEND) et logrotate fait un copytruncate.
# Après chaque rotation, l'API continue d'écrire à son ancienne position : app.log devient creux,
# et la copie suivante écrit tous ces zéros pour de vrai. Chaque nuit, un palier de plus sur le disque.
set -euo pipefail

mkdir -p /var/log/app
mount -t tmpfs -o size=256m,mode=755 applogs /var/log/app

cat > /usr/local/bin/app-api <<'EOF'
#!/usr/bin/python3
# Journal d'accès de l'API commandes : une requête par seconde en temps normal.
# Une heure de pointe arrive par /run/app-api.pointe, qui donne le volume de journal à produire, en Mo.
import itertools, os, sys, time

POINTE = '/run/app-api.pointe'
n = itertools.count()

def ecrire(nb):
    t = time.strftime('%Y-%m-%dT%H:%M:%S')
    lignes = ''.join(f"{t} GET /api/orders/{i} 200 {i % 90 + 10}ms\n" for i in itertools.islice(n, nb))
    sys.stdout.write(lignes)
    sys.stdout.flush()
    return len(lignes)

while True:
    if os.path.exists(POINTE):
        with open(POINTE) as f:
            reste = int(f.read()) * 1024 * 1024
        while reste > 0:
            reste -= ecrire(1000)
        os.remove(POINTE)
    ecrire(1)
    time.sleep(1)
EOF
chmod +x /usr/local/bin/app-api

cat > /etc/systemd/system/app-api.service <<'EOF'
[Unit]
Description=API commandes

[Service]
ExecStart=/usr/local/bin/app-api
StandardOutput=file:/var/log/app/app.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/logrotate.d/app <<'EOF'
/var/log/app/app.log {
    daily
    rotate 30
    copytruncate
    missingok
    notifempty
}
EOF

systemctl daemon-reload
systemctl enable --now app-api 2>/dev/null
until [[ -s /var/log/app/app.log ]]; do sleep 0.2; done

# Deux journées de trafic, deux rotations. Les repères servent au check à vérifier qu'aucun journal n'a été jeté.
reperes=/opt/.doctor-02
: > "$reperes"
# Chaque pointe produit exactement 40 Mo : le ticket et la démarche commentée citent ces tailles,
# et la rotation forcée de la solution n'a de place que si elles sont tenues.
pointe() {
  echo 40 > /run/app-api.pointe.tmp
  mv /run/app-api.pointe.tmp /run/app-api.pointe
  while [[ -e /run/app-api.pointe ]]; do sleep 0.1; done
  tail -c 200 /var/log/app/app.log | tail -1 | grep -o 'GET /api/orders/[0-9]* ' >> "$reperes"
}
pointe; logrotate -f /etc/logrotate.d/app
pointe; logrotate -f /etc/logrotate.d/app
pointe
touch -d '2 days ago 00:00' /var/log/app/app.log.2
touch -d 'yesterday 00:00' /var/log/app/app.log.1
