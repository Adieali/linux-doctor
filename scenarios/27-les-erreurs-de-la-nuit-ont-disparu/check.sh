#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Le check redémarre le serveur : l'identifiant de l'export lancé avant est noté sur le disque, et dans /run
# (effacé au démarrage) le fait que le redémarrage n'a pas encore eu lieu.
etape=/var/lib/labo-check/27-export
avant=/run/labo-check-27

# Lignes écrites par une exécution précise de l'export (pas les messages de systemd sur l'unité).
lignes_export() { journalctl --no-pager -q -o cat "_SYSTEMD_INVOCATION_ID=$1"; }
export_complet() { [[ $(lignes_export "$1" | grep -c 'code TVA absent, rejetée') == 1312 ]] && lignes_export "$1" | grep -q '^ERREUR : export incomplet'; }

if [[ -f $etape && ! -f $avant ]]; then
  id=$(cat "$etape")
  rm -f "$etape"
  echo "  Après le redémarrage :"
  ok "l'export lancé avant le redémarrage est toujours dans le journal, en entier" export_complet "$id"
  exit $fail
fi
rm -f "$etape"

# Un service qui s'emballe : 5000 lignes d'un coup. La protection du ticket #4651 doit en jeter.
cat > /run/systemd/system/labo-check-tempete.service <<'EOF'
[Service]
Type=oneshot
# Une unité oneshot terminée perd son InvocationID ; celle-ci reste active le temps de le lire.
RemainAfterExit=yes
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 5000 ]; do i=$((i+1)); echo "tempête $i"; done'
EOF
systemctl daemon-reload
systemctl start labo-check-tempete.service
journalctl --sync
tempete=$(systemctl show -p InvocationID --value labo-check-tempete.service)
gardees=$(journalctl --no-pager -q -o cat "_SYSTEMD_INVOCATION_ID=$tempete" | grep -c '^tempête')
systemctl stop labo-check-tempete.service
rm -f /run/systemd/system/labo-check-tempete.service
systemctl daemon-reload
limite() { (( gardees > 0 && gardees < 5000 )); }
ok "un service qui s'emballe est toujours limité ($gardees lignes gardées sur 5000)" limite

# L'export, relancé : toutes ses lignes doivent être là, bilan compris.
systemctl start export-compta.service >/dev/null 2>&1
journalctl --sync
id=$(systemctl show -p InvocationID --value export-compta.service)
ok "l'export garde toutes ses lignes : 1312 rejets et le bilan" export_complet "$id"
(( fail )) && exit 1

mkdir -p "${etape%/*}"
echo "$id" > "$etape"
touch "$avant"
exit 3
