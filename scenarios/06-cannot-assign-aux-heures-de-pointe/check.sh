#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Le port 45000 ne peut pas être pris par une connexion sortante : hors de la plage, ou réservé.
port_protege() {
  local bas haut reserves p debut fin
  read -r bas haut < /proc/sys/net/ipv4/ip_local_port_range
  (( 45000 < bas || 45000 > haut )) && return 0
  reserves=$(< /proc/sys/net/ipv4/ip_local_reserved_ports)
  IFS=, read -ra plages <<< "$reserves"
  for p in "${plages[@]}"; do
    debut=${p%-*} fin=${p#*-}
    (( 45000 >= debut && 45000 <= fin )) && return 0
  done
  return 1
}

# Connexions TCP ouvertes par ce serveur (connect), depuis son démarrage.
ouvertures() { awk '/^Tcp:/ { if (n++) print $6 }' /proc/net/snmp; }

# La pointe : 40 visiteurs, 100 pages chacun, depuis le réseau des clients.
pointe() {
  ip netns exec infra python3 - <<'EOF'
import http.client, sys, threading
erreurs = []
def visiteur(v):
    c = http.client.HTTPConnection('10.20.0.10', 80, timeout=10)
    for i in range(100):
        try:
            c.request('GET', f'/catalogue/{v * 100 + i}')
            r = c.getresponse(); r.read()
            if r.status != 200: erreurs.append(r.status)
        except Exception as e:
            erreurs.append(e); c.close()
            c = http.client.HTTPConnection('10.20.0.10', 80, timeout=10)
t = [threading.Thread(target=visiteur, args=(v,)) for v in range(40)]
for x in t: x.start()
for x in t: x.join()
sys.exit(1 if erreurs else 0)
EOF
}

ok "le service de rapports tourne sur le port 45000" systemctl is-active -q app-rapports
ok "aucune connexion sortante ne peut prendre le port 45000" port_protege
ok "la configuration de nginx est valide" nginx -t

if (( fail == 0 )); then
  echo "  Pointe : 4000 pages en quelques secondes..."
  avant=$(ouvertures)
  ok "toutes les pages répondent 200" pointe
  apres=$(ouvertures)
  # Une connexion neuve par requête en ouvrirait plus de 4000, le trafic de fond quelques-unes. Un connect()
  # refusé faute de port n'est pas compté : si des pages ont échoué, la mesure ne prouve rien.
  reutilise() { (( fail == 0 && apres - avant < 400 )); }
  ok "nginx réutilise ses connexions vers le catalogue" reutilise
else
  echo "  [KO] pointe de test non lancée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
