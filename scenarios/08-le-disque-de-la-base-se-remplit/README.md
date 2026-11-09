# 08. Le disque de la base primaire se remplit

## Le ticket

> **Ticket #4702, priorité haute**
> Alerte disque sur srv-prod-01, la base primaire de la boutique : le volume /srv/pg_wal est à 88 % et ne redescend pas. À 100 %, PostgreSQL s'arrête net, et ne redémarre pas tant qu'il n'a pas retrouvé de place.
> Déjà fait : un `CHECKPOINT` à la main, sans effet.
> La réplique de Lyon (ici le cluster 17/lyon, port 5433) est arrêtée depuis ce matin pour la mise à jour de son système. Elle repart ce soir et doit rattraper son retard par le flux de réplication : une reconstruction complète prendrait 12 heures sur le lien.
> Contraintes : le volume ne peut pas être agrandi avant la fenêtre de maintenance de samedi. Aucune perte de données, et la base reste en service.
> L'unité `lab-boutique` simule l'application : n'y touche pas.

## Impact business

Si le volume atteint 100 %, la boutique s'arrête : plus aucune commande n'est enregistrée, et la base refuse de redémarrer tant qu'on ne lui a pas rendu de la place. Dans la précipitation, la tentation sera de supprimer des fichiers, et une erreur à ce moment-là se paie en restauration depuis la sauvegarde. La réplique de Lyon sert les rapports de la direction : la perdre, c'est 12 heures de copie sur le lien inter-sites, et pas de rapports demain.

## Les enjeux

- Trouver ce qui retient les WAL alors que les points de contrôle passent.
- Distinguer ce qui ne sert plus de ce qui est seulement en pause.
- Libérer de la place sans toucher aux fichiers de pg_wal.
- Empêcher qu'un oubli de ce genre remplisse de nouveau le volume, sans condamner la réplique de Lyon.

## Ce qui est vérifié

Le check redémarre d'abord la base, comme samedi, puis fait un point de contrôle. Il vérifie :

- la base tourne et accepte les commandes
- le volume pg_wal n'a pas été agrandi (384 Mo)
- pg_wal est redescendu sous 60 %
- le slot de la réplique décommissionnée n'existe plus
- le slot de la réplique de Lyon est intact
- un slot ne peut plus retenir plus que la place libre (`max_slot_wal_keep_size`)

Si c'est bon, il relance la réplique de Lyon et vérifie qu'elle rattrape son retard par le flux. Puis il crée un slot de test qui décroche, et vérifie qu'au-delà du plafond ce slot est invalidé avant que le volume ne dépasse 92 %.

## Indices

<details><summary>Indice 1</summary>

`ls /srv/pg_wal | wc -l` donne le nombre de segments de 16 Mo, à comparer avec `max_wal_size`. PostgreSQL garde un segment tant que quelqu'un peut encore en avoir besoin. Qui ? Regarde `pg_stat_archiver`, puis `pg_replication_slots`.

</details>

<details><summary>Indice 2</summary>

`pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` donne ce que chaque slot retient. Deux slots sont inactifs : lequel attend une réplique qui reviendra ? `pg_lsclusters`, et ce qu'il y a dans /srv/doc.

</details>

<details><summary>Indice 3</summary>

