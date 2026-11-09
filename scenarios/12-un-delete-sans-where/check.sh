#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }
ref() { sed -n "s/^$1=//p" /var/lib/linux-doctor/12; }
dernier=$(ref dernier)

empreinte_commandes() {
  pg -c "SELECT md5(string_agg(id || ':' || client || ':' || montant || ':' || cree_le, ',' ORDER BY id)) FROM commandes WHERE id <= $dernier AND client <> 'test'"
}
empreinte_paiements() {
  pg -c "SELECT md5(string_agg(p.id || ':' || p.commande || ':' || p.montant || ':' || p.moyen, ',' ORDER BY p.id)) FROM paiements p JOIN commandes c ON c.id = p.commande WHERE c.id <= $dernier AND c.client <> 'test'"
}

# Toutes les commandes que l'application a enregistrées depuis l'incident sont encore en base.
depuis_incident() {
  local ids manquantes
  ids=$(awk -v d="$dernier" '$4 > d { print $4 }' /var/log/boutique/commandes.log | paste -sd,)
  [[ -n $ids ]] || return 1
  manquantes=$(pg -c "SELECT count(*) FROM unnest('{$ids}'::bigint[]) i WHERE NOT EXISTS (SELECT 1 FROM commandes WHERE id = i)")
  (( manquantes == 0 ))
}

nouvelle_commande() {
  runuser -u boutique -- psql -X -q -At -d boutique -c "INSERT INTO commandes (client, montant) VALUES ('check', 1)"
}

# Lu dans le catalogue plutôt qu'essayé : avec log_statement = 'mod', un DELETE d'essai finirait dans le
# journal, à côté de celui de l'incident.
support_ne_supprime_plus() {
  [[ $(pg -c "SELECT has_table_privilege('support', 'commandes', 'DELETE') OR has_table_privilege('support', 'paiements', 'DELETE')") == f ]]
}

ok "la base de prod n'a pas redémarré depuis l'incident" test "$(pg -c "SELECT pg_postmaster_start_time() < '$(ref incident)'::timestamptz")" = t
ok "les commandes d'avant l'incident sont revenues, à l'identique" test "$(empreinte_commandes)" = "$(ref commandes)"
ok "leurs paiements aussi" test "$(empreinte_paiements)" = "$(ref paiements)"
ok "les commandes de test ne sont pas revenues" test "$(pg -c "SELECT count(*) FROM commandes WHERE id <= $dernier AND client = 'test'")" -eq 0
ok "les commandes passées depuis l'incident sont toujours là" depuis_incident
ok "la boutique enregistre toujours des commandes" nouvelle_commande
ok "le support ne peut plus supprimer de commandes ni de paiements" support_ne_supprime_plus
ok "le support lit toujours les commandes depuis sa console" runuser -u support -- psql -X -q -At -d boutique -c "SELECT count(*) FROM commandes"

exit $fail
