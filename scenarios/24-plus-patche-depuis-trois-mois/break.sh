#!/usr/bin/env bash
# Panne : le serveur ne se met plus à jour, et personne ne le voit. Trois couches.
# 1. dpkg : agent-supervision 2.1 est à moitié configuré depuis la journée de correctifs d'août. Son postinst
#    vérifie la configuration, et la 2.1 a renommé l'option « intervalle » en « periode » ; le fichier modifié
#    localement a été gardé (confold), avec l'ancienne option. Chaque apt-get et chaque passage
#    d'unattended-upgrades bute dessus.
# 2. apt-mark hold sur libboutique-crypto, posé en mars (la 1.4.0 cassait les webhooks de paiement) et jamais
#    levé : la 1.4.3, qui corrige la CVE et la régression de mars, ne s'installe pas.
# 3. unattended-upgrades n'accepte que les origines Debian : le miroir interne s'annonce « Boutique ». Même
#    avec dpkg réparé, il ne trouve rien à installer, et ne prévient personne (pas de Mail).
# Pièges pour la réparation : éditer /var/lib/dpkg/status ou le postinst ; reprendre la configuration du paquet
# (perd l'adresse locale du serveur de supervision) ; apt-get upgrade, qui met aussi à jour l'application
# (réservée aux mises en production) ; ouvrir unattended-upgrades à toute l'origine Boutique (idem).
set -euo pipefail

# Le miroir interne (depot.interne, 10.90.0.5) : Debian et les paquets de la boutique, sans Internet.
ip netns add depot
ip link add eth1 type veth peer name eth0 netns depot
ip addr add 10.90.0.10/24 dev eth1
ip link set eth1 up
ip -n depot link set lo up
ip -n depot addr add 10.90.0.5/24 dev eth0
ip -n depot link set eth0 up
echo '10.90.0.5 depot.interne' >> /etc/hosts
install -d /srv/depot/debian/pool/trixie /srv/depot/debian/pool/trixie-securite /srv/depot/notes /usr/local/lib/labo

# Outils du labo : fabriquer un paquet, publier le dépôt.
cat > /usr/local/lib/labo/paquet <<'EOF'
#!/bin/bash
# Labo : fabrique un paquet .deb. paquet <nom> <version> <suite> <description> <dossier source>
set -e
nom=$1 version=$2 suite=$3 description=$4 src=$5
install -d "$src/DEBIAN"
cat > "$src/DEBIAN/control" <<CTRL
Package: $nom
Version: $version
Architecture: all
Maintainer: Équipe plateforme <plateforme@boutique.interne>
Section: misc
Priority: optional
Description: $description
CTRL
dpkg-deb --build --root-owner-group "$src" "/srv/depot/debian/pool/$suite/${nom}_${version}_all.deb" >/dev/null
EOF
cat > /usr/local/lib/labo/publier <<'EOF'
#!/bin/bash
# Labo : régénère les index du miroir interne, pour les deux suites.
set -e
arch=$(dpkg --print-architecture)
cd /srv/depot/debian
for suite in trixie trixie-securite; do
  label=Boutique; [[ $suite == trixie-securite ]] && label=Boutique-Securite
  install -d "dists/$suite/main/binary-$arch"
  apt-ftparchive packages "pool/$suite" > "dists/$suite/main/binary-$arch/Packages" 2>/dev/null
  gzip -kf "dists/$suite/main/binary-$arch/Packages"
  apt-ftparchive -o APT::FTPArchive::Release::Origin=Boutique -o "APT::FTPArchive::Release::Label=$label" \
    -o "APT::FTPArchive::Release::Suite=$suite" -o "APT::FTPArchive::Release::Codename=$suite" \
    -o "APT::FTPArchive::Release::Architectures=$arch" -o APT::FTPArchive::Release::Components=main \
    release "dists/$suite" > "dists/$suite/Release"
done
EOF
chmod 755 /usr/local/lib/labo/paquet /usr/local/lib/labo/publier

src=$(mktemp -d)
# libboutique-crypto : signatures des webhooks de paiement.
for v in 1.3.9 1.4.0 1.4.3; do
  rm -rf "$src"; install -d "$src/usr/lib/boutique"
  echo "$v" > "$src/usr/lib/boutique/libboutique-crypto.version"
  suite=trixie; [[ $v == 1.4.3 ]] && suite=trixie-securite
  /usr/local/lib/labo/paquet libboutique-crypto "$v" "$suite" "Bibliothèque de signatures de la boutique (webhooks de paiement)" "$src"
done
cat > /srv/depot/notes/libboutique-crypto.txt <<'EOF'
libboutique-crypto : notes de version

