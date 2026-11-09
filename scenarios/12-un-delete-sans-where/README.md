# 12. Un DELETE sans WHERE, et les commandes continuent d'arriver

## Le ticket

> **Ticket #4760, priorité critique**
> Il y a quelques minutes, depuis la console SQL du back-office, le support a voulu supprimer les commandes de test. La requête est partie sans sa clause `WHERE` : toutes les commandes ont disparu, et leurs paiements avec. Depuis, la boutique prend de nouvelles commandes, normalement.
> Sauvegardes : une sauvegarde complète cette nuit (/srv/sauvegardes), et l'archivage continu des WAL (/srv/archives/wal).
> Contraintes : la boutique reste ouverte pendant toute l'opération, et les commandes passées depuis l'incident sont conservées. Les commandes de test, elles, devaient bien disparaître. Le support garde sa console, mais elle ne doit plus pouvoir supprimer de commande.
> L'unité `lab-boutique` simule l'application : n'y touche pas.

## Impact business

Les clients ne voient plus leurs commandes passées, la logistique ne sait plus quoi expédier, et la comptabilité a perdu ses paiements. Chaque minute ajoute des commandes neuves à la prod, ce qui interdit de simplement remettre la sauvegarde en place : on effacerait les commandes de l'après-midi. Une restauration ratée, ou faite trop vite, peut coûter plus cher que l'incident lui-même.

## Les enjeux

- Trouver l'instant exact de l'incident, et à quoi il a touché.
- Restaurer à côté de la prod, jusqu'à juste avant l'incident, sans arrêter la boutique.
- Vérifier que les archives contiennent bien tout ce qu'il faut avant de lancer la restauration.
- Réinjecter ce qui manque, et seulement ce qui manque, en une seule transaction.

## Ce qui est vérifié

- la base de prod n'a pas redémarré depuis l'incident
- les commandes d'avant l'incident sont revenues, à l'identique
- leurs paiements aussi
- les commandes de test ne sont pas revenues
- les commandes passées depuis l'incident sont toujours là
- la boutique enregistre toujours des commandes
- le support ne peut plus supprimer de commandes ni de paiements
- le support lit toujours les commandes depuis sa console

## Indices

<details><summary>Indice 1</summary>

`log_statement = 'mod'` : le journal de PostgreSQL a l'heure exacte de la requête, à la milliseconde. Et `\d paiements` explique pourquoi les paiements sont partis aussi.

</details>

<details><summary>Indice 2</summary>

`pg_createcluster` crée un second cluster sur un autre port. Une sauvegarde de base, `restore_command`, `recovery_target_time`, un fichier `recovery.signal` : la restauration à un instant précis se fait là, pas sur la prod.

</details>

<details><summary>Indice 3</summary>

Les WAL de ces dernières minutes sont-ils déjà dans /srv/archives/wal ? Compare le dernier fichier archivé avec `pg_walfile_name(pg_current_wal_lsn())`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
grep -n 'statement: DELETE' /var/log/postgresql/postgresql-17-main.log    # support@boutique, et l'heure exacte
runuser -u postgres -- psql -X -d boutique -c '\d paiements'               # ON DELETE CASCADE
runuser -u postgres -- psql -X -d boutique -c "SELECT count(*), min(id) FROM commandes"   # seulement celles arrivées depuis
ls /srv/sauvegardes/*/
```

Une seule requête, `DELETE FROM commandes`, et la cascade a vidé les paiements. Remettre la sauvegarde de la nuit sur la prod effacerait les commandes arrivées depuis l'incident, et ne rendrait même pas celles de la matinée. Il faut une restauration à un instant précis : la sauvegarde de la nuit, plus tous les WAL archivés jusqu'à juste avant la requête, dans un cluster à part. L'heure de la requête est dans le journal. On prend la requête exacte, sans `WHERE`, et sa première occurrence : d'autres `DELETE` ont pu être journalisés depuis, des essais par exemple, et viser l'un d'eux ferait restaurer après l'incident :

```bash
heure=$(grep 'statement: DELETE FROM commandes$' /var/log/postgresql/postgresql-17-main.log | head -1 | awk '{print $1, $2, $3}')
echo "$heure"
```

Avant de restaurer, vérifier que les archives vont jusque-là. Elles s'arrêtent au dernier segment de WAL rempli :

```bash
ls /srv/archives/wal | tail -1
runuser -u postgres -- psql -X -At -c "SELECT pg_walfile_name(pg_current_wal_lsn())"   # un segment plus loin
```

Le segment en cours n'est archivé que quand il est plein, et il contient les dernières minutes avant l'incident. Une restauration lancée maintenant s'arrêterait avant l'heure visée : `recovery ended before configured recovery target was reached`. On force donc le passage au segment suivant, ce qui archive celui-ci :

```bash
runuser -u postgres -- psql -X -At -c "SELECT pg_switch_wal()"
sleep 2
ls /srv/archives/wal | tail -1
```

Puis un cluster à côté, sur le port 5434, à partir de la sauvegarde de la nuit. Sa configuration est neuve : il n'archive rien, et ne risque pas d'écrire dans les archives de la prod. `recovery_target_inclusive = off` arrête le rejeu juste avant la requête. À la cible, le cluster se met en pause, lisible et en lecture seule :

```bash
pg_createcluster 17 restau --port 5434 >/dev/null
rm -rf /var/lib/postgresql/17/restau/*
runuser -u postgres -- tar xzf /srv/sauvegardes/base-*/base.tar.gz -C /var/lib/postgresql/17/restau
cat > /etc/postgresql/17/restau/conf.d/restauration.conf <<EOF
restore_command = 'cp /srv/archives/wal/%f %p'
recovery_target_time = '$heure'
recovery_target_inclusive = off
EOF
runuser -u postgres -- touch /var/lib/postgresql/17/restau/recovery.signal
pg_ctlcluster 17 restau start
until [[ $(runuser -u postgres -- psql -X -At -p 5434 -c "SELECT pg_get_wal_replay_pause_state()" 2>/dev/null) == paused ]]; do sleep 1; done
runuser -u postgres -- psql -X -p 5434 -d boutique -c "SELECT count(*), max(id), count(*) FILTER (WHERE client = 'test') AS tests FROM commandes"
```

Toutes les commandes jusqu'à l'incident, commandes de test comprises. Reste à réinjecter dans la prod tout sauf les tests, commandes puis paiements, dans une seule transaction : si la seconde copie échoue, la première est annulée, et on recommence proprement. Aucun conflit de clé à craindre : toutes ces lignes ont été supprimées de la prod, et les nouvelles commandes ont des identifiants plus grands :

```bash
runuser -u postgres -- psql -X -p 5434 -d boutique \
  -c "\copy (SELECT * FROM commandes WHERE client <> 'test') TO '/var/lib/postgresql/commandes.copy'" \
  -c "\copy (SELECT p.* FROM paiements p JOIN commandes c ON c.id = p.commande WHERE c.client <> 'test') TO '/var/lib/postgresql/paiements.copy'"
