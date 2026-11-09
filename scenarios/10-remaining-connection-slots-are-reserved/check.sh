#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }

# Valeur effective d'un réglage pour une connexion de factures, lue dans le catalogue : se connecter en tant
# que factures échouerait justement quand le rôle est à son plafond. Même priorité que PostgreSQL :
# rôle dans la base, rôle, base, puis réglage global.
reglage_factures() {
  local v
  v=$(pg -c "SELECT coalesce(
      (SELECT substr(c, length('$1') + 2) FROM pg_db_role_setting s CROSS JOIN unnest(s.setconfig) c
        WHERE s.setrole = 'factures'::regrole AND c LIKE '$1=%'
          AND s.setdatabase IN (0, (SELECT oid FROM pg_database WHERE datname = 'boutique'))
        ORDER BY s.setdatabase DESC LIMIT 1),
      (SELECT substr(c, length('$1') + 2) FROM pg_db_role_setting s CROSS JOIN unnest(s.setconfig) c
        WHERE s.setrole = 0 AND c LIKE '$1=%'
          AND s.setdatabase = (SELECT oid FROM pg_database WHERE datname = 'boutique')),
      current_setting('$1'))")
  pg -c "SET $1 = '$v'" -c "SELECT setting FROM pg_settings WHERE name = '$1'"
}

# 20 connexions simultanées de l'application, gardées une demi-seconde.
capacite() {
  runuser -u boutique -- python3 - <<'EOF'
import sys, threading, time
import psycopg2
erreurs = []
def client():
    try:
        c = psycopg2.connect(dbname='boutique')
        time.sleep(0.5)
        c.close()
    except psycopg2.Error as e:
        erreurs.append(e)
t = [threading.Thread(target=client) for _ in range(20)]
for x in t: x.start()
for x in t: x.join()
sys.exit(1 if erreurs else 0)
EOF
}

limite_factures() { local n; n=$(pg -c "SELECT rolconnlimit FROM pg_roles WHERE rolname = 'factures'"); (( n >= 1 && n <= 15 )); }
delai_factures() { local ms; ms=$(reglage_factures idle_session_timeout); (( ms > 0 && ms <= 120000 )); }
exportees() { pg -c "SELECT count(*) FROM factures_exportees"; }

# Une rafale de 100 factures : le worker ouvre une connexion par facture, aussi vite qu'il peut.
rafale() {
  pg -c "INSERT INTO factures_a_exporter (commande) SELECT 0 FROM generate_series(1, 100)"
  for _ in {1..10}; do capacite || return 1; sleep 0.5; done
}

export_avance() {
  local avant=$1
  for _ in {1..180}; do (( $(exportees) >= avant + 5 )) && return 0; sleep 0.5; done
  return 1
}

ok "max_connections n'a pas bougé (40)" test "$(pg -c 'SHOW max_connections')" -eq 40
ok "l'application ouvre 20 connexions simultanées" capacite
ok "le rôle factures est plafonné (15 connexions au plus)" limite_factures
ok "une connexion inactive du rôle factures est coupée en 2 minutes au plus" delai_factures
ok "l'export des factures tourne" systemctl is-active -q export-factures

if (( fail == 0 )); then
  echo "  Rafale de 100 factures à exporter, pendant que l'application se connecte..."
  avant=$(exportees)
  ok "l'application garde ses connexions pendant la rafale" rafale
  ok "l'export des factures avance toujours" export_avance "$avant"
else
  echo "  [KO] rafale de test non lancée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
