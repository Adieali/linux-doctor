#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pid=$(systemctl show -p MainPID --value app-api)

en_ajout() {
  [[ $(readlink "/proc/$pid/fd/1") == /var/log/app/app.log ]] &&
    (( 8#$(awk '/^flags/ {print $2}' "/proc/$pid/fdinfo/1") & 02000 ))
}

journaux_conserves() {
  local r
  while IFS= read -r r; do
    zgrep -aqF "$r" /var/log/app/app.log* || return 1
  done < <(echo "GET /api/orders/0 "; cat /opt/.doctor-02)
}

sans_trou() {
  local s
  s=$(stat -c %s /var/log/app/app.log)
  (( s > 0 && s < 1048576 ))
}

ok "app-api tourne" systemctl is-active -q app-api
ok "app-api écrit dans /var/log/app/app.log en mode ajout (O_APPEND)" en_ajout
ok "les journaux sont conservés, de la première à la dernière heure de pointe" journaux_conserves

# Tant que ce qui précède n'est pas bon, la rotation de test saturerait la partition : on ne la lance pas.
if (( fail == 0 )); then
  echo "  Rotation de test, comme cette nuit..."
  logrotate -f /etc/logrotate.d/app >/dev/null 2>&1
  sleep 3
  ok "après la rotation, app.log reprend sans trou" sans_trou
  ok "après la rotation, /var/log/app est utilisé à moins de 70 %" test "$(df --output=pcent /var/log/app | tail -1 | tr -dc 0-9)" -lt 70
else
  echo "  [KO] rotation de test non lancée tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
