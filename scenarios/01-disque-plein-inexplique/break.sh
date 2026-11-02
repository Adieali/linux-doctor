#!/usr/bin/env bash
# Panne : pendant que le disque d'archives n'était pas monté (19 au 21 octobre), le job a écrit sur /srv.
# Le disque, remonté par-dessus le 22, cache ces archives : du ne les voit plus, elles occupent toujours /srv.
# Fausse piste : un petit fichier supprimé encore ouvert, pour ceux qui s'arrêtent à lsof.
set -euo pipefail

arch() { head -c 12M < <(yes "compta $1"); }   # contenu reproductible, le check le recalcule

mkdir -p /srv /var/lib/disks/archives
mount -t tmpfs -o size=48m,mode=755 srv /srv
mkdir -p /srv/app /srv/data/archive
head -c 6M /dev/urandom > /srv/app/app.jar

log=/var/log/archive-compta.log
: > "$log"
for d in $(seq 12 27); do
  day=2026-10-$d
  if (( d >= 19 && d <= 21 )); then dest=/srv/data/archive; else dest=/var/lib/disks/archives; fi
  arch "$day" > "$dest/compta-$day.tar"
  touch -d "$day 02:00:04" "$dest/compta-$day.tar"
  echo "$day 02:00:04 archive écrite : /srv/data/archive/compta-$day.tar (12M)" >> "$log"
done
mount --bind /var/lib/disks/archives /srv/data/archive

cat > /usr/local/bin/archive-compta <<'EOF'
#!/bin/bash
# Archive comptable quotidienne.
set -e
f=/srv/data/archive/compta-$(date +%F).tar
yes "compta $(date +%F)" | head -c 12M > "$f"
echo "$(date '+%F %T') archive écrite : $f ($(du -h "$f" | cut -f1))" >> /var/log/archive-compta.log
EOF
chmod +x /usr/local/bin/archive-compta

cat > /etc/systemd/system/archive-compta.service <<'EOF'
[Unit]
Description=Archive comptable quotidienne

[Service]
Type=oneshot
ExecStart=/usr/local/bin/archive-compta
EOF

cat > /etc/systemd/system/archive-compta.timer <<'EOF'
[Unit]
Description=Archive comptable chaque nuit

[Timer]
OnCalendar=*-*-* 02:00:00

[Install]
WantedBy=timers.target
EOF

cat > /usr/local/bin/app-metrics <<'EOF'
#!/bin/bash
exec 3>>/srv/app/metrics.log
while true; do echo "$(date -Is) ok" >&3; sleep 10; done
EOF
chmod +x /usr/local/bin/app-metrics

cat > /etc/systemd/system/app-metrics.service <<'EOF'
[Unit]
Description=Collecte de métriques

[Service]
ExecStart=/usr/local/bin/app-metrics
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now archive-compta.timer app-metrics 2>/dev/null
sleep 1
head -c 2M /dev/zero >> /srv/app/metrics.log
rm /srv/app/metrics.log
