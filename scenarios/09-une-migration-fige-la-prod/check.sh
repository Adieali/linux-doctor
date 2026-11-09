#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }
# Une requête de l'application, avec sa durée en millisecondes.
requete() {
  local debut=$EPOCHREALTIME
  runuser -u boutique -- psql -X -q -At -d boutique -c "SELECT count(*) FROM commandes WHERE client = 'client-1'" >/dev/null 2>&1 || return 1
  echo $(( (${EPOCHREALTIME/./} - ${debut/./}) / 1000 ))
}
rapide() { local ms; ms=$(timeout 5 bash -c "$(declare -f requete); requete") && (( ms < 1000 )); }
idle_rapports() { pg -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'rapports' AND state = 'idle in transaction'"; }

# Effectif pour une connexion du rôle rapports : réglage du rôle, de la base ou global.
delai_rapports() {
  local ms
  ms=$(runuser -u rapports -- psql -X -At -d boutique -c "SELECT setting FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout'")
  (( ms > 0 && ms <= 900000 ))
}

# Un déploiement pendant un rapport bloqué : l'application ne doit jamais attendre plus de 3 secondes.
deploiement_sous_rapport() {
  local pire=0 ms
  cat > /srv/migrations/9999_check.sql <<'EOF'
ALTER TABLE commandes ADD COLUMN controle_check int;
EOF
  chown deploiement /srv/migrations/9999_check.sql
  systemctl restart --no-block rapport-stock
  for _ in {1..40}; do (( $(idle_rapports) >= 1 )) && break; sleep 0.25; done
  systemctl start --no-block migration
  for _ in {1..20}; do
    ms=$(timeout 5 bash -c "$(declare -f requete); requete") || ms=5000
    (( ms > pire )) && pire=$ms
    (( pire >= 3000 )) && break
    sleep 0.3
  done
  systemctl stop rapport-stock
  for _ in {1..40}; do systemctl is-active -q migration || break; sleep 0.25; done
  pg -c "ALTER TABLE commandes DROP COLUMN IF EXISTS controle_check" -c "DELETE FROM schema_migrations WHERE version = '9999'"
  rm -f /srv/migrations/9999_check.sql
  (( pire < 3000 ))
}

ok "l'application répond en moins d'une seconde" rapide
ok "la migration 0042 de la version 2.14 est passée" test "$(pg -c "SELECT count(*) FROM schema_migrations WHERE version = '0042'")$(pg -c "SELECT count(*) FROM information_schema.columns WHERE table_name = 'commandes' AND column_name = 'suivi_colis'")" = 11
ok "plus aucune session de rapport ne reste en transaction" test "$(idle_rapports)" -eq 0
ok "aucun rapport n'est resté bloqué en cours d'exécution" test "$(systemctl show -p ActiveState --value rapport-stock)" != activating
ok "le rapport de stock part toujours chaque heure" systemctl is-active -q rapport-stock.timer
ok "une session de rapport inactive en transaction est coupée en 15 minutes au plus" delai_rapports

if (( fail == 0 )); then
  echo "  Nouveau déploiement pendant que le rapport de l'heure attend l'ERP..."
  ok "l'application n'attend jamais plus de 3 secondes" deploiement_sous_rapport
else
  echo "  [KO] déploiement de test non lancé tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
