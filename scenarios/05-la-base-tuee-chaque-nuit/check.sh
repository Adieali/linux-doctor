#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

prop() { systemctl show -p "$2" --value "$1"; }
pg() { runuser -u postgres -- psql -X -At -d boutique "$@"; }
requete='SELECT id, client, adresse, montant, cree_le FROM commandes ORDER BY id'
fichier=/srv/exports/commandes-$(date +%F).csv

budget_dba() {
  [[ $(prop postgresql@17-main ActiveState) == active && $(prop postgresql@17-main Slice) == base.slice ]] &&
  [[ $(prop base.slice MemoryMax) == 419430400 && $(prop base.slice MemorySwapMax) == 0 ]]
}

# Un plafond sur l'unité, ou sur la tranche qui la contient.
plafond_propre() {
  local tranche
  tranche=$(prop export-nuit.service Slice)
  [[ $tranche != base.slice ]] &&
  { [[ $(prop export-nuit.service MemoryMax) != infinity ]] || [[ $(prop "$tranche" MemoryMax) != infinity ]]; }
}

# Une connexion témoin reste ouverte pendant l'export : un crash de la base, ou son arrêt, la coupe.
temoin='SELECT pg_sleep(600) -- témoin du check'
nuit() {
  pg -c "$temoin" >/dev/null 2>&1 &
  sleep 1
  systemctl start export-nuit || return 1
  [[ $(pg -c "SELECT count(*) FROM pg_stat_activity WHERE query = '$temoin'") == 1 ]]
}

fichier_erp() {
  [[ -f $fichier ]] &&
  [[ $(md5sum < "$fichier") == "$(pg -F ';' -v FETCH_COUNT=10000 -c "$requete" | md5sum)" ]]
}

# Le même export avec 64 Mo, sans swap : un psql qui charge tout le résultat n'y tient pas.
nuit_bridee() {
  local d=/run/systemd/system/export-nuit.service.d rc
  install -d "$d"
  printf '[Service]\nMemoryMax=64M\nMemorySwapMax=0\n' > "$d/zz-check.conf"
  systemctl daemon-reload
  systemctl start export-nuit
  rc=$?
  rm -f "$d/zz-check.conf"
  systemctl daemon-reload
  return "$rc"
}

ok "la base tourne dans base.slice, avec le budget du DBA (400 Mo, sans swap)" budget_dba
ok "l'export n'est plus dans base.slice, et il a son propre plafond mémoire" plafond_propre
ok "l'export n'est plus protégé de l'OOM killer" test "$(prop export-nuit.service OOMScoreAdjust)" -ge 0
ok "l'export tourne toujours chaque nuit (timer actif)" systemctl is-active -q export-nuit.timer

# Rejouer la nuit sur une base arrêtée ne prouverait rien.
if (( fail == 0 )); then
  echo "  Nuit rejouée : export pendant qu'une connexion reste ouverte sur la base..."
  rm -f "$fichier"
  ok "l'export se termine, et la connexion ouverte n'est pas coupée" nuit
  ok "le fichier est complet, au format attendu par l'ERP" fichier_erp
  echo "  Même export avec 64 Mo de mémoire..."
  ok "il se termine encore : sa mémoire ne dépend plus de la taille de la table" nuit_bridee
else
  echo "  [KO] nuit de test non rejouée tant que les points ci-dessus ne sont pas réglés"
fi
pg -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query = '$temoin'" >/dev/null 2>&1

exit $fail
