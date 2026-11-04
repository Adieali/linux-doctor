#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Seuil sous la seconde : timeout:1 seul ramène l'attente à 1 s sans rien réparer, il doit échouer.
vite() { timeout 0.9 "$@" </dev/null; }
dix() { for _ in {1..10}; do vite "$@" || return 1; done; }

# Après un changement de dhcpcd.conf, eth1 est coupée environ 5 secondes : on laisse le bail revenir.
bail() {
  for _ in {1..30}; do
    systemctl is-active -q dhcpcd || return 1
    ip -o -4 addr show eth1 | grep -v forever | grep -q 10.20.0.10/24 && grep -q '^nameserver' /etc/resolv.conf && return 0
    sleep 0.5
  done
  return 1
}

ok "dhcpcd tourne et eth1 garde son adresse DHCP" bail

# Sans dhcpcd, le renouvellement ne prouverait rien : on ne le lance pas.
if (( fail == 0 )); then
  echo "  Renouvellement DHCP, comme celui qui arrive tout seul toutes les quelques minutes..."
  dhcpcd --rebind eth1 >/dev/null 2>&1
  sleep 3
  bail
  # controle.interne.lan n'apparaît dans aucune configuration : un /etc/hosts complété à la main ne le couvre pas.
  ok "un nom interne se résout en moins d'une seconde, dix fois de suite" dix getent ahosts controle.interne.lan
  ok "un nom court aussi, avec la liste de recherche" dix getent ahosts controle
  ok "/api/stock répond en moins d'une seconde" vite curl -fsS localhost/api/stock/1
  ok "/api/paiement répond en moins d'une seconde" vite curl -fsS localhost/api/paiement/1
  ok "sudo répond en moins d'une seconde" vite sudo -n true
  ok "une session SSH s'ouvre en moins d'une seconde" vite ssh -o BatchMode=yes 10.20.0.10 true
else
  echo "  [KO] renouvellement DHCP de test non lancé tant que le point ci-dessus n'est pas réglé"
fi

exit $fail
