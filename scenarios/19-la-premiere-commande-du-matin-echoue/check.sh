#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

# Une commande : réussie, et en moins de 2 s.
rapide() {
  local r
  r=$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{time_total}' http://localhost:8000/commandes)
  [[ ${r% *} == 200 ]] && awk -v t="${r#* }" 'BEGIN { exit !(t < 2) }'
}
# Les connexions du service, vues par la base : leur heure d'ouverture.
connexions() { runuser -u postgres -- psql -Atqc "SELECT backend_start FROM pg_stat_activity WHERE usename = 'commandes' ORDER BY 1"; }
# La connexion de la veille est toujours là, et c'est elle qui a servi la commande du matin. (Une connexion
# abandonnée par le serveur reste visible côté base : son heure d'ouverture ne suffit pas.)
a_servi_le_matin() {
  [[ $(runuser -u postgres -- psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE usename = 'commandes' AND extract(epoch FROM query_start) >= $matin") -ge 1 ]]
}
meme_connexion() { [[ -n $veille && $(connexions) == "$veille" ]] && a_servi_le_matin; }
delai_pare_feu() { [[ $(ip netns exec pare-feu sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established) == 20 ]]; }

# Comme au prochain démarrage : valeurs par défaut du noyau, fichiers de /etc/sysctl.d relus, service relancé.
echo "  Redémarrage simulé : réglages du noyau relus, service des commandes relancé..."
sysctl -qw net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9
sysctl -q --system >/dev/null 2>&1
systemctl restart commandes
timeout 10 bash -c 'until curl -fs -o /dev/null http://localhost:8000/commandes; do sleep 0.3; done'

ok "le pare-feu oublie toujours une connexion inactive au bout de 20 s" delai_pare_feu
ok "le service des commandes répond" rapide
veille=$(connexions)

echo "  Une nuit passe : 30 s sans une commande..."
sleep 30
matin=$(date +%s)
ok "la première commande du matin passe, en moins de 2 s" rapide
ok "par la connexion de la veille, sans en ouvrir une nouvelle" meme_connexion

exit $fail
