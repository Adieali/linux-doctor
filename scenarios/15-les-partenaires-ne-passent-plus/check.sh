#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

ca=/var/lib/labo-acme
live=/etc/acme/live/api.boutique.lan

partenaire_passe() { partenaire curl -fs --max-time 5 -o /dev/null https://api.boutique.lan/api/stock; }
# Le certificat que nginx présente vraiment, et son empreinte.
servi() { openssl s_client -connect 10.50.0.10:443 -servername api.boutique.lan </dev/null 2>/dev/null | openssl x509 -outform pem; }
empreinte() { openssl x509 -noout -fingerprint -sha256 "$@"; }
dernier_certificat() { [[ $(servi | empreinte) == "$(empreinte -in "$live/cert.pem")" ]]; }
meme_maitre() { [[ $(systemctl show -p MainPID --value nginx) == "$(cat "$ca/nginx-maitre")" ]]; }
cle_epinglee() {
  [[ $(servi | openssl x509 -noout -pubkey | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1) == "$(cat "$ca/cle-epinglee")" ]]
}

# Le fichier que nginx sert pour l'API, quel que soit l'endroit où il a été rangé.
fichier_servi() {
  local cible f
  cible=$(servi | empreinte)
  for f in $(nginx -T 2>/dev/null | awk '$1 == "ssl_certificate" {gsub(";", "", $2); print $2}' | sort -u); do
    [[ $(empreinte -in "$f" 2>/dev/null) == "$cible" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Un rechargement de nginx est asynchrone : attendre que les nouveaux workers servent la nouvelle chaîne.
attendre() { for _ in {1..20}; do "$@" && return 0; sleep 0.25; done; return 1; }
longueur_chaine() { openssl s_client -connect 10.50.0.10:443 -servername api.boutique.lan -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE'; }
chaine_de() { [[ $(longueur_chaine) == "$1" ]]; }

# Notre certificat seul, sans intermédiaire, le temps d'un passage de la sonde : elle doit échouer.
sonde_voit_la_casse() {
  local f n rc
  f=$(fichier_servi) || return 1
  n=$(longueur_chaine)
  cp "$f" /tmp/chaine-servie
  cat "$live/cert.pem" > "$f"
  systemctl reload nginx && attendre chaine_de 1
  systemctl start sonde-tls
  rc=$?
  cat /tmp/chaine-servie > "$f"
  rm -f /tmp/chaine-servie
  systemctl reload nginx && attendre chaine_de "$n"
  systemctl reset-failed sonde-tls 2>/dev/null
  (( rc != 0 ))
}

ok "les partenaires passent, avec la seule racine de l'AC comme confiance" partenaire_passe
ok "nginx a été rechargé, pas redémarré" meme_maitre
ok "la clé publique n'a pas changé (épinglée par la banque partenaire)" cle_epinglee
ok "nginx sert le certificat du dernier renouvellement" dernier_certificat
ok "la sonde TLS est verte" systemctl start sonde-tls

if (( fail == 0 )); then
  echo "  Notre certificat servi seul, sans intermédiaire, le temps d'un passage de la sonde..."
  ok "la sonde voit la chaîne incomplète" sonde_voit_la_casse
  ok "les partenaires passent de nouveau" partenaire_passe
  echo "  Renouvellement suivant : l'AC signe désormais avec un autre intermédiaire..."
  echo R12 > "$ca/intermediaire-actuel"
  acme-renouveler >/dev/null 2>&1
  ok "nginx sert le nouveau certificat" attendre dernier_certificat
  ok "les partenaires passent toujours" partenaire_passe
  ok "la clé publique n'a toujours pas changé" cle_epinglee
else
  echo "  [KO] renouvellement de test non lancé tant que les points ci-dessus ne sont pas réglés"
fi

exit $fail
