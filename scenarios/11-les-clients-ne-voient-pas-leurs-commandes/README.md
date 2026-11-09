# 11. Les clients ne voient pas leurs commandes

## Le ticket

> **Ticket #4744, priorité haute**
> Depuis ce matin, des clients écrivent au support : ils passent commande, reçoivent le mail de confirmation, mais la commande n'apparaît pas dans « Mes commandes ». Les commandes sont pourtant en base : le support les voit dans le back-office.
> La sonde de supervision de la réplication est verte (`sonde-replication`).
> Cette nuit, l'extraction mensuelle pour l'audit a tourné sur la réplique de lecture, sans son montage /srv/audit, absent depuis une maintenance du NAS.
> Contraintes : les lectures des clients restent sur la réplique, le primaire est déjà chargé. Mais un client doit voir ses commandes même si la réplique prend du retard : 10 secondes de décalage au plus. L'auditeur attend son extraction, elle doit pouvoir être relancée.
> L'unité `lab-clients` simule les clients : n'y touche pas.

## Impact business

Un client qui ne voit pas sa commande la repasse, ou appelle le support, ou les deux. Les doublons partent en préparation, les appels saturent le support, et chaque correction coûte un remboursement ou un retour. La supervision étant verte, personne côté technique ne cherche, et le problème dure jusqu'à ce que le support remonte assez de plaintes.

## Les enjeux

- Comprendre comment une réplication peut être « en flux » et ne plus rien mettre à jour.
- Ne pas croire la sonde : vérifier ce qu'elle mesure vraiment.
- Remonter jusqu'à ce qui a arrêté la réplique, et le rendre impossible.
- Protéger les clients du prochain retard de la réplique, quelle qu'en soit la cause.

## Ce qui est vérifié

- la réplique rejoue les WAL du primaire en moins de 2 secondes
- une commande passée apparaît aussitôt dans « Mes commandes »
- l'API tolère 10 secondes de retard de la réplique au plus (`retard_max_lecture`)
- l'extraction pour l'audit tourne toujours chaque mois

Si c'est bon, le check relance l'extraction sans son montage, puis avec. Il vérifie qu'une extraction ratée ne laisse pas le rejeu en pause, et qu'une extraction réussie produit son fichier. Enfin il met lui-même le rejeu en pause, comme une réplique qui décroche, et vérifie qu'un client voit quand même sa nouvelle commande.

## Indices

<details><summary>Indice 1</summary>

Sur le primaire, `pg_stat_replication` donne plusieurs positions : envoyé, écrit, vidé sur disque, rejoué. La sonde regarde laquelle ?

</details>

<details><summary>Indice 2</summary>

Sur la réplique : `pg_last_wal_receive_lsn()`, `pg_last_wal_replay_lsn()`, `pg_get_wal_replay_pause_state()`. Puis `journalctl -u extraction-audit`, et le script lui-même.

</details>

<details><summary>Indice 3</summary>

