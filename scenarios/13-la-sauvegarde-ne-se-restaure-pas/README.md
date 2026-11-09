# 13. La sauvegarde existe mais ne se restaure pas

## Le ticket

> **Ticket #4778, priorité haute**
> L'exercice trimestriel du plan de reprise a échoué ce matin : la sauvegarde de cette nuit ne démarre pas (`exercice-restauration`). D'après l'équipe, les sauvegardes « marchent » depuis deux ans : le job est vert chaque nuit, l'archive contient tous les fichiers, et sa taille suit celle de la base.
> L'auditeur passe dans quinze jours et demandera un exercice réussi.
> Contraintes : la base reste en service pendant la sauvegarde, l'application écrit en continu. L'exercice de restauration doit rester automatique et ne jamais toucher à la prod.
> L'unité `lab-boutique` simule l'application : n'y touche pas.

## Impact business

Si le serveur de base disparaissait aujourd'hui, il n'y aurait rien à restaurer : deux ans de sauvegardes vertes, et pas une seule utilisable. Chaque jour sans sauvegarde valide est un jour où un disque mort, une erreur humaine ou un rançongiciel peut coûter toute la boutique. L'exercice raté est la bonne nouvelle de l'histoire : il a trouvé le problème avant l'incident.

## Les enjeux

- Comprendre pourquoi une archive qui contient « tous les fichiers » ne restaure pas une base.
- Ne pas forcer la restauration pour faire passer l'exercice : une base qui démarre n'est pas forcément une base intacte.
- Sauvegarder une base en service avec l'outil prévu pour, WAL compris.
- Adapter l'exercice au nouveau format, et lui faire vérifier l'intégrité, pas seulement le démarrage.

## Ce qui est vérifié

- la sauvegarde part toujours chaque nuit
- l'application écrit toujours dans la base

Si c'est bon, le check lance une sauvegarde pendant que l'application écrit, et la restaure lui-même, à part, sur le port 5436. Il vérifie :

- la sauvegarde se termine sans erreur
- la sauvegarde démarre comme une base à part entière
- elle contient la commande écrite juste avant la sauvegarde
- ses tables et ses index sont intacts (`pg_amcheck`)
- l'exercice de restauration du PRA passe

La restauration du check accepte un dossier produit par `pg_basebackup`, au format tar ou plain.

## Indices

<details><summary>Indice 1</summary>

`journalctl -u exercice-restauration`, puis le journal de l'instance d'exercice dans /srv/exercice. Que cherche PostgreSQL au démarrage, et pourquoi ne le trouve-t-il pas ?

</details>

<details><summary>Indice 2</summary>

`tar tzvf` sur l'archive, et cherche `pg_wal`. Puis `ls -l /var/lib/postgresql/17/main/`. Et que dit le script de sauvegarde du code de sortie 1 de `tar` ?

</details>

<details><summary>Indice 3</summary>

