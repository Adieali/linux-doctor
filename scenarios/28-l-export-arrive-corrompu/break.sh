#!/usr/bin/env bash
# Panne : l'export du catalogue tourne deux fois en même temps chaque nuit, et les deux écrivent le même fichier.
# Le mois dernier, le job a migré de cron vers un minuteur systemd (ticket #4790), mais la ligne de
# /etc/cron.d est restée : à 2 h, cron et le minuteur le lancent ensemble. Le script a pourtant un verrou
# (flock sur /tmp/export-catalogue.lock), mais l'unité systemd a PrivateTmp=yes : son /tmp n'est pas celui de
# cron, chacun verrouille son propre fichier. Les deux exports tronquent puis complètent le même fichier :
# lignes en double, lignes coupées. Et le partenaire récupère le fichier pendant qu'il s'écrit.
# Pièges pour la réparation : supprimer la ligne cron laisse les relances à la main de l'astreinte se superposer
# au minuteur ; un verrou dans /run/lock échoue sous ProtectSystem=strict (système de fichiers en lecture seule)
# s'il n'est pas ouvert à l'unité ; retirer PrivateTmp ou ProtectSystem casse le durcissement demandé ; sans
# écriture atomique, le partenaire lit encore un fichier à moitié écrit.
# Fausses pistes : le partenaire, l'encodage, la base.
set -euo pipefail

useradd --system --home-dir /var/lib/export --shell /usr/sbin/nologin export
install -d -o export -g export /srv/echanges
install -d /opt/catalogue

cat > /opt/catalogue/extraire.py <<'EOF'
#!/usr/bin/env python3
# Extraction du catalogue (60 000 références) depuis la base, ligne à ligne. Labo : la base est simulée.
import random, sys, time

random.seed(28)
categories = ["jardin", "cuisine", "bricolage", "salle-de-bain", "luminaire", "rangement"]
for i in range(60000):
    print(f"REF-{100000 + i};Produit {i};{random.uniform(2, 400):.2f};{random.randint(0, 500)};{random.choice(categories)}")
    if i % 2000 == 0:
        time.sleep(0.15)   # les requêtes vers la base
EOF

cat > /usr/local/bin/export-catalogue <<'EOF'
#!/bin/bash
# Export du catalogue vers la place de marché. Le partenaire récupère /srv/echanges/catalogue.csv à 2 h 30.
# Un seul export à la fois : il charge la base.
set -e
exec 9> /tmp/export-catalogue.lock
if ! flock -n 9; then
    echo "export déjà en cours, abandon"
    exit 0
fi
sortie=/srv/echanges/catalogue.csv
echo "$(date '+%F %T') début de l'export"
echo "reference;libelle;prix;stock;categorie" > "$sortie"
python3 /opt/catalogue/extraire.py >> "$sortie"
echo "$(date '+%F %T') fin de l'export : $(wc -l < "$sortie") lignes"
EOF
chmod 755 /usr/local/bin/export-catalogue

cat > /etc/systemd/system/export-catalogue.service <<'EOF'
[Unit]
Description=Export du catalogue vers la place de marché

[Service]
Type=oneshot
User=export
ExecStart=/usr/local/bin/export-catalogue
# Durcissement demandé par la sécurité lors de la migration (ticket #4790).
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/srv/echanges
EOF
cat > /etc/systemd/system/export-catalogue.timer <<'EOF'
[Unit]
Description=Export du catalogue, chaque nuit
# Migration depuis cron (ticket #4790).

[Timer]
OnCalendar=*-*-* 02:00:00

[Install]
WantedBy=timers.target
EOF
cat > /etc/cron.d/export-catalogue <<'EOF'
# Export du catalogue vers la place de marché
0 2 * * * export /usr/local/bin/export-catalogue >> /var/log/export-catalogue.log 2>&1
EOF
touch -d '5 weeks ago' /etc/cron.d/export-catalogue
install -o export -g export -m 640 /dev/null /var/log/export-catalogue.log
systemctl daemon-reload
systemctl enable --now export-catalogue.timer 2>/dev/null

# La nuit dernière, à 2 h : le minuteur et cron, ensemble.
systemctl start --no-block export-catalogue.service
runuser -u export -- /usr/local/bin/export-catalogue >> /var/log/export-catalogue.log 2>&1
for _ in {1..100}; do
  [[ $(systemctl show -p ActiveState --value export-catalogue.service) == activating ]] || break
  sleep 0.3
done
lignes=$(wc -l < /srv/echanges/catalogue.csv)
if (( lignes == 60001 )); then
  echo "L'export aurait dû être corrompu ($lignes lignes)" >&2
  exit 1
fi
