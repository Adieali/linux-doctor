#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

journal=/var/log/labo-proxy.log
expedition() { [[ $(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -X POST http://localhost:8000/expedier) == 201 ]]; }
# Ce que le proxy a vu depuis le début du check.
vu_par_le_proxy() { tail -n "+$((debut + 1))" "$journal"; }
transporteur_par_le_proxy() { vu_par_le_proxy | grep -q 'CONNECT api.transporteur.example:443$'; }
rien_d_interne() { ! vu_par_le_proxy | grep -qE 'stock\.interne|localhost|127\.0\.0\.1|REFUSÉ'; }
sortie_fermee() { ! curl -s -o /dev/null --noproxy '*' --max-time 3 https://api.transporteur.example/v1/sante; }

# Comme au prochain démarrage : ce qui ne vit qu'en mémoire ou dans /run disparaît, le service repart.
echo "  Redémarrage simulé : environnement de systemd et drop-ins de /run effacés, service relancé..."
systemctl unset-environment http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
rm -rf /run/systemd/system/expeditions.service.d
systemctl daemon-reload
systemctl restart expeditions
timeout 10 bash -c 'until curl -s -o /dev/null http://localhost:8000/; do sleep 0.3; done'
debut=$(wc -l < "$journal")

ok "la sortie directe vers Internet reste fermée" sortie_fermee
ok "une expédition passe de bout en bout" expedition
ok "le transporteur est joint par le proxy" transporteur_par_le_proxy
ok "les appels internes et locaux ne passent pas par le proxy" rien_d_interne

exit $fail
