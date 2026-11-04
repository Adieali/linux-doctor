#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# N requêtes simultanées vers l'API, sans passer par nginx. Réussit si toutes répondent le code attendu.
charge() {
  python3 - "$@" <<'EOF'
import sys, threading, urllib.error, urllib.request
premier, nombre, attendu = (int(a) for a in sys.argv[1:4])
depart = threading.Barrier(nombre)
bons = []
def get(n):
    depart.wait()
    try:
        code = urllib.request.urlopen(f'http://127.0.0.1:8000/api/articles/{n}', timeout=10).status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        code = 0
    bons.append(code == attendu)
fils = [threading.Thread(target=get, args=(premier + i,)) for i in range(nombre)]
for f in fils: f.start()
for f in fils: f.join()
sys.exit(0 if all(bons) else 1)
EOF
}

descripteurs() { local fd=(/proc/"$(systemctl show -p MainPID --value app-api)"/fd/*); echo ${#fd[@]}; }

# Un article inconnu ne doit laisser aucun descripteur derrière lui. Le trafic de fond en ouvre quelques-uns.
sans_fuite() {
  local avant
  avant=$(descripteurs)
  for i in {0..9}; do charge $((990000 + i * 30)) 30 404 || return 1; done
  sleep 2
  (( $(descripteurs) - avant < 30 ))
}

limite_molle() { awk '/^Max open files/ {print $4}' /proc/"$(systemctl show -p MainPID --value app-api)"/limits; }

# Passage d'Ansible : le fichier de l'audit revient tel qu'il a été déployé.
echo "  Passage d'Ansible sur le durcissement, puis redémarrage de l'API..."
install -d /etc/systemd/system/app-api.service.d
cat > /etc/systemd/system/app-api.service.d/10-durcissement.conf <<'EOF'
# Géré par Ansible (rôle durcissement, audit sécurité de septembre).
# Toute modification locale est écrasée au prochain passage.
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
TasksMax=64
EOF
systemctl daemon-reload
systemctl restart app-api
for _ in {1..50}; do curl -fs localhost:8000/api/articles/1 >/dev/null 2>&1 && break; sleep 0.2; done

ok "l'API tourne, avec le durcissement de l'audit" grep -q '^NoNewPrivs:[[:space:]]*1' /proc/"$(systemctl show -p MainPID --value app-api)"/status
ok "elle a droit à 65535 fichiers ouverts, la valeur validée" test "$(limite_molle)" -ge 65535
ok "son nombre de tâches reste plafonné" test "$(systemctl show -p TasksMax --value app-api)" != infinity
ok "200 requêtes simultanées passent toutes, comme à la pointe de midi" charge 30000 200 200
ok "300 articles inconnus ne laissent aucun descripteur ouvert" sans_fuite

exit $fail
