# 30. Tout est tombé en même temps

## Le ticket

> **Ticket #5000, incident majeur**
> La campagne pré-Black Friday a démarré ce matin, et la boutique est tombée quelques minutes plus tard : erreur 500 sur toutes les pages. La supervision est entièrement rouge : PostgreSQL arrêté, disque de données plein, API en erreur, temps de réponse de nginx. Chaque équipe a déjà son explication, et ce ne sont pas les mêmes.
> Pour tester : `curl -X POST http://localhost/commandes` (une commande).
> Contraintes : aucune commande acceptée par la boutique ne doit être perdue. Le trafic de la campagne continue pendant l'intervention. Une fois le service rétabli, le post-mortem est attendu pour la revue de demain : `/root/post-mortem-5000.md`, à partir du modèle de l'entreprise (`/root/post-mortem-modele.md`).
> L'unité `lab-clients` simule les clients : n'y touche pas.

## Impact business

La campagne pré-Black Friday ouvre les jours les plus chargés de l'année. La publicité continue d'envoyer des clients vers une boutique fermée : chaque minute coûte des ventes, et le budget de la campagne. Une commande payée puis perdue coûterait plus cher encore : remboursement, service client, confiance. Et sans post-mortem clair, la même panne attend vendredi.

## Les enjeux

- Remonter la chaîne jusqu'au premier maillon, au lieu de traiter l'alerte la plus visible.
- Rétablir dans le bon ordre, sans perdre une commande, pendant que le trafic continue.
- Empêcher la rechute dans les minutes qui suivent.
- Écrire un post-mortem utile : des faits datés, des mécanismes, des actions.

## Ce qui est vérifié

- PostgreSQL tourne, et la boutique prend des commandes
- aucune commande acceptée par la boutique n'a été perdue
- l'API n'est plus en DEBUG
- le disque de données a de la marge (moins de 70 %), et 20 s de trafic ordinaire n'y écrivent presque rien
- le post-mortem (`/root/post-mortem-5000.md`) a les sept sections du modèle, remplies ; sa chronologie compte au moins quatre événements datés, dont l'arrêt de PostgreSQL ; sa cause racine remonte au changement qui a déclenché la chaîne ; il propose au moins trois actions

## Indices

<details><summary>Indice 1</summary>

Quatre alertes, une seule chaîne. Commence par ce qui est arrivé en premier : `/var/log/postgresql/`, `df -h`, `du -sh /srv/donnees/*`.

</details>

<details><summary>Indice 2</summary>

Pourquoi l'API écrit-elle autant ? Regarde son journal, puis sa configuration : `systemctl cat api`, et le fichier qu'elle lit.

</details>

<details><summary>Indice 3</summary>

Pour rendre de la place sur un fichier qu'un processus tient ouvert : `rm` ou `truncate` ? Et dans `pg_wal`, rien ne se supprime à la main.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -X POST http://localhost/commandes; echo           # {"erreur": "erreur interne"}
systemctl --failed --no-pager                              # postgresql@17-main.service failed
grep -m1 PANIC /var/log/postgresql/postgresql-17-main.log  # PANIC: could not write to file ...: No space left on device
df -h /srv/donnees                                         # 192M, 100 %
du -sh /srv/donnees/*                                      # logs 151M, postgresql 42M
grep -m1 DEBUG /srv/donnees/logs/api.log | cut -c1-120     # une requête, ses en-têtes, puis le résultat SQL entier
cat /etc/boutique/api.env                                  # LOG_LEVEL=DEBUG : ticket #4987, « à retirer demain matin »
ls -l --time-style='+%d/%m %H:%M' /etc/boutique/api.env    # hier soir, 18:05
```

Les alertes sont des conséquences. La chaîne, dans l'ordre : hier soir, le changement #4987 passe l'API en DEBUG, pour une nuit. Personne ne le retire. En DEBUG, chaque requête écrit une dizaine de Ko de journal, sur le disque de données, celui de PostgreSQL. Ce matin, le trafic de la campagne remplit le disque en moins d'une minute. PostgreSQL ne peut plus écrire, puis s'arrête. L'API répond 500, les clients réessaient, et chaque erreur écrit sa pile d'appels : le disque reste plein.

Avant de toucher à quoi que ce soit, on relève les heures dont le post-mortem aura besoin : la date de `api.env` va changer, et les journaux vont continuer d'avancer.

```bash
journal_pg=/var/log/postgresql/postgresql-17-main.log
debug=$(date -r /etc/boutique/api.env '+%d/%m à %H:%M')
debut=$(head -1 /var/log/nginx/access.log | sed -E 's/.*:([0-9]{2}:[0-9]{2}):[0-9]{2} .*/\1/')
plein=$(grep -m1 'No space left' "$journal_pg" | cut -c12-16)
panne=$(grep -m1 PANIC "$journal_pg" | cut -c12-16)
echo "DEBUG le $debug, campagne à $debut, disque plein à $plein, PostgreSQL arrêté à $panne"
```

On arrête d'abord ce qui remplit le disque, sinon la place rendue repartira en quelques minutes. L'API revient en INFO. On garde un extrait de son journal pour l'enquête, ailleurs que sur le disque plein, puis on vide le fichier. `rm` ne rendrait rien : l'API le tient ouvert, et la place ne revient qu'à sa fermeture. Dans `pg_wal`, rien ne se supprime : ce sont les commandes validées qui n'ont pas encore été écrites dans les tables.

```bash
sed -i 's/^LOG_LEVEL=DEBUG$/LOG_LEVEL=INFO/' /etc/boutique/api.env
tail -n 5000 /srv/donnees/logs/api.log > /root/api-incident-5000.log
truncate -s 0 /srv/donnees/logs/api.log
systemctl restart api
df -h /srv/donnees                                         # 22 %
```

PostgreSQL peut redémarrer. Il rejoue son WAL jusqu'à la dernière transaction validée : une commande acceptée par la boutique a été validée, elle revient.

```bash
systemctl restart postgresql@17-main
tail -3 /var/log/postgresql/postgresql-17-main.log         # redo done ... database system is ready to accept connections
curl -s -X POST http://localhost/commandes; echo           # {"commande": 2273}
retour=$(date +%H:%M)
```

Le post-mortem s'écrit maintenant, pendant que tout est frais, à partir du modèle et des heures relevées :

```bash
cat > /root/post-mortem-5000.md <<EOF
# Post-mortem : la boutique arrêtée au lancement de la campagne pré-Black Friday

