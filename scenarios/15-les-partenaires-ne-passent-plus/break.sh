#!/usr/bin/env bash
# Panne : chaîne de certificats incomplète après renouvellement. Le hook de déploiement d'un ancien admin
# colle le certificat renouvelé avec un intermédiaire figé dans un fichier (R10, téléchargé en 2023). Cette
# nuit, l'AC a signé avec un autre intermédiaire (R11) : nginx sert « certificat + R10 », deux certificats
# qui ne se suivent pas. Un client qui ne connaît que la racine (les partenaires) ne remonte plus la chaîne.
# Les navigateurs complètent seuls (AIA, cache d'intermédiaires). La sonde du serveur reste verte : son
# bundle contient la racine et tous les intermédiaires, elle valide sans regarder la chaîne envoyée.
# Fausses pistes : la date de validité, l'horloge, TLS 1.3 et les suites, « il y a bien deux certificats ».
set -euo pipefail

ca=/var/lib/labo-acme
live=/etc/acme/live/api.boutique.lan

# L'AC (simulée) : une racine, et les intermédiaires qu'elle utilise tour à tour.
install -d -m 700 "$ca"
cd "$ca"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout racine.key -out racine.pem \
  -days 3650 -subj "/O=Labo AC/CN=Labo Racine X1" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" 2>/dev/null
