#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pm=/root/post-mortem-5000.md
journal_pg=/var/log/postgresql/postgresql-17-main.log

base() { runuser -u postgres -- pg_isready -q; }
commande() { [[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST http://localhost/commandes) == 201 ]]; }
# Chaque commande acceptée par la boutique (réponse 201) a été notée par les clients du labo : toutes doivent être en base.
rien_de_perdu() {
  local attendues trouvees
  sort -nu /var/log/labo-commandes.log > /tmp/labo-ids
  attendues=$(wc -l < /tmp/labo-ids)
  trouvees=$(runuser -u postgres -- psql -X -q -At -d boutique 2>/dev/null <<'SQL'
CREATE TEMP TABLE t (id bigint);
\copy t FROM '/tmp/labo-ids'
SELECT count(*) FROM t JOIN commandes USING (id);
SQL
)
  rm -f /tmp/labo-ids
  (( attendues > 0 && trouvees == attendues ))
}
pas_de_debug() {
  local pid
  pid=$(systemctl show -p MainPID --value api)
  (( pid > 0 )) && ! tr '\0' '\n' < "/proc/$pid/environ" | grep -qx 'LOG_LEVEL=DEBUG'
}
marge() { (( $(df --output=pcent /srv/donnees | tail -1 | tr -dc 0-9) < 70 )); }
sobre() { local a b; marge || return 1; a=$(du -sb /srv/donnees | cut -f1); sleep 20; b=$(du -sb /srv/donnees | cut -f1); (( b - a < 1048576 )); }

# Le contenu d'une section du post-mortem, sans les lignes vides ni les consignes du modèle.
section() { awk -v t="## $1" '$0 == t {f = 1; next} /^## / {f = 0} f && NF && !/^</' "$pm"; }
sections() {
  local s
  for s in "Résumé" "Impact" "Chronologie" "Cause racine" "Causes contributives" "Ce qui a bien marché" "Actions"; do
    [[ -n $(section "$s") ]] || return 1
  done
}
chronologie() {
  local panne
  panne=$(grep -m1 PANIC "$journal_pg" | cut -c12-16)
  (( $(section Chronologie | grep -cE '[0-2][0-9]:[0-5][0-9]') >= 4 )) && section Chronologie | grep -q "$panne"
}
cause_racine() { section "Cause racine" | grep -q '#4987'; }
actions() { (( $(section Actions | grep -c '^- ') >= 3 )); }

ok "PostgreSQL tourne" base
ok "la boutique prend des commandes" commande
ok "aucune commande acceptée par la boutique n'a été perdue" rien_de_perdu
ok "l'API n'est plus en DEBUG" pas_de_debug
ok "le disque de données a de la marge (moins de 70 %)" marge
ok "20 s de trafic ordinaire n'écrivent presque rien sur le disque de données" sobre
if [[ -s $pm ]]; then
  ok "post-mortem : les sept sections du modèle, remplies" sections
  ok "post-mortem : au moins quatre événements datés, dont l'arrêt de PostgreSQL" chronologie
  ok "post-mortem : la cause racine remonte au changement #4987" cause_racine
  ok "post-mortem : au moins trois actions" actions
else
  echo "  [KO] post-mortem rédigé dans $pm, à partir de /root/post-mortem-modele.md"
  fail=1
fi

exit $fail