Ticket : #5000. Sans recherche de coupable : des faits et des mécanismes, pas des personnes.

## Résumé

Au lancement de la campagne, le disque de données de srv-prod-01 s'est rempli en moins d'une minute avec les
journaux de l'API, restés en DEBUG depuis la veille. PostgreSQL, sur le même disque, s'est arrêté. Le service est
revenu après le retour de l'API en INFO, la purge de son journal et le redémarrage de PostgreSQL.

## Impact

Boutique indisponible de $plein à $retour : toutes les pages et toutes les commandes en erreur 500, en plein pic de
la campagne. Aucune commande acceptée n'a été perdue : PostgreSQL a rejoué son WAL jusqu'à la dernière transaction
validée.

## Chronologie

- $debug : changement #4987, l'API passe en DEBUG pour l'enquête sur les paniers vides, à retirer le lendemain matin.
- $debut : début de la campagne. En DEBUG, chaque requête écrit une dizaine de Ko de journal.
- $plein : disque de données plein. PostgreSQL refuse les écritures, les commandes échouent.
- $panne : PostgreSQL ne peut plus écrire son WAL et s'arrête (PANIC). Toutes les pages sont en erreur.
- $panne et après : les clients réessaient, chaque erreur écrit sa pile d'appels, le disque reste plein.
- $retour : API en INFO, journal vidé (extrait gardé), PostgreSQL redémarré. Les commandes passent de nouveau.

## Cause racine

Le DEBUG du changement #4987, prévu pour une nuit, est resté actif : rien n'imposait son retrait, et rien ne limitait
la taille du journal qu'il produisait.

## Causes contributives

- Les journaux de l'API et les données de PostgreSQL partagent le même disque : un journal qui gonfle arrête la base.
- La supervision alerte sur un disque plein, pas sur sa vitesse de remplissage : l'alerte est arrivée avec la panne.
- Le journal de l'API n'a ni rotation ni taille maximale.
- Les clients réessaient sans délai croissant : chaque erreur en appelle d'autres, et chacune écrit dans le journal.

## Ce qui a bien marché

- Aucune commande validée n'a été perdue : WAL intact, et récupération automatique de PostgreSQL.
- Le journal a été vidé sans supprimer le fichier ouvert, et un extrait a été gardé pour l'enquête.

## Actions

- Journaux de l'API hors du disque de données, avec rotation et taille maximale (équipe plateforme, avant vendredi).
- Tout passage en DEBUG en production porte une date de fin, et revient seul en INFO (équipe API, sous quinze jours).
- Alerte sur la vitesse de remplissage des disques, en plus du taux (supervision, sous quinze jours).
- Nouvelles tentatives des clients avec un délai croissant (équipe front, avant vendredi).
EOF
```

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Redémarrer PostgreSQL d'abord** : sans place, il ne démarre pas. Et s'il en trouve, le DEBUG la reprend en quelques minutes.
- **`rm` sur `api.log`** : l'API garde le fichier ouvert, la place ne revient pas tant qu'elle tourne. `lsof +L1` le montre.
- **Supprimer des fichiers dans `pg_wal`** : ce sont les commandes validées pas encore écrites dans les tables. La base en perd, ou ne redémarre plus.
- **Vider le journal sans couper le DEBUG** : avec le trafic de la campagne, le disque est de nouveau plein en quelques minutes.
- **Agrandir le disque** : utile ensuite, mais le journal rattrape n'importe quelle taille tant que le DEBUG reste.
- **Couper nginx pour arrêter le trafic** : le disque cesse de se remplir, et la boutique reste fermée en pleine campagne.
- **Un post-mortem écrit de mémoire, la semaine suivante** : les heures sont fausses, les journaux ont tourné, et la cause racine devient « le disque était plein ».
- **Couper la source, garder un extrait, vider le fichier, redémarrer la base, puis écrire le post-mortem avec les heures des journaux** : chaque maillon traité dans l'ordre, sans perte, et la revue de demain part des faits.

</details>

## En prod

- Une panne en cascade se lit dans l'ordre des horodatages, pas dans l'ordre des alertes : la première qui sonne est rarement le premier maillon.
- Journaux et données sur des disques séparés : un journal qui déborde ne doit pas pouvoir arrêter une base.
- Un changement « temporaire » sans date de fin est permanent. Le niveau de journalisation se remet seul à sa valeur, ou une alerte rappelle qu'il ne l'est pas.
- Pour rendre la place d'un fichier ouvert : `truncate`, ou `rm` puis redémarrage du programme. `lsof +L1` liste les fichiers supprimés encore ouverts.
- Ne jamais supprimer à la main dans `pg_wal`. PostgreSQL recycle lui-même ses segments, une fois la place revenue et le checkpoint passé.
- Le post-mortem s'écrit dans les jours qui suivent, sans coupable : des faits datés tirés des journaux, des mécanismes, des actions avec un responsable et une échéance.