for nom in R10 R11 R12; do
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$nom.key" \
    -subj "/O=Labo AC/CN=Labo $nom" -out "$nom.csr" 2>/dev/null
  openssl x509 -req -in "$nom.csr" -CA racine.pem -CAkey racine.key -set_serial "0x$(openssl rand -hex 8)" \
    -days 1825 -sha256 -out "$nom.pem" -extfile <(printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" \
    "keyUsage=critical,keyCertSign,cRLSign" "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid") 2>/dev/null
  rm -f "$nom.csr"
done
cd /
install -d /etc/ssl/certs
cp "$ca/racine.pem" /etc/ssl/certs/labo-racine-x1.pem

# Le client ACME (simulé) : même clé à chaque renouvellement, puis les hooks de déploiement.
cat > /usr/local/bin/acme-renouveler <<'EOF'
#!/bin/bash
# Labo : simule le client ACME. Renouvelle api.boutique.lan auprès de l'AC (même clé), écrit
# cert.pem, chain.pem et fullchain.pem dans /etc/acme/live/api.boutique.lan, puis lance /etc/acme/deploy.d/*.
set -euo pipefail
ca=/var/lib/labo-acme
live=/etc/acme/live/api.boutique.lan
inter=$(cat "$ca/intermediaire-actuel")
openssl req -new -key "$live/privkey.pem" -subj "/CN=api.boutique.lan" -out "$ca/demande.csr" 2>/dev/null
openssl x509 -req -in "$ca/demande.csr" -CA "$ca/$inter.pem" -CAkey "$ca/$inter.key" \
  -set_serial "0x$(openssl rand -hex 8)" -days 90 -sha256 -out "$live/cert.pem" \
  -extfile <(printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=serverAuth" "subjectAltName=DNS:api.boutique.lan" "authorityKeyIdentifier=keyid") 2>/dev/null
rm -f "$ca/demande.csr"
cp "$ca/$inter.pem" "$live/chain.pem"
cat "$live/cert.pem" "$live/chain.pem" > "$live/fullchain.pem"
logger -t acme "api.boutique.lan renouvelé, émis par Labo $inter, valide jusqu'au $(openssl x509 -noout -enddate -in "$live/cert.pem" | cut -d= -f2)"
for hook in /etc/acme/deploy.d/*; do
  [[ -x $hook ]] && RENEWED_LINEAGE=$live "$hook"
done
EOF
chmod +x /usr/local/bin/acme-renouveler
install -d -m 700 "$live"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$live/privkey.pem" 2>/dev/null

# Le hook de déploiement, tel que l'a laissé l'ancien admin.
install -d /etc/acme/deploy.d /etc/nginx/ssl
cp "$ca/R10.pem" /etc/nginx/ssl/intermediaire.pem
cat > /etc/acme/deploy.d/nginx <<'EOF'
#!/bin/bash
# Déploiement du certificat de l'API (J.-M., mars 2023).
# La chaîne pour nginx : notre certificat, puis l'intermédiaire de l'AC (téléchargé sur son site).
set -e
cat "$RENEWED_LINEAGE/cert.pem" /etc/nginx/ssl/intermediaire.pem > /etc/nginx/ssl/api.crt
install -m 600 "$RENEWED_LINEAGE/privkey.pem" /etc/nginx/ssl/api.key
systemctl reload nginx
EOF
chmod +x /etc/acme/deploy.d/nginx

# L'API des partenaires. Le site HTTPS n'est chargé qu'au premier déploiement du certificat (reload du hook).
systemctl start nginx
install -d /srv/api
printf '{"reference":"CHAISE-ORME","stock":42}\n' > /srv/api/stock
printf '{"etat":"ok"}\n' > /srv/api/sante
cat > /etc/nginx/sites-available/api <<'EOF'
server {
    listen 443 ssl;
    server_name api.boutique.lan;
    ssl_certificate     /etc/nginx/ssl/api.crt;
    ssl_certificate_key /etc/nginx/ssl/api.key;

    location /api/ {
        alias /srv/api/;
        default_type application/json;
    }
}
EOF
ln -sf /etc/nginx/sites-available/api /etc/nginx/sites-enabled/api
echo "10.50.0.10 api.boutique.lan" >> /etc/hosts

# Un partenaire : il ne fait confiance qu'à la racine, comme un client Java ou Python ordinaire.
ip netns add partenaire
ip link add eth1 type veth peer name eth0 netns partenaire
ip addr add 10.50.0.10/24 dev eth1
ip link set eth1 up
ip -n partenaire link set lo up
ip -n partenaire addr add 10.50.0.20/24 dev eth0
ip -n partenaire link set eth0 up
install -d /etc/netns/partenaire /opt/labo/partenaire
printf '127.0.0.1 localhost\n10.50.0.10 api.boutique.lan\n' > /etc/netns/partenaire/hosts
cp "$ca/racine.pem" /opt/labo/partenaire/racine.pem
cat > /usr/local/bin/partenaire <<'EOF'
#!/bin/bash
# Labo : lance une commande depuis le réseau d'un partenaire, qui ne fait confiance qu'à la racine de l'AC.
export CURL_CA_BUNDLE=/opt/labo/partenaire/racine.pem SSL_CERT_FILE=/opt/labo/partenaire/racine.pem
exec ip netns exec partenaire "$@"
EOF
chmod +x /usr/local/bin/partenaire

# Le rechargement de nginx (dans le hook) est asynchrone : attendre que l'émetteur servi soit le bon.
emetteur_servi() {
  openssl s_client -connect 10.50.0.10:443 -servername api.boutique.lan </dev/null 2>/dev/null |
    openssl x509 -noout -issuer 2>/dev/null | grep -q "Labo $1\$"
}
attendre_emetteur() { for _ in {1..40}; do emetteur_servi "$1" && return 0; sleep 0.25; done; return 1; }

# Août : renouvellement avec R10, tout passe.
echo R10 > "$ca/intermediaire-actuel"
/usr/local/bin/acme-renouveler
attendre_emetteur R10
partenaire curl -fs -o /dev/null --max-time 5 https://api.boutique.lan/api/stock

# La sonde TLS, avec « tous les certificats de l'AC, pour être tranquille ».
install -d /etc/sonde
cat "$ca/racine.pem" "$ca/R10.pem" "$ca/R11.pem" > /etc/sonde/ca-bundle.pem
cat > /etc/systemd/system/sonde-tls.service <<'EOF'
[Unit]
Description=Supervision : l'API des partenaires répond en HTTPS

[Service]
Type=oneshot
ExecStart=/usr/bin/curl -fsS --max-time 5 --cacert /etc/sonde/ca-bundle.pem -o /dev/null https://api.boutique.lan/api/sante
EOF
cat > /etc/systemd/system/sonde-tls.timer <<'EOF'
[Unit]
Description=Supervision de l'API des partenaires, toutes les 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now sonde-tls.timer 2>/dev/null

# Cette nuit, 3 h : l'AC signe désormais avec R11.
echo R11 > "$ca/intermediaire-actuel"
/usr/local/bin/acme-renouveler
attendre_emetteur R11
systemctl start sonde-tls

# Repères pour le check : le processus maître de nginx et la clé publique épinglée.
systemctl show -p MainPID --value nginx > "$ca/nginx-maitre"
openssl pkey -in "$live/privkey.pem" -pubout -outform der 2>/dev/null | sha256sum | cut -d' ' -f1 > "$ca/cle-epinglee"

if partenaire curl -fs -o /dev/null --max-time 5 https://api.boutique.lan/api/stock; then
  echo "Le partenaire aurait dû échouer" >&2
  exit 1
fi