`pg_basebackup`, ses options `-X stream` et `-Ft`. Le fichier `backup_label`, et ce qu'il dit à PostgreSQL au démarrage.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
journalctl -u exercice-restauration -o cat --no-pager | tail -3
grep PANIC /srv/exercice/exercice.log         # could not locate a valid checkpoint record
ls -l /srv/sauvegardes/
tar tzvf /srv/sauvegardes/base-*.tar.gz | grep -E 'main/pg_wal |backup_label'   # pg_wal n'est qu'un lien
ls -l /var/lib/postgresql/17/main/pg_wal      # lien vers /srv/pg_wal, le volume des WAL
cat /usr/local/bin/sauvegarde-base
```

Deux problèmes, dont un seul se voit.

Le premier : `pg_wal` est un lien vers son propre volume, et `tar` archive le lien, pas les fichiers. L'archive ne contient aucun WAL. Au démarrage, PostgreSQL lit dans `global/pg_control` l'emplacement du dernier point de contrôle, et va chercher cet enregistrement dans les WAL. Il n'y en a pas : la base refuse de démarrer.

Le second est plus grave, parce qu'il resterait même avec les WAL. `tar` copie les fichiers un par un pendant que la base écrit : chaque fichier est copié à un instant différent, et l'archive ne correspond à aucun état réel de la base. PostgreSQL sait réparer une telle copie, à deux conditions : savoir à quel moment elle a commencé (le fichier `backup_label`, écrit quand on prévient la base qu'une sauvegarde démarre), et disposer de tous les WAL écrits pendant la copie. Sans `backup_label`, il repartirait du point de contrôle noté dans `pg_control` au moment où `tar` est passé dessus. Les fichiers copiés avant ce moment ne seraient jamais réparés : une base qui démarre, avec des pages incohérentes que personne ne voit. Le script le signale lui-même : `tar` sort en code 1 parce que des fichiers changent pendant la copie, et une ligne le déclare « normal ».

`pg_basebackup` règle les deux : il prévient la base, copie les fichiers, écrit le `backup_label`, et récupère en flux les WAL produits pendant la copie (`-X stream`). Il suit aussi `pg_wal` à travers le lien. La sauvegarde passe sous l'utilisateur `postgres`, qui en devient propriétaire :

```bash
chown postgres: /srv/sauvegardes
cat > /usr/local/bin/sauvegarde-base <<'EOF'
#!/bin/bash
# Sauvegarde nocturne de la base, en service : pg_basebackup, avec les WAL écrits pendant la copie.
# Ticket #4778 : l'ancien tar à chaud ne se restaurait pas.
set -euo pipefail
cible=/srv/sauvegardes/base-$(date +%F)
rm -rf "$cible.partielle"
pg_basebackup -D "$cible.partielle" -Ft -z -X stream -c fast
rm -rf "$cible"
mv "$cible.partielle" "$cible"
EOF
mkdir -p /etc/systemd/system/sauvegarde-base.service.d
printf '[Service]\nUser=postgres\n' > /etc/systemd/system/sauvegarde-base.service.d/utilisateur.conf
systemctl daemon-reload
systemctl start sauvegarde-base
ls /srv/sauvegardes/base-*/                   # base.tar.gz, pg_wal.tar.gz, backup_manifest
```

La copie se fait dans un dossier `.partielle`, renommé seulement à la fin : une sauvegarde interrompue ne peut jamais passer pour la dernière bonne. Reste l'exercice, à adapter au nouveau format. Il vérifie maintenant l'intégrité des tables et des index avec `pg_amcheck`, en plus du démarrage :

```bash
cat > /usr/local/bin/exercice-restauration <<'EOF'
#!/bin/bash
# Exercice de restauration du PRA : la dernière sauvegarde démarre à part, sur le port 5435,
# contient les commandes, et ses tables et index sont intacts.
set -euo pipefail
bin=/usr/lib/postgresql/17/bin
derniere=$(ls -td /srv/sauvegardes/base-????-??-??/ | head -1)
cible=/srv/exercice
rm -rf "$cible"
install -d -o postgres -m 700 "$cible"
runuser -u postgres -- tar xzf "$derniere/base.tar.gz" -C "$cible"
runuser -u postgres -- tar xzf "$derniere/pg_wal.tar.gz" -C "$cible/pg_wal"
printf "port = 5435\nlisten_addresses = ''\nunix_socket_directories = '/var/run/postgresql'\narchive_mode = off\n" > "$cible/postgresql.conf"
echo "local all all peer" > "$cible/pg_hba.conf"
touch "$cible/pg_ident.conf"
chown postgres: "$cible"/postgresql.conf "$cible"/pg_hba.conf "$cible"/pg_ident.conf
trap 'runuser -u postgres -- "$bin/pg_ctl" -D "$cible" -m fast stop >/dev/null 2>&1 || true' EXIT
runuser -u postgres -- "$bin/pg_ctl" -D "$cible" -l "$cible/exercice.log" -w -t 120 start
n=$(runuser -u postgres -- psql -X -At -p 5435 -d boutique -c "SELECT count(*) FROM commandes")
runuser -u postgres -- "$bin/pg_amcheck" -p 5435 -d boutique --install-missing --heapallindexed
echo "Restauration de $derniere : $n commandes, tables et index intacts"
EOF
systemctl start exercice-restauration
journalctl -u exercice-restauration -o cat --no-pager | tail -1
```

Les anciennes archives ne servent à rien, mais on ne les supprime pas pendant l'incident : on les marque, pour que personne ne les prenne un jour pour une sauvegarde :

```bash
for f in /srv/sauvegardes/base-*.tar.gz; do mv "$f" "$f.inexploitable"; done
```

Dernière étape, hors du serveur : dire clairement à la direction que la boutique n'avait aucune sauvegarde utilisable jusqu'à aujourd'hui, et programmer l'exercice chaque mois, plus seulement chaque trimestre.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Ajouter `/srv/pg_wal` dans le `tar`** : les WAL sont là, la base démarre peut-être. Mais la copie reste prise à des instants différents, sans `backup_label` : rien ne garantit qu'elle soit intacte, et rien ne le signale.
- **`pg_resetwal` sur la copie pour la forcer à démarrer** : elle démarre, avec des données incohérentes, et l'exercice passe au vert. C'est le pire résultat possible : une fausse sauvegarde certifiée.
- **Arrêter la base pendant le `tar`** : la copie devient cohérente, au prix d'une coupure de la boutique chaque nuit, et toujours sans les WAL si on oublie le lien.
- **`pg_backup_start()` et `pg_backup_stop()` autour du `tar`** : la méthode bas niveau, correcte si elle est bien faite. Il faut garder la session ouverte pendant toute la copie, écrire soi-même le `backup_label` renvoyé par `pg_backup_stop()` et récupérer les WAL. `pg_basebackup` fait tout ça, sans risque d'oubli.
- **`pg_dump`** : une sauvegarde logique, cohérente, utile en complément. Mais la restauration recharge toutes les données et reconstruit tous les index, beaucoup plus lentement, et ne permet pas de restaurer à un instant précis.
- **`pg_basebackup -X stream`, et un exercice qui vérifie l'intégrité** : une sauvegarde cohérente, avec ses WAL, prise base en service, et une preuve automatique qu'elle se restaure.

</details>

## En prod

- Une sauvegarde n'est validée que par une restauration. Automatiser l'exercice, et le faire vérifier plus que le démarrage : `pg_amcheck`, des comptages, une requête métier.
- Ne jamais sauvegarder une base en service en copiant ses fichiers sans la prévenir. `pg_basebackup`, ou un outil qui l'utilise (pgBackRest, Barman).
- Un code de sortie qu'on ignore « parce que c'est normal » mérite une explication écrite. Ici, c'était le symptôme.
- `pg_verifybackup` contrôle une sauvegarde de `pg_basebackup` à l'aide de son `backup_manifest`, sans la restaurer : au format plain avec PostgreSQL 17, au format tar aussi à partir de la version 18.
- Garder plusieurs sauvegardes, et au moins une hors du serveur. Celle-ci était sur le même serveur que la base.
