#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

r() { redis-cli "$@"; }
info() { r info "$1" | tr -d '\r' | sed -n "s/^$2://p"; }
reglage() { r config get "$1" | sed -n 2p; }
tues() { sed -n 's/^oom_kill //p' /sys/fs/cgroup/system.slice/redis-server.service/memory.events; }
pointe() { # nombre d'écritures
  redis-benchmark -q -n "$1" -r 500000 -c 8 SET 'panier:__rand_int__' "$(printf 'x%.0s' {1..400})" EX 604800 >/dev/null 2>&1
}

limite_systeme() {
  [[ $(systemctl show -p MemoryMax --value redis-server) == 419430400 && $(systemctl show -p MemorySwapMax --value redis-server) == 0 ]]
}
persistance_active() {
  [[ -n $(reglage save) || $(reglage appendonly) == yes ]] && [[ $(reglage stop-writes-on-bgsave-error) == yes ]]
}
# Les données, plus une copie complète pendant la sauvegarde, plus une marge : moins de 400 Mo.
dimensionne() { local m; m=$(reglage maxmemory); (( m > 0 && 2 * m + 64 * 1024 * 1024 <= 400 * 1024 * 1024 )); }

# Une sauvegarde en pleine pointe d'écriture : elle doit aboutir, sans qu'aucun processus soit tué.
sauvegarde_sous_pointe() {
  local avant
  avant=$(tues)
  pointe 300000 &
  sleep 1
  r bgsave || { wait; return 1; }
  for _ in {1..120}; do [[ $(info persistence rdb_bgsave_in_progress) == 0 ]] && break; sleep 0.5; done
  wait
  [[ $(info persistence rdb_last_bgsave_status) == ok && $(tues) == "$avant" ]]
}

# Des paniers modifiés à l'instant, puis une pointe qui oblige à faire de la place : ce ne sont pas eux qui
# partent. La pointe reste petite devant le cache : au-delà, tout le cache serait renouvelé, et « à l'instant »
# ne voudrait plus rien dire.
frais_gardes() {
  local i
  for i in $(seq 1 2000); do echo "SET panier:frais:$i x EX 604800"; done | r >/dev/null
  pointe 30000
  [[ $(r eval "local n=0 for i=1,2000 do n = n + redis.call('EXISTS', 'panier:frais:' .. i) end return n" 0) == 2000 ]]
}

survit_au_redemarrage() {
  local temoin=$RANDOM
  r set temoin-du-check "$temoin" && r bgsave || return 1
  for _ in {1..120}; do [[ $(info persistence rdb_bgsave_in_progress) == 0 ]] && break; sleep 0.5; done
  systemctl restart redis-server
  for _ in {1..120}; do [[ $(r ping 2>/dev/null) == PONG ]] && break; sleep 0.5; done
  [[ $(r get temoin-du-check) == "$temoin" ]] && dimensionne
}

ok "Redis garde sa limite de 400 Mo, sans swap" limite_systeme
ok "la persistance reste active, et protège toujours les écritures" persistance_active
ok "Redis accepte les écritures" test "$(r set controle 1)" = OK
ok "maxmemory laisse la place d'une copie complète pendant la sauvegarde" dimensionne

if (( fail == 0 )); then
  echo "  Sauvegarde en pleine pointe d'écriture..."
  ok "la sauvegarde aboutit, sans processus tué" sauvegarde_sous_pointe
  echo "  Paniers modifiés à l'instant, puis nouvelle pointe..."
  ok "les paniers qu'on vient de modifier sont toujours là" frais_gardes
  echo "  Redémarrage de Redis..."
  ok "les données et la configuration survivent au redémarrage" survit_au_redemarrage
else
  echo "  [KO] pointe de test non lancée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