runuser -u postgres -- psql -X -d boutique -1 \
  -c "\copy commandes FROM '/var/lib/postgresql/commandes.copy'" \
  -c "\copy paiements FROM '/var/lib/postgresql/paiements.copy'"
runuser -u postgres -- psql -X -d boutique -c "SELECT count(*) FROM commandes" -c "SELECT count(*) FROM paiements"
```

La prod a retrouvé ses commandes, sans avoir été arrêtée. Le cluster de restauration s'arrête, mais on le garde jusqu'à la fin de l'analyse de l'incident :

```bash
pg_ctlcluster 17 restau stop
rm /var/lib/postgresql/commandes.copy /var/lib/postgresql/paiements.copy
```

Enfin, la console du support. Elle sert à corriger des commandes, pas à en supprimer :

```bash
runuser -u postgres -- psql -X -d boutique -c "REVOKE DELETE ON commandes, paiements FROM support"
```

Dernière étape, hors du serveur : prévenir la comptabilité et la logistique de l'intervalle à vérifier, entre l'incident et la réinjection, et demander une revue de la console du back-office.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Remettre la sauvegarde de la nuit à la place de la prod** : la boutique s'arrête, les commandes de la matinée manquent, et celles passées depuis l'incident sont effacées une seconde fois.
- **Restauration à un instant précis directement sur la prod** : les commandes de la matinée reviennent, mais il faut arrêter la boutique, et tout ce qui est arrivé depuis l'incident disparaît.
- **Restaurer sans `pg_switch_wal()`** : les dernières minutes avant l'incident ne sont pas dans les archives. PostgreSQL refuse de démarrer avant la cible (`recovery ended before configured recovery target was reached`), ou, avec une heure visée plus tôt, rend des données incomplètes sans prévenir.
- **Viser l'heure de la requête à la seconde près, ou à la minute** : on perd les commandes validées entre cette heure-là et la requête. Le journal donne la milliseconde, et `recovery_target_inclusive = off` exclut la requête elle-même.
- **Réinjecter commandes et paiements dans deux transactions séparées** : si la seconde échoue, la prod a des commandes sans paiement, et il faut démêler à la main.
- **Tout réinjecter, tests compris** : la base revient à l'identique, et il reste à refaire, cette fois correctement, la suppression demandée au départ.
- **Un cluster à côté, des archives complètes, une seule transaction, sans les tests** : la prod n'a jamais été arrêtée, rien n'est perdu ni dupliqué, et la demande initiale du support est faite.

</details>

## En prod

- Une sauvegarde qu'on n'a jamais restaurée n'est pas une sauvegarde. Restaurer à un instant précis, dans un cluster à part, au moins une fois par trimestre.
- `archive_timeout` borne l'âge du dernier segment non archivé, et donc ce qu'on perd si le serveur disparaît.
- `log_statement = 'mod'` donne l'heure exacte de chaque modification, et c'est souvent ce qui rend une restauration précise possible.
- Personne n'a besoin du droit `DELETE` sur les tables de production pour une console de support. Les suppressions passent par l'application, avec ses règles.
- `ON DELETE CASCADE` sur des données métier transforme une erreur en catastrophe. Le préférer pour les données qui n'ont pas de sens sans leur parent.
- Indexer la colonne d'une clé étrangère du côté enfant. Sans index sur `paiements(commande)`, chaque commande supprimée fait parcourir toute la table des paiements : ici, la requête a mis plusieurs secondes, et tenait ses verrous tout ce temps.