1.4.3 (19 août 2026), SÉCURITÉ
  CVE-2026-31337 : comparaison des signatures HMAC en temps non constant (signature des webhooks devinable).
  Corrige aussi la régression de la 1.4.0 (incident #4411) : signatures invalides avec une clé de plus de
  64 octets. Mise à jour recommandée sur tous les serveurs, y compris ceux restés en 1.3.x.

1.4.0 (3 mars 2026)
  Nouveau format de clé. Régression connue : signatures invalides avec une clé de plus de 64 octets.
EOF

# boutique-api : l'application. Ses versions passent par les mises en production, jamais par apt upgrade.
for v in 3.8.0 3.9.0; do
  rm -rf "$src"; install -d "$src/opt/boutique-api"
  echo "$v" > "$src/opt/boutique-api/VERSION"
  /usr/local/lib/labo/paquet boutique-api "$v" trixie "API de la boutique (livrée par les mises en production)" "$src"
done

# agent-supervision : la 2.1 renomme une option de sa configuration.
agent() { # version options-connues defaut
  rm -rf "$src"; install -d "$src/usr/bin" "$src/etc" "$src/usr/lib/systemd/system" "$src/usr/share/doc/agent-supervision" "$src/DEBIAN"
  cat > "$src/usr/bin/agent-supervision" <<EOF
#!/bin/sh
# Agent de supervision $1 : envoie l'état du serveur au serveur de supervision.
CONF=/etc/agent-supervision.conf
verifier() {
  awk -F' *= *' 'BEGIN { split("$2", k, " "); for (i in k) ok[k[i]] = 1 }
    /^[[:space:]]*(#|\$)/ { next }
    !(\$1 in ok) { print "agent-supervision : option inconnue dans /etc/agent-supervision.conf : " \$1 "$4"; e = 1 }
    END { exit e }' "\$CONF"
}
if [ "\$1" = --verifier ]; then verifier; exit; fi
verifier || exit 1
while true; do sleep 30; done
EOF
  chmod 755 "$src/usr/bin/agent-supervision"
  printf '# Agent de supervision\nserveur = supervision.exemple\n%s\n' "$3" > "$src/etc/agent-supervision.conf"
  echo /etc/agent-supervision.conf > "$src/DEBIAN/conffiles"
  printf '[Unit]\nDescription=Agent de supervision\n\n[Service]\nExecStart=/usr/bin/agent-supervision\n\n[Install]\nWantedBy=multi-user.target\n' \
    > "$src/usr/lib/systemd/system/agent-supervision.service"
  printf 'agent-supervision 2.1\n  L'\''option « intervalle » est renommée « periode ». Si /etc/agent-supervision.conf a été modifié\n  localement, le mettre à jour : la 2.1 refuse de démarrer avec une option inconnue.\n' \
    > "$src/usr/share/doc/agent-supervision/NEWS"
  cat > "$src/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    agent-supervision --verifier
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload
        systemctl enable agent-supervision.service >/dev/null 2>&1
        systemctl restart agent-supervision.service
    fi
fi
EOF
  chmod 755 "$src/DEBIAN/postinst"
  /usr/local/lib/labo/paquet agent-supervision "$1" trixie "Agent de supervision des serveurs" "$src"
}
agent 2.0 "serveur intervalle" "intervalle = 60" ""
agent 2.1 "serveur periode" "periode = 60" " (renommée periode en 2.1, voir /usr/share/doc/agent-supervision/NEWS)"
rm -rf "$src"
/usr/local/lib/labo/publier

cat > /etc/systemd/system/lab-depot.service <<'EOF'
[Unit]
Description=Labo : le miroir interne, depot.interne (ne pas toucher)

[Service]
ExecStart=/usr/sbin/ip netns exec depot /usr/bin/python3 -m http.server 80 --directory /srv/depot
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-depot 2>/dev/null
timeout 10 bash -c 'until curl -fs -o /dev/null http://depot.interne/debian/dists/trixie/Release; do sleep 0.3; done'

# Sans Internet : seulement le miroir interne.
rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list
cat > /etc/apt/sources.list.d/depot-interne.sources <<'EOF'
# Miroir interne (depot.interne) : Debian, et les paquets de la boutique.
# Labo : le dépôt n'est pas signé.
Types: deb
URIs: http://depot.interne/debian
Suites: trixie trixie-securite
Components: main
Trusted: yes
EOF
apt-get update -qq
apt-get install -y -qq libboutique-crypto=1.3.9 boutique-api=3.8.0 agent-supervision=2.0 >/dev/null

# Mars, incident #4411 : la 1.4.0 cassait les webhooks, la bibliothèque est bloquée en 1.3.9.
apt-mark hold libboutique-crypto >/dev/null
cat > /etc/motd <<'EOF'

srv-prod-01 : boutique, production.
libboutique-crypto bloquée en 1.3.9 (incident #4411, mars 2026 : la 1.4.0 cassait les webhooks de paiement).

EOF

# L'adresse du serveur de supervision, et un envoi plus fréquent, réglés à la main.
cat > /etc/agent-supervision.conf <<'EOF'
# Agent de supervision
serveur = 10.90.0.20
intervalle = 30
EOF

# Août, journée de correctifs : la mise à jour de l'agent s'arrête au postinst.
apt-get install -y -qq -o Dpkg::Options::=--force-confold agent-supervision=2.1 >/dev/null 2>&1 || true
dpkg -s agent-supervision | grep -q '^Status: install ok half-configured'

# Les mises à jour automatiques tournent chaque jour depuis l'installation du serveur, sans rien trouver.
# Les journaux d'apt et de dpkg racontent l'installation d'avril et la journée de correctifs du 20 août.
systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
install -d /var/log/unattended-upgrades
python3 - <<'EOF'
import datetime

maintenant = datetime.datetime.now()
origines = ("origin=Debian,codename=trixie,label=Debian, origin=Debian,codename=trixie,label=Debian-Security, "
            "origin=Debian,codename=trixie-security,label=Debian-Security")
lignes = []
for n in range(120, 0, -1):
    t = (maintenant - datetime.timedelta(days=n)).replace(hour=6, minute=24, second=11, microsecond=0)
    h = lambda s: (t + datetime.timedelta(seconds=s)).strftime("%Y-%m-%d %H:%M:%S,%f")[:23]
    lignes += [f"{h(0)} INFO Starting unattended upgrades script",
               f"{h(0)} INFO Allowed origins are: {origines}",
               f"{h(0)} INFO Initial blacklist: ",
               f"{h(0)} INFO Initial whitelist (not strict): ",
               f"{h(3)} INFO No packages found that can be upgraded unattended and no pending auto-removals"]
open("/var/log/unattended-upgrades/unattended-upgrades.log", "w").write("\n".join(lignes) + "\n")

open("/var/log/apt/history.log", "w").write("""
Start-Date: 2026-04-02  10:12:44
Commandline: apt-get install -y libboutique-crypto=1.3.9 boutique-api=3.8.0 agent-supervision=2.0
Install: libboutique-crypto:all (1.3.9), boutique-api:all (3.8.0), agent-supervision:all (2.0)
End-Date: 2026-04-02  10:12:46

Start-Date: 2026-08-20  14:03:10
Commandline: apt-get -y -o Dpkg::Options::=--force-confold upgrade
Upgrade: agent-supervision:all (2.0, 2.1)
Error: Sub-process /usr/bin/dpkg returned an error code (1)
End-Date: 2026-08-20  14:03:12
""")
open("/var/log/apt/term.log", "w").write("""
Log started: 2026-08-20  14:03:10
(Reading database ... 23211 files and directories currently installed.)
Preparing to unpack .../agent-supervision_2.1_all.deb ...
Unpacking agent-supervision (2.1) over (2.0) ...
Setting up agent-supervision (2.1) ...
agent-supervision : option inconnue dans /etc/agent-supervision.conf : intervalle (renommée periode en 2.1, voir /usr/share/doc/agent-supervision/NEWS)
dpkg: error processing package agent-supervision (--configure):
 installed agent-supervision package post-installation script subprocess returned error exit status 1
Errors were encountered while processing:
 agent-supervision
Log ended: 2026-08-20  14:03:12
""")
open("/var/log/dpkg.log", "w").write("""2026-04-02 10:12:45 install agent-supervision:all <none> 2.0
2026-04-02 10:12:45 status installed agent-supervision:all 2.0
2026-04-02 10:12:45 install boutique-api:all <none> 3.8.0
2026-04-02 10:12:45 status installed boutique-api:all 3.8.0
2026-04-02 10:12:46 install libboutique-crypto:all <none> 1.3.9
2026-04-02 10:12:46 status installed libboutique-crypto:all 1.3.9
2026-08-20 14:03:11 upgrade agent-supervision:all 2.0 2.1
2026-08-20 14:03:11 status half-installed agent-supervision:all 2.0
2026-08-20 14:03:11 status unpacked agent-supervision:all 2.1
2026-08-20 14:03:11 configure agent-supervision:all 2.1 <none>
2026-08-20 14:03:12 status half-configured agent-supervision:all 2.1
""")
EOF
