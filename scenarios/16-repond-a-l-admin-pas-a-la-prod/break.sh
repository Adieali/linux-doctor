#!/usr/bin/env bash
# Panne : routage asymétrique. Hier, un collègue a ajouté l'interface d'admin (eth2) avec une route par
# défaut de métrique 10, plus prioritaire que celle de la prod (100), « pour que les mises à jour passent
# par l'admin ». Pour un client d'Internet, la route de retour passe donc par le routeur d'admin, qui ne
# sait pas l'acheminer. Pire : le filtrage du chemin de retour strict (CIS, rp_filter=1) jette les requêtes
# des clients dès leur arrivée sur eth1, puisque la route vers leur adresse sort par eth2. tcpdump voit les
# SYN, nginx ne voit rien. Le bastion, le miroir et la supervision passent par eth2 et marchent.
# Fausses pistes : nginx (il répond en local), le pare-feu (vide), le routeur de prod (il répond au ping).
set -euo pipefail

routeur() { # nom : un netns qui route, sans filtrage du chemin de retour
  ip netns add "$1"
  ip -n "$1" link set lo up
  ip netns exec "$1" sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
}
hote() { # nom adresse/masque passerelle [adresse/masque supplémentaire] : une machine derrière un routeur
  ip -n "$1" link set lo up
  ip -n "$1" addr add "$2" dev eth0
  [[ -n ${4:-} ]] && ip -n "$1" addr add "$4" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" route add default via "$3"
}

# Durcissement CIS, appliqué par l'équipe sécurité sur tous les serveurs. Au démarrage, avant les
# interfaces : eth1 et eth2 héritent des valeurs « default ». Sinon, elles garderaient la valeur héritée de
# la machine hôte (2, lâche, sur un hôte Ubuntu), et le noyau retiendrait la plus grande des deux : 2.
cat > /etc/sysctl.d/60-cis.conf <<'EOF'
# Durcissement CIS Debian (équipe sécurité, référentiel 2025). Ne pas modifier sans dérogation.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
sysctl -q -p /etc/sysctl.d/60-cis.conf

# Prod : routeur-prod entre le LAN de prod (eth1) et Internet, avec deux plages de clients.
routeur routeur-prod
ip link add eth1 type veth peer name lan netns routeur-prod
ip -n routeur-prod addr add 10.60.0.1/24 dev lan
ip -n routeur-prod link set lan up
ip netns add internet
ip -n routeur-prod link add wan type veth peer name eth0 netns internet
ip -n routeur-prod addr add 203.0.113.1/24 dev wan
ip -n routeur-prod addr add 198.51.100.1/24 dev wan
ip -n routeur-prod link set wan up
hote internet 203.0.113.50/24 203.0.113.1 198.51.100.7/24

# Admin : routeur-admin entre le LAN d'admin (eth2), le bastion et les services (miroir, supervision).
routeur routeur-admin
ip link add eth2 type veth peer name lan netns routeur-admin
ip -n routeur-admin addr add 10.70.0.1/24 dev lan
ip -n routeur-admin link set lan up
ip netns add bastion
ip -n routeur-admin link add vers-bastion type veth peer name eth0 netns bastion
ip -n routeur-admin addr add 10.80.0.1/24 dev vers-bastion
ip -n routeur-admin link set vers-bastion up
hote bastion 10.80.0.5/24 10.80.0.1
ip netns add services
ip -n routeur-admin link add vers-services type veth peer name eth0 netns services
ip -n routeur-admin addr add 10.90.0.1/24 dev vers-services
ip -n routeur-admin link set vers-services up
hote services 10.90.0.5/24 10.90.0.1 10.90.0.20/24

# Le serveur : plus de route par défaut vers Docker, ses deux réseaux viennent d'ifupdown.
ip route del default 2>/dev/null || true
cat > /etc/network/interfaces.d/prod <<'EOF'
# Réseau de prod : le frontal de la boutique, derrière routeur-prod.
auto eth1
iface eth1 inet static
    address 10.60.0.10/24
    gateway 10.60.0.1
    metric 100
EOF
cat > /etc/network/interfaces.d/admin <<'EOF'
# Réseau d'admin (ticket #4811, ajouté hier) : bastion, miroir de paquets, supervision.
# Demande de la sécurité : les mises à jour et la supervision passent par l'admin, jamais par la prod.
auto eth2
iface eth2 inet static
    address 10.70.0.10/24
    gateway 10.70.0.1
    metric 10
EOF
ifup eth1 >/dev/null 2>&1
ifup eth2 >/dev/null 2>&1

# La boutique.
printf '<!doctype html>\n<title>Boutique</title>\n<h1>Boutique</h1>\n' > /var/www/html/index.html
systemctl restart nginx

# Le miroir de paquets, côté services.
install -d /srv/miroir/debian/dists/trixie
printf 'Origin: Debian\nSuite: stable\nCodename: trixie\n' > /srv/miroir/debian/dists/trixie/Release
cat > /etc/systemd/system/lab-miroir.service <<'EOF'
[Unit]
Description=Labo : miroir de paquets interne, 10.90.0.5 (ne pas toucher)

[Service]
ExecStart=/usr/sbin/ip netns exec services /usr/bin/python3 -m http.server 80 --bind 10.90.0.5 --directory /srv/miroir
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# La supervision, côté services : elle interroge le serveur sur son adresse d'admin, chaque minute.
install -d /opt/labo
cat > /opt/labo/supervision <<'EOF'
#!/bin/bash
code=$(ip netns exec services curl -s -o /dev/null --max-time 3 --interface 10.90.0.20 -w '%{http_code}' http://10.70.0.10/)
logger -t supervision "srv-prod-01 (10.70.0.10) : HTTP $code"
EOF
chmod +x /opt/labo/supervision
cat > /etc/systemd/system/lab-supervision.service <<'EOF'
[Unit]
Description=Labo : la supervision interroge srv-prod-01 (ne pas toucher)

[Service]
Type=oneshot
ExecStart=/opt/labo/supervision
EOF
cat > /etc/systemd/system/lab-supervision.timer <<'EOF'
[Unit]
Description=Labo : supervision de srv-prod-01, chaque minute

[Timer]
OnCalendar=*:*:00

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now lab-miroir lab-supervision.timer 2>/dev/null

# Commandes du labo pour tester depuis l'extérieur.
cat > /usr/local/bin/client-internet <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis un client de la boutique, sur Internet (203.0.113.50).
exec ip netns exec internet "$@"
EOF
cat > /usr/local/bin/bastion <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis le bastion des admins (10.80.0.5).
exec ip netns exec bastion "$@"
EOF
chmod +x /usr/local/bin/client-internet /usr/local/bin/bastion

timeout 10 bash -c 'until curl -fs -o /dev/null http://10.90.0.5/debian/dists/trixie/Release; do sleep 0.2; done'
systemctl start lab-supervision
bastion curl -fs -o /dev/null --max-time 3 http://10.70.0.10/
if client-internet curl -fs -o /dev/null --max-time 3 http://10.60.0.10/; then
  echo "La boutique aurait dû être injoignable depuis Internet" >&2
  exit 1
fi