`trap ... EXIT` en bash. Et dans /etc/boutique/api.ini, un réglage que personne n'a activé.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -X POST 'http://127.0.0.1:8000/api/commandes?client=client-42'                  # {"commande": ...}
curl -s http://127.0.0.1:8000/api/clients/client-42/commandes | tr ',' '\n' | tail -1   # pas celle-là
sonde-replication                                                                       # OK - réplication streaming
runuser -u postgres -- psql -X -c "SELECT application_name, state, sent_lsn, flush_lsn, replay_lsn FROM pg_stat_replication"
```

La réplique est connectée et reçoit tout : `sent_lsn` et `flush_lsn` suivent le primaire. Mais `replay_lsn` ne bouge plus. Une réplique fait deux choses distinctes : elle reçoit les WAL et les écrit sur son disque, puis elle les rejoue dans ses fichiers de données. Les lectures ne voient que ce qui a été rejoué. Côté réplique :

```bash
runuser -u postgres -- psql -X -p 5433 -c "SELECT pg_get_wal_replay_pause_state() AS rejeu, pg_last_wal_receive_lsn() AS recu, pg_last_wal_replay_lsn() AS rejoue, date_trunc('second', now() - pg_last_xact_replay_timestamp()) AS retard"
journalctl -u extraction-audit -o cat --no-pager | tail -3     # pg_dump : /srv/audit n'existe pas
cat /usr/local/bin/extraction-audit
```

Le rejeu est en pause depuis cette nuit. L'extraction le met en pause avant `pg_dump`, pour qu'un dump long ne soit pas annulé par un conflit avec la réplication, puis le relance à la fin. Cette nuit, `pg_dump` a échoué faute de montage, `set -e` a arrêté le script, et la ligne qui relance le rejeu n'a jamais été exécutée. Une pause du rejeu n'arrête pas la réception des WAL : la connexion reste `streaming`, et la sonde, qui ne regarde que cet état, reste verte.

D'abord rendre aux clients leurs commandes :

```bash
runuser -u postgres -- psql -X -p 5433 -c "SELECT pg_wal_replay_resume()"
sleep 1
curl -s http://127.0.0.1:8000/api/clients/client-42/commandes | tr ',' '\n' | tail -1   # elle y est
```

Puis rendre au script sa remise en état, quoi qu'il arrive au dump. Le `trap` se pose avant la pause : relancer un rejeu qui n'est pas en pause ne fait rien de mal. `INT` et `TERM` sont convertis en sortie, pour que l'arrêt du service relance aussi le rejeu :

```bash
cat > /usr/local/bin/extraction-audit <<'EOF'
#!/bin/bash
# Extraction mensuelle pour l'audit : les commandes, prises sur la réplique de lecture.
# Le rejeu est mis en pause pendant pg_dump : sinon, au-delà de max_standby_streaming_delay,
# un conflit avec la réplication annule le dump au bout de 30 secondes.
# Ticket #4744 : quoi qu'il arrive au dump, le rejeu repart à la sortie du script.
set -euo pipefail
trap 'psql -X -q -p 5433 -c "SELECT pg_wal_replay_resume()"' EXIT
trap 'exit 1' INT TERM
psql -X -q -p 5433 -c "SELECT pg_wal_replay_pause()"
pg_dump -p 5433 -d boutique -t commandes -f "/srv/audit/commandes-$(date +%F).sql"
EOF
```

Cette fois c'était l'extraction. La prochaine fois, ce sera une réplique en retard pour une autre raison : une pointe d'écriture, un disque lent, un lien saturé. L'API a déjà la protection, désactivée : au-delà d'un retard donné, elle lit sur le primaire. 5 secondes laissent de la marge sous les 10 du ticket, et une réplique en bonne santé reste sous la seconde :

```bash
sed -i 's/^retard_max_lecture = 0$/retard_max_lecture = 5/' /etc/boutique/api.ini
systemctl restart app-boutique
```

Enfin, une sonde qui regarde ce que voient les clients, pas seulement la connexion :

```bash
cat > /usr/local/bin/sonde-replication <<'EOF'
#!/bin/bash
# Sonde de supervision : la réplique de lecture (17/lecture) reçoit les WAL du primaire, et les rejoue.
q() { runuser -u postgres -- psql -X -At "$@"; }
etat=$(q -c "SELECT state FROM pg_stat_replication WHERE application_name = '17/lecture'")
if [[ $etat != streaming ]]; then echo "CRITICAL - réplication ${etat:-absente}"; exit 2; fi
rejeu=$(q -p 5433 -c "SELECT pg_get_wal_replay_pause_state()")
if [[ $rejeu != 'not paused' ]]; then echo "CRITICAL - rejeu $rejeu sur la réplique"; exit 2; fi
ecart=$(q -c "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint FROM pg_stat_replication WHERE application_name = '17/lecture'")
if (( ecart > 64 * 1024 * 1024 )); then echo "WARNING - $(( ecart / 1048576 )) Mo reçus, pas encore rejoués"; exit 1; fi
echo "OK - réplication $etat, rejeu à jour"
EOF
sonde-replication
```

Dernière étape, hors du serveur : relancer l'extraction quand le montage du NAS sera revenu, et prévenir l'auditeur du retard.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Vider le cache de l'application, ou la redémarrer** : la commande n'est dans aucun cache. Elle n'existe pas encore sur la base où l'API la cherche.
- **Envoyer toutes les lectures sur le primaire** : les clients retrouvent leurs commandes, et le primaire, déjà chargé, encaisse toute la lecture de la boutique.
- **Redémarrer la réplique** : la pause ne survit pas au redémarrage, le rejeu repart, en coupant les lectures en cours. Et la prochaine extraction ratée recommencera.
- **Relancer l'extraction à la main, une fois le NAS revenu** : elle se termine, relance le rejeu en passant, et l'auditeur a son fichier. Le script reste aussi fragile.
- **`pg_wal_replay_resume()` seul** : les clients retrouvent leurs commandes aujourd'hui. Le mois prochain, la même extraction ratée refera la même chose, et la sonde ne verra toujours rien.
- **Remplacer la pause par `hot_standby_feedback`** : le dump n'est plus annulé, sans arrêter le rejeu, mais le primaire garde ses lignes mortes tant que le dump tourne. Une piste à discuter, pas un changement à faire en urgence.
- **Relancer le rejeu, un `trap` dans le script, la garde de retard dans l'API, et une sonde qui regarde le rejeu** : les clients voient leurs commandes, l'extraction ne peut plus figer la réplique, et le prochain retard, quelle que soit sa cause, se voit et ne touche plus les clients.

</details>

## En prod

- Superviser le rejeu, pas seulement la connexion : `pg_get_wal_replay_pause_state()`, l'écart entre `sent_lsn` et `replay_lsn`, l'âge de la dernière transaction rejouée.
- Tout script qui met un système dans un état anormal (pause, maintenance, verrou) le remet en état dans un `trap ... EXIT`.
- Lire sur une réplique demande un seuil de retard (routage applicatif, `delay_threshold` de Pgpool-II), et la lecture de ses propres écritures sur le primaire juste après les avoir faites.
- Un job qui a besoin d'un montage le déclare : `RequiresMountsFor=` dans son unité, et il échoue avant de commencer au lieu d'échouer au milieu.
- Une sonde verte ne prouve que ce qu'elle mesure. Lire son code au moins une fois.
