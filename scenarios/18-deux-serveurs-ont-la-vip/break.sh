#!/usr/bin/env bash
# Panne : split brain keepalived. srv-prod-01 (secours, priorité 100) n'entend plus les annonces VRRP de
# srv-prod-02 (maître, priorité 150). Le pare-feu standard posé hier sur srv-prod-01 autorise bien le VRRP,
# mais depuis 10.100.0.22, l'adresse de srv-prod-02 dans la CMDB. srv-prod-02 a été réadressé en
# 10.100.0.32 le mois dernier. Sans annonce, srv-prod-01 se déclare maître : les deux nœuds portent la VIP,
# et leurs ARP gratuits périodiques font basculer les clients de l'un à l'autre. Les paniers, en session
# locale sur chaque nœud, se perdent à chaque bascule.
# Fausses pistes : la règle VRRP existe, le switch, keepalived lui-même (il fait ce qu'on lui dit).
set -euo pipefail

vip=10.100.0.100

# Le LAN de la boutique : un bridge, dans le netns « lan ».
ip netns add lan
ip -n lan link add br0 type bridge mcast_snooping 0
ip -n lan link set br0 up
ip link add eth1 type veth peer name p-srv01 netns lan
ip -n lan link set p-srv01 master br0 up
ip netns add srv-prod-02
ip -n lan link add p-srv02 type veth peer name eth1 netns srv-prod-02
ip -n lan link set p-srv02 master br0 up
ip netns add client
ip -n lan link add p-client type veth peer name eth0 netns client
ip -n lan link set p-client master br0 up

ip addr add 10.100.0.21/24 dev eth1
ip link set eth1 up
ip -n srv-prod-02 link set lo up
ip -n srv-prod-02 addr add 10.100.0.32/24 dev eth1
ip -n srv-prod-02 link set eth1 up
ip -n client link set lo up
ip -n client addr add 10.100.0.50/24 dev eth0
ip -n client link set eth0 up

# La boutique, sur chaque nœud. Les paniers sont en session locale : chaque nœud a les siens.
printf '<!doctype html>\n<title>Boutique</title>\n<p>Boutique, servie par srv-prod-01</p>\n' > /var/www/html/index.html
systemctl restart nginx
install -d /srv/srv-prod-02
printf '<!doctype html>\n<title>Boutique</title>\n<p>Boutique, servie par srv-prod-02</p>\n' > /srv/srv-prod-02/index.html
cat > /etc/systemd/system/lab-web-02.service <<'EOF'
[Unit]
Description=Labo : la boutique sur srv-prod-02 (ne pas toucher)

[Service]
ExecStart=/usr/sbin/ip netns exec srv-prod-02 /usr/bin/python3 -m http.server 80 --directory /srv/srv-prod-02
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# keepalived : srv-prod-02 maître (150), srv-prod-01 secours (100), VIP 10.100.0.100.
cat > /etc/keepalived/srv-prod-02.conf <<'EOF'
# Labo : keepalived de srv-prod-02, nœud maître de la boutique.
global_defs {
    router_id srv-prod-02
    vrrp_garp_master_refresh 5
}

vrrp_instance boutique {
    state MASTER
    interface eth1
    virtual_router_id 51
    priority 150
    advert_int 1
    virtual_ipaddress {
        10.100.0.100/24 dev eth1
    }
}
EOF
cat > /etc/systemd/system/lab-keepalived-02.service <<'EOF'
[Unit]
Description=Labo : keepalived de srv-prod-02 (ne pas toucher)

[Service]
ExecStart=/usr/sbin/ip netns exec srv-prod-02 /usr/sbin/keepalived --dont-fork --log-console --use-file=/etc/keepalived/srv-prod-02.conf --pid=/run/keepalived-02.pid --vrrp_pid=/run/keepalived-02-vrrp.pid --checkers_pid=/run/keepalived-02-checkers.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/keepalived/keepalived.conf <<'EOF'
# keepalived de srv-prod-01 : nœud de secours de la boutique (VIP 10.100.0.100).
global_defs {
    router_id srv-prod-01
    # ARP gratuits toutes les 5 s quand on est maître : les clients et les switchs suivent la VIP.
    vrrp_garp_master_refresh 5
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

# Le pare-feu standard des serveurs de prod, déployé hier soir sur srv-prod-01.
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Pare-feu standard des serveurs de prod (ticket sécurité #4830).
flush ruleset

table inet filtre {
    chain entree {
        type filter hook input priority filter; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        tcp dport { 22, 80, 443 } accept
        # Cluster de la boutique : VRRP entre les deux nœuds, et seulement entre eux (CMDB : srv-prod-02).
        ip saddr 10.100.0.22 ip protocol vrrp accept
    }
}
EOF

systemctl daemon-reload
systemctl enable --now lab-web-02 lab-keepalived-02 2>/dev/null
timeout 10 bash -c "until ip -n srv-prod-02 -br addr show eth1 | grep -q '$vip/'; do sleep 0.25; done"
systemctl enable --now nftables keepalived 2>/dev/null

# Commandes du labo.
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

# Sans annonce de srv-prod-02, srv-prod-01 passe maître après quelques secondes : deux VIP.
timeout 15 bash -c "until ip -br addr show eth1 | grep -q '$vip/'; do sleep 0.25; done"
ip -n srv-prod-02 -br addr show eth1 | grep -q "$vip/"
