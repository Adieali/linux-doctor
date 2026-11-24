#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

vip=10.100.0.100
porte_vip() {
  if [[ $1 == srv-prod-01 ]]; then ip -br addr show eth1; else ip -n "$1" -br addr show eth1; fi | grep -q "$vip/"
}
une_seule_vip() { porte_vip srv-prod-02 && ! porte_vip srv-prod-01; }
attendre() { local s=$1 i; shift; for ((i = 0; i < s * 4; i++)); do "$@" && return 0; sleep 0.25; done; return 1; }
servi_par() { ip netns exec client curl -s --max-time 2 "http://$vip/" | grep -q "servie par $1"; }
# 20 requêtes sur 5 s, le temps de deux ARP gratuits : avec deux maîtres, le client bascule.
toutes_vers() {
  local i
  ip -n client neigh flush dev eth0
  for ((i = 0; i < 20; i++)); do servi_par "$1" || return 1; sleep 0.25; done
}
pare_feu_strict() { nft list ruleset | grep -q 'hook input .*policy drop'; }

intrus() { # Une machine du LAN qui annonce la VIP avec la priorité maximale.
  ip netns add intrus
  ip -n lan link add p-intrus type veth peer name eth1 netns intrus
  ip -n lan link set p-intrus master br0 up
  ip -n intrus link set lo up
  ip -n intrus addr add 10.100.0.66/24 dev eth1
  ip -n intrus link set eth1 up
  cat > /tmp/intrus.conf <<'EOF'
vrrp_instance vol {
    state MASTER
    interface eth1
    virtual_router_id 51
    priority 254
    advert_int 1
    virtual_ipaddress {
        10.100.0.100/24 dev eth1
    }
}
EOF
  ip netns exec intrus keepalived --dont-fork --use-file=/tmp/intrus.conf --pid=/run/k-intrus.pid \
    --vrrp_pid=/run/k-intrus-vrrp.pid --checkers_pid=/run/k-intrus-chk.pid >/dev/null 2>&1 &
  echo $! > /run/k-intrus.lanceur
}
plus_d_intrus() {
  kill "$(cat /run/k-intrus.lanceur)" 2>/dev/null
  sleep 1
  ip -n lan link del p-intrus 2>/dev/null
  ip netns del intrus 2>/dev/null
  rm -f /tmp/intrus.conf /run/k-intrus*
}

echo "  Rechargement du pare-feu depuis /etc/nftables.conf, comme au prochain démarrage..."
systemctl restart nftables
sleep 5

ok "le pare-feu est chargé, politique drop en entrée" pare_feu_strict
ok "keepalived tourne sur srv-prod-01" systemctl is-active -q keepalived
ok "une seule VIP : sur srv-prod-02, pas sur srv-prod-01" attendre 6 une_seule_vip
ok "20 requêtes d'un client, toutes servies par srv-prod-02" toutes_vers srv-prod-02

if (( fail == 0 )); then
  echo "  srv-prod-02 tombe..."
  systemctl stop lab-keepalived-02
  ok "srv-prod-01 prend la VIP en moins de 5 s" attendre 5 porte_vip srv-prod-01
  ok "les clients le joignent" attendre 3 servi_par srv-prod-01
  echo "  Une machine du LAN annonce la VIP, avec la priorité maximale..."
  intrus
  sleep 5
  ok "srv-prod-01 ne l'écoute pas, et garde la VIP" porte_vip srv-prod-01
  plus_d_intrus
  echo "  srv-prod-02 revient..."
  systemctl start lab-keepalived-02
  ok "srv-prod-02 reprend la VIP, srv-prod-01 la rend" attendre 8 une_seule_vip
else
  echo "  [KO] bascule de test non simulée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
