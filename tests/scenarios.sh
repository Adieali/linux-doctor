#!/usr/bin/env bash
# Rejoue chaque scénario de bout en bout : la panne s'installe, le check doit la refuser,
# puis les blocs bash de la « Démarche commentée » du README sont exécutés tels quels,
# et le check doit les accepter.
#
# Usage : tests/scenarios.sh [numéro | début-fin ...]    tous les scénarios par défaut
# Une plage ne prend que les scénarios présents : la CI découpe par semaine sans connaître les jours publiés.
# En cas d'échec, le serveur reste en place pour l'enquête : ./doctor shell <numéro>
set -euo pipefail
cd "$(dirname "$0")/.."

# On exécute le texte même que lit le joueur : une solution publiée ne peut pas dériver sans casser ce test.
solution() {
  awk '/^## Démarche commentée/ {f=1; next} /^## / {f=0}
       f && /^```bash/ {c=1; next} c && /^```/ {c=0} c' "$1/README.md"
}

presents=()
for d in scenarios/*/; do d=${d#scenarios/}; presents+=("${d%%-*}"); done

nums=()
for a in "${@:-01-99}"; do
  if [[ $a =~ ^([0-9]+)-([0-9]+)$ ]]; then
    for n in "${presents[@]}"; do
      (( 10#$n >= 10#${BASH_REMATCH[1]} && 10#$n <= 10#${BASH_REMATCH[2]} )) && nums+=("$n")
    done
  else
    nums+=("$a")
  fi
done
if (( ${#nums[@]} == 0 )); then
  echo "Aucun scénario publié dans : $*"
  exit 0
fi

for n in "${nums[@]}"; do
  dirs=(scenarios/"$n"-*/)
  dir=${dirs[0]%/}
  echo "=== $dir"
  ./doctor start "$n" </dev/null >/dev/null
  if ./doctor check "$n"; then
    echo "ÉCHEC $n : le check accepte le serveur en panne"
    exit 1
  fi
  # Une démarche contient des diagnostics qui échouent exprès (dig vers un résolveur mort) : le check seul tranche.
  sortie=$(solution "$dir" | docker exec -i "linux-doctor-$n" bash 2>&1) || true
  if ! ./doctor check "$n"; then
    echo "$sortie"
    echo "ÉCHEC $n : la solution du README ne passe pas le check"
    exit 1
  fi
  ./doctor stop "$n" >/dev/null
done
echo "Tous les scénarios passent : ${nums[*]}"
