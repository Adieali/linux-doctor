# 09. Une migration fige toute la prod

## Le ticket

> **Ticket #4718, priorité critique**
> Depuis le lancement du déploiement 2.14, il y a quelques minutes, la boutique est figée : les pages tournent dans le vide, sans erreur, et plus aucune commande n'est enregistrée. CPU et disque au repos. PostgreSQL répond à `SELECT 1`.
> La 2.14 contient une seule migration, « triviale » d'après l'équipe : un `ADD COLUMN` sans valeur par défaut, 0,2 seconde en préproduction.
> Le développeur de garde propose de redémarrer PostgreSQL.
> Contraintes : la migration fait partie de la 2.14, elle doit passer. Aucune commande ne doit être perdue. L'application ne doit jamais attendre plus de 3 secondes, déploiements compris. Le rapport de stock horaire vers l'ERP continue de partir.
> Les unités `lab-*` simulent le reste (application, ERP) : n'y touche pas.

## Impact business

Chaque minute de gel, ce sont des commandes perdues et des clients qui partent, avec en prime des paniers figés que le support devra rattraper à la main. Le redémarrage proposé couperait aussi les transactions en cours, et rien ne dit que le prochain déploiement ne refigera pas tout. L'équipe va vouloir annuler la 2.14 « par prudence » : c'est une version de retard, et la même panne au prochain essai.

## Les enjeux

- Comprendre pourquoi une migration de 0,2 seconde bloque tout, alors qu'elle n'a même pas commencé.
- Remonter la chaîne d'attente jusqu'à celui qui bloque vraiment.
- Débloquer sans redémarrer la base et sans annuler la version.
- Faire en sorte qu'un déploiement ne puisse plus figer la boutique, quoi qu'il arrive au rapport.

## Ce qui est vérifié

- l'application répond en moins d'une seconde
- la migration 0042 de la version 2.14 est passée
- plus aucune session de rapport ne reste en transaction
- aucun rapport n'est resté bloqué en cours d'exécution
- le rapport de stock part toujours chaque heure
- une session de rapport inactive en transaction est coupée en 15 minutes au plus

Si c'est bon, le check relance le rapport de l'heure, qui se bloque de nouveau sur l'ERP, puis lance un nouveau déploiement avec une migration. Il vérifie que l'application n'attend jamais plus de 3 secondes pendant ce temps.

## Indices

<details><summary>Indice 1</summary>

`pg_stat_activity` montre qui attend (`wait_event_type`) et depuis quand (`xact_start`). Trie par début de transaction : qui était là le premier ?

</details>

<details><summary>Indice 2</summary>

`pg_blocking_pids(pid)` donne, pour chaque session qui attend, celles qui la bloquent. Suis la chaîne jusqu'au bout. Pourquoi un `SELECT`, compatible avec une autre lecture, attend-il quand même ?

</details>

<details><summary>Indice 3</summary>

