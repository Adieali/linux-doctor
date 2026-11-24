#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

paiement() { [[ $(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -X POST http://localhost:8000/payer) == 201 ]]; }
# Ce qu'obtient une application (getaddrinfo : /etc/hosts, puis le DNS avec search et ndots), pas dig.
resout() { [[ $(getent ahostsv4 "$1" | awk 'NR == 1 {print $1}') == "$2" ]]; }
joker() { [[ $(dig +short @10.61.0.53 recette-42.prod.boutique.lan) == 10.62.0.80 ]]; }
prestataire_en() { # ancienne-adresse nouvelle-adresse : le prestataire change d'adresse, et le DNS suit
  sed -i "s/^host-record=api.paiement.example,.*/host-record=api.paiement.example,$2/" /etc/labo/dns.conf
  systemctl restart lab-dns
  ip -n internet addr add "$2/24" dev eth0
  ip -n internet addr del "$1/24" dev eth0
  timeout 10 bash -c "until [[ \$(dig +short @10.61.0.53 api.paiement.example) == $2 ]]; do sleep 0.3; done"
}

ok "le DNS interne a toujours son joker, pour la recette" joker
ok "api.paiement.example résout vers le prestataire (198.51.100.30)" resout api.paiement.example 198.51.100.30
ok "un nom externe à un seul point aussi : transporteur.example (198.51.100.40)" resout transporteur.example 198.51.100.40
ok "les noms courts internes marchent toujours : stock (10.63.0.21)" resout stock 10.63.0.21
ok "un paiement passe de bout en bout" paiement

if (( fail == 0 )); then
  echo "  Le prestataire change d'adresse : 198.51.100.31, publiée dans son DNS..."
  ip netns exec internet sysctl -qw net.ipv4.conf.eth0.promote_secondaries=1
  prestataire_en 198.51.100.30 198.51.100.31
  ok "un paiement passe encore, vers la nouvelle adresse" paiement
  prestataire_en 198.51.100.31 198.51.100.30
else
  echo "  [KO] changement d'adresse du prestataire non simulé tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
