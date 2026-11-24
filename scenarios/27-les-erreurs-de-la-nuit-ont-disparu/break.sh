#!/usr/bin/env bash
# Panne : les journaux du batch de nuit ont disparu, de deux façons.
# 1. Limitation de débit de journald, durcie pour tout le serveur après le disque plein de septembre
#    (RateLimitBurst=100 sur 30 s). Le batch comptable écrit une ligne par facture rejetée : après une centaine de lignes,
#    journald jette le reste, y compris la ligne finale qui donne le bilan.
# 2. Journal volatil : Storage=volatile, et /var/log/journal supprimé pour libérer de la place. Le redémarrage
#    qui a suivi le batch a tout effacé. Retirer Storage=volatile ne suffit pas : en Storage=auto, journald
#    n'écrit sur le disque que si /var/log/journal existe.
# Pièges pour la réparation : supprimer la limitation pour tout le serveur (contraire au ticket #4651) ; un
# journal persistant sans flush ni redémarrage de journald, qui reste en mémoire jusqu'au prochain démarrage.
# Fausses pistes : le batch lui-même (il fait ce qu'on lui demande), le minuteur, la taille du journal.
set -euo pipefail

useradd --system --home-dir /var/lib/compta --shell /usr/sbin/nologin compta
install -d -o compta -g compta /var/lib/compta /srv/exports
install -d /opt/compta

# Les factures du mois : 4000, dont 1312 sans code TVA (taux pas encore saisis pour les nouveaux produits).
python3 - <<'EOF'
import csv, random
random.seed(27)
with open("/var/lib/compta/factures.csv", "w", newline="") as f:
    w = csv.writer(f, delimiter=";", lineterminator="\n")
    w.writerow(["facture", "client", "montant_ht", "code_tva"])
    sans_tva = set(random.sample(range(4000), 1312))
    for i in range(4000):
        w.writerow([f"F-2026-{80001 + i}", f"C{random.randint(1000, 9999)}",
                    f"{random.uniform(15, 900):.2f}", "" if i in sans_tva else random.choice(["TVA20", "TVA10", "TVA55"])])
EOF
chown compta:compta /var/lib/compta/factures.csv

cat > /opt/compta/export.py <<'EOF'
#!/usr/bin/env python3
# Export comptable de nuit : factures du mois vers le fichier attendu par la banque (équipe Finance-IT).
import csv, datetime, sys

jour = datetime.date.today().isoformat()
print(f"export-compta : début de l'export du {jour}")
lignes, rejets = [], 0
with open("/var/lib/compta/factures.csv", newline="") as f:
    for facture in csv.DictReader(f, delimiter=";"):
        if not facture["code_tva"]:
            rejets += 1
            print(f"facture {facture['facture']} (client {facture['client']}) : code TVA absent, rejetée")
            continue
        lignes.append(facture)
with open(f"/srv/exports/compta-{jour}.csv", "w", newline="") as f:
    csv.writer(f, delimiter=";").writerows([l.values() for l in lignes])
if rejets:
    print(f"ERREUR : export incomplet, {rejets} factures rejetées sur {rejets + len(lignes)} (code TVA absent). "
          "Fichier NON transmis à la banque : à corriger par la comptabilité, puis relancer l'export.")
    sys.exit(1)
print(f"export-compta : {len(lignes)} factures exportées, fichier transmis à la banque")
EOF
cat > /etc/systemd/system/export-compta.service <<'EOF'
[Unit]
Description=Export comptable de nuit vers la banque

[Service]
Type=oneshot
User=compta
ExecStart=/usr/bin/python3 /opt/compta/export.py
EOF
cat > /etc/systemd/system/export-compta.timer <<'EOF'
[Unit]
Description=Export comptable, chaque nuit

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Après le disque plein de septembre (un service en boucle d'erreurs, 40 Go de journal) : limitation de débit
# durcie, journal en mémoire, et l'ancien journal effacé pour libérer /var.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-anti-tempete.conf <<'EOF'
# Ticket #4651 (septembre) : /var plein, 40 Go de journal écrits par un service en boucle d'erreurs.
# Plus de 100 messages en 30 s pour un même service : le reste est jeté.
[Journal]
RateLimitIntervalSec=30s
RateLimitBurst=100
EOF
cat > /etc/systemd/journald.conf.d/60-memoire.conf <<'EOF'
# Ticket #4651 : journal en mémoire, pour ne plus remplir /var.
[Journal]
Storage=volatile
EOF
systemctl restart systemd-journald
rm -rf /var/log/journal

systemctl daemon-reload
systemctl enable export-compta.timer 2>/dev/null

# Le batch de cette nuit : il échoue, et le journal n'en garde que le début.
systemctl start export-compta.service 2>/dev/null && { echo "L'export aurait dû échouer" >&2; exit 1; }
sleep 1
if journalctl -u export-compta --no-pager | grep -q 'export incomplet'; then
  echo "La ligne finale du batch aurait dû être jetée par la limitation de débit" >&2
  exit 1
fi

# Puis le redémarrage pour les correctifs : le journal en mémoire part avec.
exit 3