`max_slot_wal_keep_size`. Fais le compte : la taille du volume, la place des WAL normaux (`max_wal_size`), et ce que la réplique de Lyon aura accumulé d'ici ce soir.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
df -h /srv/pg_wal                      # 88 %
ls /srv/pg_wal | wc -l                 # 24 segments de 16 Mo, pour un max_wal_size de 128 Mo
runuser -u postgres -- psql -X -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('max_wal_size', 'wal_keep_size', 'max_slot_wal_keep_size')"
runuser -u postgres -- psql -X -c "SELECT archived_count, failed_count FROM pg_stat_archiver"   # aucun échec : l'archivage ne retient rien
```

Trois fois plus de WAL que ce que `max_wal_size` laisse prévoir, et ce n'est pas l'archivage qui les garde. L'autre raison classique, ce sont les slots de réplication :

```bash
runuser -u postgres -- psql -X -c "SELECT slot_name, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retenu FROM pg_replication_slots"
pg_lsclusters                          # 17/lyon arrêté : c'est la maintenance du ticket
cat /srv/doc/inventaire-bases.md       # srv-secours-01 décommissionnée le 30 septembre, serveur rendu
```

Un slot garantit à sa réplique que le primaire garde chaque segment de WAL à partir de son `restart_lsn`, jusqu'à ce qu'elle confirme les avoir reçus. Avec `max_slot_wal_keep_size` à -1, la valeur par défaut, cette garantie n'a pas de limite : un slot dont la réplique ne reviendra jamais retient tout, pour toujours. `CHECKPOINT` ne supprime que les segments dont plus personne n'a besoin, d'où son absence d'effet.

Les deux slots sont inactifs, mais pas pour la même raison. `replica_lyon` attend une réplique qui repart ce soir et retient 82 Mo. `replica_secours` attend un serveur rendu en septembre et retient 317 Mo, presque tout le volume. C'est lui qu'on supprime, avec PostgreSQL, et pas en effaçant des fichiers :

```bash
runuser -u postgres -- psql -X -c "SELECT pg_drop_replication_slot('replica_secours')"
runuser -u postgres -- psql -X -c "CHECKPOINT"
df -h /srv/pg_wal                      # moins de la moitié
```

Reste à ce que l'oubli ne se reproduise pas. `max_slot_wal_keep_size` plafonne ce qu'un slot peut retenir. Au-delà, PostgreSQL invalide le slot (`wal_status` passe à `lost`) : la réplique concernée devra être reconstruite, mais le primaire ne tombe plus. Le chiffre se calcule : 384 Mo de volume, 128 Mo pour les WAL normaux, et un peu de marge. 200 Mo laissent largement de quoi tenir à Lyon, qui retient 82 Mo ce matin et n'en accumulera que quelques-uns par heure d'ici ce soir :

```bash
runuser -u postgres -- psql -X -c "ALTER SYSTEM SET max_slot_wal_keep_size = '200MB'" -c "SELECT pg_reload_conf()"
runuser -u postgres -- psql -X -c "SHOW max_slot_wal_keep_size"
```

`ALTER SYSTEM` écrit dans postgresql.auto.conf : le réglage survit au redémarrage de samedi, et ce paramètre se recharge sans redémarrer.

Dernière étape, hors du serveur : ajouter « supprimer son slot sur le primaire » à la procédure de décommissionnement des répliques. C'est cette ligne qui manquait en septembre.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Supprimer des fichiers dans pg_wal** : la place revient, et PostgreSQL ne sait pas que les segments ont disparu. Selon les fichiers effacés, rien ne casse tout de suite, ou Lyon demande ce soir des segments qui n'existent plus (`requested WAL segment has already been removed`, et 12 heures de reconstruction), ou le primaire ne retrouve plus son dernier point de contrôle et refuse de redémarrer. Personne ne sait lequel avant d'avoir essayé. Le check redémarre la base et relance Lyon.
- **`pg_archivecleanup` sur pg_wal** : l'outil sert à nettoyer un dossier d'archives, pas le pg_wal d'une base en service. Même résultat que l'effacement à la main.
- **Un autre `CHECKPOINT`** : il ne supprime que ce que personne ne retient. Les slots retiennent.
- **Agrandir le volume** : interdit avant samedi, et le slot abandonné le remplirait de nouveau.
- **Supprimer tous les slots** : la place revient d'un coup, et Lyon ne pourra plus rattraper son retard. Une maintenance de routine se transforme en reconstruction de 12 heures.
- **`max_slot_wal_keep_size` sans supprimer le slot** : le slot abandonné est invalidé au point de contrôle suivant, et la place revient. Mais il reste listé, `wal_status` à `lost`, et trompera le prochain qui regardera. Il ne sert à personne : autant le supprimer.
- **Un plafond trop bas, 32 Mo par exemple** : c'est le slot de Lyon qui est invalidé, dès le prochain point de contrôle. Même résultat que de le supprimer.
- **Supprimer le slot abandonné et poser un plafond calculé** : la place revient tout de suite, Lyon rattrape son retard ce soir, et le prochain slot oublié coûtera une réplique, pas la base.

</details>

## En prod

- Superviser `pg_replication_slots` : ce que retient chaque slot, et depuis combien de temps il est inactif. Un slot inactif depuis plus d'une journée doit déclencher une alerte.
- Toujours régler `max_slot_wal_keep_size` (PostgreSQL 13 et plus), dimensionné avec le volume de pg_wal.
- Mettre pg_wal sur son propre volume, avec une alerte vers 70 % : le jour où il se remplit, la base s'arrête, mais les données restent intactes sur leur volume.
- Décommissionner une réplique, c'est aussi supprimer son slot sur le primaire. Le noter dans la procédure.
- Ne jamais toucher aux fichiers de pg_wal à la main.
