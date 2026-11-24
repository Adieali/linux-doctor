#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

depuis() { local ns=$1; shift; ip netns exec "$ns" curl -fs --max-time 3 -o /dev/null "$@"; }

# Effectif : le noyau applique le plus strict entre « all » et l'interface (1 = strict, 2 = lâche).
strict() {
  local i a b
  a=$(sysctl -n net.ipv4.conf.all.rp_filter)
  for i in eth1 eth2; do
    b=$(sysctl -n "net.ipv4.conf.$i.rp_filter")
    (( (a > b ? a : b) == 1 )) || return 1
  done
}
sortie() { ip route get "$1" | grep -q "dev $2"; }

# Comme au prochain démarrage : interfaces descendues (leurs routes disparaissent de toutes les tables),
# règles de routage d'origine, réglages du noyau relus, puis ifupdown.
echo "  Redémarrage simulé : ifdown, routes et règles effacées, sysctl --system, ifup..."
ifdown --force eth1 eth2 >/dev/null 2>&1
ip link set eth1 down
ip link set eth2 down
ip addr flush dev eth1
ip addr flush dev eth2
ip rule flush
ip rule add pref 32766 lookup main
ip rule add pref 32767 lookup default
sysctl -q --system >/dev/null 2>&1
ifup eth1 >/dev/null 2>&1
ifup eth2 >/dev/null 2>&1

ok "le filtrage du chemin de retour reste strict sur eth1 et eth2 (CIS)" strict
ok "un client d'Internet charge la boutique" depuis internet http://10.60.0.10/
ok "un client d'une autre plage d'Internet aussi" depuis internet --interface 198.51.100.7 http://10.60.0.10/
ok "les admins se connectent depuis le bastion" depuis bastion http://10.70.0.10/
ok "la supervision interroge le serveur" depuis services --interface 10.90.0.20 http://10.70.0.10/
ok "les mises à jour joignent le miroir" curl -fs --max-time 3 -o /dev/null http://10.90.0.5/debian/dists/trixie/Release
ok "elles passent par le réseau d'admin, pas par la prod" sortie 10.90.0.5 eth2
ok "les réponses aux clients partent par la prod" sortie 203.0.113.50 eth1

if (( fail == 0 )); then
  echo "  L'équipe réseau ouvre le VPN d'admin, sur une plage choisie aujourd'hui : 10.85.0.0/24..."
  ip netns add vpn
  ip -n routeur-admin link add vers-vpn type veth peer name eth0 netns vpn
  ip -n routeur-admin addr add 10.85.0.1/24 dev vers-vpn
  ip -n routeur-admin link set vers-vpn up
  ip -n vpn link set lo up
  ip -n vpn addr add 10.85.0.9/24 dev eth0
  ip -n vpn link set eth0 up
  ip -n vpn route add default via 10.85.0.1
  ok "un admin connecté au VPN atteint le serveur, sans changer sa configuration" depuis vpn http://10.70.0.10/
  ip -n routeur-admin link del vers-vpn
  ip netns del vpn
else
  echo "  [KO] arrivée du VPN d'admin non simulée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
