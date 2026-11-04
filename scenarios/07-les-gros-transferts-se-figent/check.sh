#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

rapport=/var/www/html/rapport-octobre.pdf
attendu=$(md5sum < "$rapport")

telecharge() { [[ $(ip netns exec poste curl -fs --max-time 5 http://10.20.0.10/rapport-octobre.pdf | md5sum) == "$attendu" ]]; }
tunnel() { ip -n siege link set vers-lyon mtu "$1" && ip -n agence link set vers-siege mtu "$1"; }

# Partout, pas seulement sur le serveur : un poste qui a appris le MTU du chemin annonce un MSS plus petit,
# et le serveur n'a alors plus rien à découvrir.
oublier_mtu() { ip route flush cache; for n in siege agence poste; do ip -n "$n" route flush cache; done; }

# Le pare-feu tel qu'il repartira au prochain démarrage, et un MTU de chemin à réapprendre.
echo "  Rechargement du pare-feu depuis /etc/nftables.conf, oubli des MTU appris..."
systemctl restart nftables
oublier_mtu

ok "le pare-feu est chargé" systemctl is-active -q nftables
ok "le serveur ne répond toujours pas au ping (PSSI-12)" bash -c '! ip netns exec poste ping -c 2 -W 1 10.20.0.10'
ok "les pages légères passent depuis Lyon" ip netns exec poste curl -fs --max-time 5 -o /dev/null http://10.20.0.10/
ok "le rapport de 2 Mo arrive complet à Lyon en moins de 5 s" telecharge
ok "le serveur a appris le MTU du chemin vers Lyon (1400)" bash -c 'ip route get 10.40.0.10 | grep -q "mtu 1400"'

echo "  L'équipe réseau passe le tunnel en IPsec : MTU 1380..."
tunnel 1380
ok "le rapport arrive encore complet à Lyon" telecharge
tunnel 1400
oublier_mtu

exit $fail
