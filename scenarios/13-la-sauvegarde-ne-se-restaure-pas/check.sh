#!/usr/bin/env bash
fail=0
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [OK] $label"; else echo "  [KO] $label"; fail=1; fi; }

bin=/usr/lib/postgresql/17/bin
restau=/var/lib/postgresql/check-restauration
pg() { runuser -u postgres -- psql -X -q -At -d boutique "$@"; }

# La sauvegarde la plus récente de /srv/sauvegardes, fichier ou dossier, créée après le début du check.
nouvelle_sauvegarde() { find /srv/sauvegardes -mindepth 1 -maxdepth 1 -newer /run/check-13 -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-; }

# Restauration indépendante de l'exercice : dossier de pg_basebackup, au format tar ou plain.
restaurer() {
  local src=$1 t
  rm -rf "$restau"
  install -d -o postgres -m 700 "$restau"
  if [[ -d $src && -n $(compgen -G "$src/base.tar*") ]]; then
    for t in "$src"/base.tar*; do runuser -u postgres -- tar xf "$t" -C "$restau" || return 1; done
    for t in "$src"/pg_wal.tar*; do
      [[ -e $t ]] && { runuser -u postgres -- tar xf "$t" -C "$restau/pg_wal" || return 1; }
    done
  elif [[ -f $src/PG_VERSION ]]; then
    runuser -u postgres -- cp -a "$src"/. "$restau"/ || return 1
  else
    return 1
  fi
  # Un pg_wal qui pointe vers la prod n'est pas une sauvegarde. Un postmaster.pid copié désignerait le
  # processus de la prod, et pg_ctl stop l'arrêterait.
  [[ ! -L $restau/pg_wal ]] || return 1
  rm -f "$restau/postmaster.pid"
  printf "port = 5436\nlisten_addresses = ''\nunix_socket_directories = '/var/run/postgresql'\narchive_mode = off\n" > "$restau/postgresql.conf"
  echo "local all all peer" > "$restau/pg_hba.conf"
  touch "$restau/pg_ident.conf"
  chown postgres: "$restau"/postgresql.conf "$restau"/pg_hba.conf "$restau"/pg_ident.conf
  runuser -u postgres -- "$bin/pg_ctl" -D "$restau" -l "$restau/check.log" -w -t 120 start
}
arreter() { runuser -u postgres -- "$bin/pg_ctl" -D "$restau" -m fast stop >/dev/null 2>&1; rm -rf "$restau"; }

temoin_present() { [[ $(runuser -u postgres -- psql -X -At -p 5436 -d boutique -c "SELECT count(*) FROM commandes WHERE client = 'témoin $1'") == 1 ]]; }
integre() { runuser -u postgres -- "$bin/pg_amcheck" -p 5436 -d boutique --install-missing --heapallindexed; }

ok "la sauvegarde part toujours chaque nuit" systemctl is-active -q sauvegarde-base.timer
ok "l'application écrit toujours dans la base" systemctl is-active -q lab-boutique

if (( fail == 0 )); then
  echo "  Sauvegarde lancée pendant que l'application écrit..."
  touch /run/check-13
  temoin=$RANDOM
  pg -c "INSERT INTO commandes (client, montant) VALUES ('témoin $temoin', 1)"
  ok "la sauvegarde se termine sans erreur" systemctl start sauvegarde-base
  src=$(nouvelle_sauvegarde)
  echo "  Restauration de ${src:-(aucune nouvelle sauvegarde)} à part, sur le port 5436..."
  ok "la sauvegarde démarre comme une base à part entière" restaurer "$src"
  ok "elle contient la commande écrite juste avant la sauvegarde" temoin_present "$temoin"
  ok "ses tables et ses index sont intacts (pg_amcheck)" integre
  arreter
  ok "l'exercice de restauration du PRA passe" systemctl start exercice-restauration
else
  echo "  [KO] sauvegarde de test non lancée tant que les points ci-dessus ne sont pas réglés"
fi
rm -f /run/check-13

exit $fail
