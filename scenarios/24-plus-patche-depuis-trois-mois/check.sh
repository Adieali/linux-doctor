#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
dpkg_propre() { [[ -z $(dpkg --audit) ]]; }
agent_configure() { [[ $(dpkg-query -W -f='${db:Status-Abbrev}' agent-supervision) == 'ii ' && $(version agent-supervision) == 2.1 ]]; }
serveur_local() { grep -Eq '^serveur *= *10\.90\.0\.20$' /etc/agent-supervision.conf; }
crypto_corrigee() { dpkg --compare-versions "$(version libboutique-crypto)" ge 1.4.3; }
crypto_libre() { ! apt-mark showhold | grep -qx libboutique-crypto; }
api_en_production() { [[ $(version "boutique-api") == "$1" ]]; }
automatiques() {
  systemctl is-enabled -q apt-daily.timer apt-daily-upgrade.timer &&
    apt-config dump | grep -qx 'APT::Periodic::Unattended-Upgrade "1";' &&
    apt-config dump | grep -qx 'APT::Periodic::Update-Package-Lists "1";'
}

ok "dpkg est dans un état propre (dpkg --audit ne signale rien)" dpkg_propre
ok "agent-supervision 2.1 est installé et configuré" agent_configure
ok "l'agent de supervision tourne" systemctl is-active -q agent-supervision
ok "il parle toujours au serveur de supervision réglé à la main (10.90.0.20)" serveur_local
ok "libboutique-crypto est en 1.4.3 au moins (CVE-2026-31337)" crypto_corrigee
ok "libboutique-crypto n'est plus bloquée" crypto_libre
ok "boutique-api est toujours en 3.8.0, sa version de production" api_en_production 3.8.0
ok "les mises à jour automatiques sont planifiées" automatiques
(( fail )) && exit 1

echo "  Le miroir publie un correctif de sécurité (libboutique-crypto 1.4.4) et une version de l'application"
echo "  (boutique-api 3.9.1). Passage quotidien des mises à jour automatiques :"
src=$(mktemp -d)
install -d "$src/usr/lib/boutique"
echo 1.4.4 > "$src/usr/lib/boutique/libboutique-crypto.version"
/usr/local/lib/labo/paquet libboutique-crypto 1.4.4 trixie-securite "Bibliothèque de signatures de la boutique (webhooks de paiement)" "$src"
rm -rf "$src"; src=$(mktemp -d)
install -d "$src/opt/boutique-api"
echo 3.9.1 > "$src/opt/boutique-api/VERSION"
/usr/local/lib/labo/paquet boutique-api 3.9.1 trixie "API de la boutique (livrée par les mises en production)" "$src"
rm -rf "$src"
/usr/local/lib/labo/publier
apt-get update -qq >/dev/null 2>&1
unattended-upgrade >/dev/null 2>&1
crypto_a_jour() { [[ $(version libboutique-crypto) == 1.4.4 ]]; }
ok "le correctif de sécurité s'est installé seul" crypto_a_jour
ok "la version de l'application, non : elle attend sa mise en production" api_en_production 3.8.0
# Le dépôt revient à son état, pour un prochain check.
rm -f /srv/depot/debian/pool/trixie-securite/libboutique-crypto_1.4.4_all.deb /srv/depot/debian/pool/trixie/boutique-api_3.9.1_all.deb
/usr/local/lib/labo/publier

exit $fail
