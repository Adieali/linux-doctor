#!/usr/bin/env bash
# Panne : nginx n'écoute la boutique que sur la VIP keepalived (exigence de l'audit). Au démarrage, la VIP
# n'existe pas encore : keepalived ne la prend qu'au bout de l'élection VRRP, quelques secondes après son
# lancement. nginx échoue (bind() : Cannot assign requested address), et le Restart=on-failure ajouté après un
# incident précédent le relance toutes les 100 ms : cinq échecs en une demi-seconde, « Start request repeated
# too quickly », nginx reste en échec. Relancé à la main plus tard, il démarre : la VIP est là.
# Pièges pour la réparation : nginx attend déjà network-online.target, et attendre keepalived.service ne sert
# à rien (keepalived démarré ne veut pas dire VIP posée). Un RestartSec plus long passe au démarrage du maître,
# mais sur un nœud de secours la VIP ne vient jamais : nginx tourne en boucle ou abandonne, la page d'état de
# la supervision tombe, et à la bascule personne n'écoute. Écouter sur toutes les adresses sert la boutique
# sur l'adresse propre du serveur (refusé par l'audit).
# Fausses pistes : keepalived (la bascule marche), l'ordre de démarrage, le réseau.
set -euo pipefail

vip=10.100.0.100

# Le LAN de la boutique, srv-prod-02 et un poste client, recréés à chaque démarrage par une unité du labo.
install -d /usr/local/lib/labo
cat > /usr/local/lib/labo/reseau.sh <<'EOF'
#!/bin/bash
# Labo : le LAN de la boutique (un bridge), srv-prod-02 et un poste client. Recréé à chaque démarrage.
set -e
ip netns add lan
ip -n lan link add br0 type bridge mcast_snooping 0
ip -n lan link set br0 up
ip link add eth1 type veth peer name p-srv01 netns lan
ip -n lan link set p-srv01 master br0 up
ip netns add srv-prod-02
ip -n lan link add p-srv02 type veth peer name eth1 netns srv-prod-02
ip -n lan link set p-srv02 master br0 up
ip -n srv-prod-02 link set lo up
ip -n srv-prod-02 addr add 10.100.0.32/24 dev eth1
ip -n srv-prod-02 link set eth1 up
ip netns add client
ip -n lan link add p-client type veth peer name eth0 netns client
ip -n lan link set p-client master br0 up
ip -n client link set lo up
ip -n client addr add 10.100.0.50/24 dev eth0
ip -n client link set eth0 up
EOF
chmod 755 /usr/local/lib/labo/reseau.sh
cat > /etc/systemd/system/lab-reseau.service <<'EOF'
[Unit]
Description=Labo : LAN de la boutique, srv-prod-02 et poste client (ne pas toucher)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target networking.service keepalived.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/labo/reseau.sh

[Install]
WantedBy=multi-user.target
EOF

# srv-prod-01 sur le LAN, par ifupdown, comme le reste de la prod.
cat > /etc/network/interfaces.d/eth1 <<'EOF'
# LAN de la boutique
auto eth1
iface eth1 inet static
    address 10.100.0.21/24
EOF

# srv-prod-02 : l'autre nœud, avec sa boutique et son keepalived.
install -d /srv/srv-prod-02
printf '<!doctype html>\n<title>Boutique</title>\n<p>Boutique, servie par srv-prod-02</p>\n' > /srv/srv-prod-02/index.html
cat > /etc/systemd/system/lab-web-02.service <<'EOF'
[Unit]
Description=Labo : la boutique sur srv-prod-02 (ne pas toucher)
Requires=lab-reseau.service
After=lab-reseau.service

[Service]
ExecStart=/usr/sbin/ip netns exec srv-prod-02 /usr/bin/python3 -m http.server 80 --directory /srv/srv-prod-02
Restart=always

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/keepalived/srv-prod-02.conf <<'EOF'
# Labo : keepalived de srv-prod-02, nœud de secours de la boutique.
global_defs {
    router_id srv-prod-02
}

vrrp_instance boutique {
    state BACKUP
    interface eth1
    virtual_router_id 51
    priority 100
    advert_int 1
    virtual_ipaddress {
        10.100.0.100/24 dev eth1
    }
}
EOF
cat > /etc/systemd/system/lab-keepalived-02.service <<'EOF'
[Unit]
Description=Labo : keepalived de srv-prod-02 (ne pas toucher)
Requires=lab-reseau.service
After=lab-reseau.service

[Service]
ExecStart=/usr/sbin/ip netns exec srv-prod-02 /usr/sbin/keepalived --dont-fork --log-console --use-file=/etc/keepalived/srv-prod-02.conf --pid=/run/keepalived-02.pid --vrrp_pid=/run/keepalived-02-vrrp.pid --checkers_pid=/run/keepalived-02-checkers.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# srv-prod-01 : nœud maître (priorité 150). Les deux nœuds démarrent en BACKUP, la priorité départage.
cat > /etc/keepalived/keepalived.conf <<'EOF'
# keepalived de srv-prod-01 : nœud maître de la boutique (VIP 10.100.0.100).
global_defs {
    router_id srv-prod-01
}

vrrp_instance boutique {
    state BACKUP
    interface eth1
    virtual_router_id 51
    priority 150
    advert_int 1
    virtual_ipaddress {
        10.100.0.100/24 dev eth1
    }
}
EOF

# nginx : la boutique sur la VIP seulement (audit), la page d'état de la supervision sur l'adresse du nœud.
printf '<!doctype html>\n<title>Boutique</title>\n<p>Boutique, servie par srv-prod-01</p>\n' > /var/www/html/index.html
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/boutique <<'EOF'
# La boutique : sur la VIP seulement. Audit PCI DSS (#4702) : rien sur les adresses propres des serveurs.
server {
    listen 10.100.0.100:80;
    root /var/www/html;
}

# Page d'état pour la supervision, sur l'adresse du nœud : interrogée sur les deux nœuds, maître ou secours.
server {
    listen 10.100.0.21:8080;
    location = /etat {
        stub_status;
    }
}
EOF
ln -s ../sites-available/boutique /etc/nginx/sites-enabled/boutique
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/redemarrage.conf <<'EOF'
[Service]
# Incident #4512 : nginx arrêté par l'OOM killer, la boutique coupée deux heures. Il redémarre seul désormais.
Restart=on-failure
EOF

cat > /usr/local/bin/client <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis le poste d'un client, sur le LAN de la boutique (10.100.0.50).
exec ip netns exec client "$@"
EOF
cat > /usr/local/bin/srv-prod-02 <<'EOF'
#!/bin/bash
# Labo : lance une commande sur srv-prod-02, l'autre nœud du cluster (comme par SSH).
exec ip netns exec srv-prod-02 "$@"
EOF
chmod +x /usr/local/bin/client /usr/local/bin/srv-prod-02

systemctl daemon-reload
systemctl enable lab-reseau lab-web-02 lab-keepalived-02 keepalived nginx 2>/dev/null

# Avant le redémarrage, la boutique tourne sur srv-prod-01.
systemctl start lab-reseau
ifup eth1
systemctl start lab-web-02 lab-keepalived-02 keepalived
timeout 15 bash -c "until ip -br addr show eth1 | grep -q '$vip/'; do sleep 0.25; done"
systemctl restart nginx
timeout 10 bash -c "until ip netns exec client curl -fs -o /dev/null http://$vip/; do sleep 0.3; done"

# Le redémarrage de cette nuit, pour les correctifs du mois.
exit 3