`lock_timeout` et `idle_in_transaction_session_timeout`, et `ALTER ROLE ... SET` pour qu'ils ne s'appliquent qu'à qui en a besoin.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
tail -3 /var/log/boutique/acces.log         # la dernière commande date du lancement du déploiement
runuser -u postgres -- psql -X -d boutique -c "SELECT pid, usename, state, wait_event_type AS attente, date_trunc('second', now() - xact_start) AS depuis, left(query, 50) AS requete FROM pg_stat_activity WHERE datname = 'boutique' AND pid <> pg_backend_pid() ORDER BY xact_start"
```

Toutes les sessions actives attendent un verrou (`Lock`), la migration comme l'application. La plus ancienne transaction n'attend rien : une session du rôle `rapports`, `idle in transaction`. Qui bloque qui :

```bash
runuser -u postgres -- psql -X -d boutique -c "SELECT pid, usename, pg_blocking_pids(pid) AS bloque_par, left(query, 40) AS requete FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0"
```

L'application est bloquée par la migration, et la migration par le rapport. `ALTER TABLE ... ADD COLUMN` est quasi instantané, mais il demande un verrou `ACCESS EXCLUSIVE`, incompatible avec tout, y compris avec le verrou `ACCESS SHARE` que le rapport a pris en lisant `commandes`. La migration se met donc dans la file. Et PostgreSQL sert les verrous dans l'ordre d'arrivée : un `SELECT` de l'application serait compatible avec le rapport, mais pas avec la migration qui attend devant lui. Il se range derrière elle. Une transaction oubliée et une migration de 0,2 seconde suffisent à figer toute la table.

Pourquoi le rapport ne finit pas :

```bash
systemctl status rapport-stock --no-pager | head -12     # activating : en cours depuis le début du rapport
ps -o pid,etime,args -C curl                             # l'appel à l'ERP attend toujours
cat /usr/local/bin/rapport-stock                         # BEGIN, lecture, appel à l'ERP, COMMIT
```

Le rapport ouvre une transaction, lit les ventes, puis appelle l'ERP avant de valider. L'ERP accepte la connexion et ne répond plus, et `curl` n'a pas de délai d'expiration : la transaction reste ouverte indéfiniment, avec son verrou.

Arrêter le service du rapport, plutôt que de seulement couper sa session dans PostgreSQL. `psql` s'arrête, sa transaction est annulée, et le verrou tombe. Couper la session seule laisserait `curl` bloqué, le service en `activating`, et le timer ne relancerait plus aucun rapport tant qu'il le reste :

```bash
systemctl stop rapport-stock
sleep 1
systemctl status migration --no-pager | grep -E 'Active|Migration'   # terminée
tail -2 /var/log/boutique/acces.log                                  # les commandes repartent
```

La 2.14 est passée, en une fraction de seconde. Reste à empêcher la prochaine fois, avec deux délais qui ne s'appliquent qu'aux rôles concernés :

```bash
runuser -u postgres -- psql -X -c "ALTER ROLE deploiement SET lock_timeout = '2s'" -c "ALTER ROLE rapports SET idle_in_transaction_session_timeout = '5min'"
mkdir -p /etc/systemd/system/rapport-stock.service.d
cat > /etc/systemd/system/rapport-stock.service.d/delai.conf <<'EOF'
# Ticket #4718 : un rapport bloqué par l'ERP ne doit pas empêcher les suivants de partir.
[Service]
TimeoutStartSec=15min
EOF
systemctl daemon-reload
```

`lock_timeout` à 2 secondes : une migration qui n'obtient pas son verrou à temps échoue, au lieu de figer la boutique. Le pipeline affiche un déploiement en échec, qu'on relance quelques minutes plus tard : c'est infiniment moins grave qu'une boutique arrêtée. Pendant ces 2 secondes, l'application attend derrière la migration, d'où un délai sous les 3 secondes du ticket. `idle_in_transaction_session_timeout` à 5 minutes : une session de rapport qui ne fait plus rien au milieu d'une transaction est coupée, et ses verrous avec. Et `TimeoutStartSec` empêche un rapport bloqué d'empêcher les suivants de partir.

Dernière étape, hors du serveur : demander à l'équipe des rapports un `--max-time` sur `curl`, et l'appel à l'ERP après le `COMMIT`, pas pendant la transaction.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Arrêter le pipeline de déploiement** : ne débloque rien. Le `psql` de la migration meurt, mais sa session reste dans la file d'attente des verrous : par défaut, PostgreSQL ne vérifie pas pendant une requête que son client est toujours là.
- **Annuler la migration avec `pg_cancel_backend`** : la boutique repart, mais la 2.14 n'est pas déployée. Le prochain essai refigera tout tant que le rapport attend l'ERP.
- **Redémarrer PostgreSQL** : tout se débloque, en coupant toutes les connexions et les commandes en cours. Le service du rapport reste bloqué sur `curl`, et le prochain déploiement qui tombe sur un rapport refige la boutique.
- **`pg_terminate_backend` sur la session du rapport** : la file se vide, mais `curl` reste bloqué, et le service avec : plus aucun rapport ne part tant que personne ne l'arrête.
- **`lock_timeout` seul** : la boutique ne gèle plus, mais chaque déploiement échoue tant qu'un rapport est bloqué, sans fin si l'ERP ne revient pas.
- **`idle_in_transaction_session_timeout` seul** : la session du rapport est coupée au bout de 5 minutes. D'ici là, un déploiement qui tombe dessus fige la boutique pendant 5 minutes.
- **`statement_timeout` sur l'application** : les requêtes échouent au lieu d'attendre. La boutique répond, avec des erreurs.
- **Les mêmes délais dans postgresql.conf, pour tout le monde** : ça marche aussi. Le réglage par rôle laisse aux sessions d'administration le temps de travailler.
- **Arrêter le rapport bloqué, et un délai par rôle** : la 2.14 passe sans redémarrage ni annulation, et ni un rapport bloqué ni un déploiement ne peuvent plus figer la boutique.

</details>

## En prod

- Toute migration devrait tourner avec un `lock_timeout` court et une relance. Une migration « instantanée » peut figer une table entière, juste en attendant son verrou.
- Superviser les transactions ouvertes depuis longtemps (`now() - xact_start` dans `pg_stat_activity`), et tout particulièrement les `idle in transaction`.
- Jamais d'appel externe pendant une transaction : on lit, on valide, puis on appelle.
- Tout appel réseau a un délai d'expiration. Un `curl` sans `--max-time` attend aussi longtemps que le serveur d'en face le décide.
- Avant un déploiement avec migration, regarder `pg_stat_activity`. Une transaction ouverte depuis une heure, c'est le prochain gel.
