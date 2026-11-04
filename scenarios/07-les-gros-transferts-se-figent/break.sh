#!/usr/bin/env bash
# Panne : trou noir PMTUD. Le serveur et les postes de Lyon sont en MTU 1500 et négocient un MSS de 1460,
# mais le tunnel entre les deux sites ne passe que 1400 octets. Le routeur jette chaque segment plein
# (DF posé) et répond par un ICMP « fragmentation nécessaire, MTU 1400 ». Le pare-feu du serveur jette
# tout l'ICMP en entrée (règle d'audit contre le ping) : le serveur n'apprend jamais le MTU du chemin et
# renvoie le même segment trop gros jusqu'au timeout. Les échanges de moins de 1400 octets passent.
# Fausses pistes : le tunnel (aucune perte entre routeurs), nginx, le débit.
set -euo pipefail

# Siège : routeur du LAN, et départ du tunnel vers Lyon.
ip netns add siege
ip link add eth1 type veth peer name lan netns siege
ip -n siege link set lo up
ip -n siege link set lan up
ip -n siege addr add 10.20.0.1/24 dev lan
ip addr add 10.20.0.10/24 dev eth1
ip link set eth1 up
ip route add 10.40.0.0/24 via 10.20.0.1

# Le tunnel : 1400 octets, le reste part en en-têtes de chiffrement.
ip netns add agence
ip -n siege link add vers-lyon mtu 1400 type veth peer name vers-siege mtu 1400 netns agence
ip -n siege addr add 172.16.0.1/30 dev vers-lyon
ip -n siege link set vers-lyon up
ip -n siege route add 10.40.0.0/24 via 172.16.0.2
ip netns exec siege sysctl -qw net.ipv4.ip_forward=1
ip -n agence link set lo up
ip -n agence addr add 172.16.0.2/30 dev vers-siege
ip -n agence link set vers-siege up
ip -n agence route add 10.20.0.0/24 via 172.16.0.1
ip netns exec agence sysctl -qw net.ipv4.ip_forward=1

# Un poste de l'agence, sur le LAN de Lyon en MTU 1500.
ip netns add poste
ip -n agence link add lan-lyon type veth peer name eth0 netns poste
ip -n agence addr add 10.40.0.1/24 dev lan-lyon
ip -n agence link set lan-lyon up
ip -n poste link set lo up
ip -n poste addr add 10.40.0.10/24 dev eth0
ip -n poste link set eth0 up
ip -n poste route add default via 10.40.0.1

cat > /usr/local/bin/poste-lyon <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis un poste de l'agence de Lyon (10.40.0.10).
exec ip netns exec poste "$@"
EOF
chmod +x /usr/local/bin/poste-lyon

# L'intranet : des pages légères, et les rapports mensuels.
head -c 2M /dev/urandom > /var/www/html/rapport-octobre.pdf
cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<title>Intranet</title>
<h1>Intranet</h1>
<p><a href="rapport-octobre.pdf">Rapport d'octobre</a></p>
EOF
systemctl restart nginx

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Pare-feu du serveur.
flush ruleset

table inet filtre {
    chain entree {
        type filter hook input priority filter; policy accept;
        # PSSI-12 (audit 2025) : le serveur ne répond pas aux scans. Pas d'ICMP.
        meta l4proto icmp drop
    }
}
EOF
systemctl enable --now nftables 2>/dev/null

timeout 10 bash -c 'until poste-lyon curl -fs -o /dev/null http://10.20.0.10/; do sleep 0.2; done'
if poste-lyon curl -fs -o /dev/null --max-time 3 http://10.20.0.10/rapport-octobre.pdf; then
  echo "Le téléchargement aurait dû se figer" >&2
  exit 1
fi
