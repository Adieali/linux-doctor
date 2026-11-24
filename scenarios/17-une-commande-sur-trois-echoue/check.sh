#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

commande() { curl -s -o /dev/null --max-time 3 -w '%{http_code}' -X POST -d '{"panier":42}' http://localhost/api/commande; }
sans_erreur() { local i; for ((i = 0; i < $1; i++)); do [[ $(commande) == 201 ]] || return 1; done; }
meme_pid() { [[ $(systemctl show -p MainPID --value "$1") == "$(cat "$2")" ]]; }
# Commandes reçues par un serveur d'application, erreurs comprises (compteur du labo).
recues() { curl -s "http://127.0.0.1:808$1/labo/commandes" | python3 -c 'import json, sys; print(json.load(sys.stdin)["commandes"])'; }
etat() { echo "$2" > "/run/labo/app$1.etat"; }

ok "HAProxy a été rechargé, pas redémarré" meme_pid haproxy /run/labo/haproxy.pid
ok "app2 tourne toujours, pour l'enquête des devs" meme_pid lab-app@2 /run/labo/app2.pid
avant=$(recues 2)
ok "60 commandes de suite, sans une erreur" sans_erreur 60
ok "app2, malade, ne reçoit plus aucune commande" test "$(recues 2)" -eq "$avant"

if (( fail == 0 )); then
  echo "  19 h : app3 perd sa base à son tour. Personne d'astreinte..."
  etat 3 base-ko
  sleep 10
  avant=$(recues 3)
  ok "10 s plus tard, 60 commandes passent sans erreur" sans_erreur 60
  ok "app3, malade, ne reçoit plus aucune commande" test "$(recues 3)" -eq "$avant"
  echo "  L'équipe dev répare la base d'app2..."
  etat 2 ok
  sleep 10
  avant=$(recues 2)
  sans_erreur 30
  ok "10 s plus tard, app2 reçoit de nouveau des commandes" test "$(recues 2)" -gt "$avant"
  etat 3 ok
else
  echo "  [KO] pannes de test non simulées tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
