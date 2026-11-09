# 10. « remaining connection slots are reserved »

## Le ticket

> **Ticket #4731, priorité critique**
> Depuis ce matin, la boutique renvoie des erreurs, de plus en plus souvent, puis en continu : `FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute`. Le DBA de garde, lui, arrive à se connecter.
> Hier, la version 2.3 de l'export des factures (le worker `export-factures`) a été mise en production.
> Le développeur de garde propose de passer `max_connections` de 40 à 500.
> Contraintes : `max_connections` est dimensionné sur la mémoire du serveur, on n'y touche pas. L'export des factures doit continuer de tourner, la comptabilité clôture ce soir. Le code du worker appartient à l'équipe facturation, qui livre un correctif jeudi.
> Les unités `lab-*` simulent l'application : n'y touche pas.

## Impact business

Plus aucune commande ne passe, et chaque redémarrage n'achète que quelques minutes avant la rechute. La solution proposée par le développeur demande un redémarrage de la base, et expose le serveur à manquer de mémoire au premier pic. Et si l'export s'arrête, la clôture comptable de ce soir glisse au mois suivant.

## Les enjeux

- Lire ce que dit vraiment le message : il ne reste que les places réservées aux superutilisateurs.
- Trouver qui occupe les autres, et pourquoi elles ne se libèrent pas.
- Protéger la boutique sans arrêter le worker fautif, ni attendre son correctif.
- Garder l'export en vie jusqu'à jeudi, même plus lent.

## Ce qui est vérifié

- `max_connections` n'a pas bougé (40)
- l'application ouvre 20 connexions simultanées
- le rôle `factures` est plafonné (15 connexions au plus)
- une connexion inactive du rôle `factures` est coupée en 2 minutes au plus
- l'export des factures tourne

Si c'est bon, le check envoie une rafale de 100 factures à exporter, et vérifie que l'application garde ses connexions pendant que le worker les traite, puis que l'export avance toujours.

## Indices

<details><summary>Indice 1</summary>

`max_connections` et `superuser_reserved_connections` : combien de places pour qui ? Puis `pg_stat_activity`, regroupé par `usename` et `state`.

</details>

<details><summary>Indice 2</summary>

Lis la fonction `connexion()` du worker. À quoi sert la liste, et qui la vide ?

</details>

<details><summary>Indice 3</summary>

`ALTER ROLE ... CONNECTION LIMIT`, et `idle_session_timeout` (PostgreSQL 14 et plus). Un réglage de rôle s'applique à l'ouverture de la session.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
tail -1 /var/log/boutique/erreurs.log      # remaining connection slots are reserved for roles with the SUPERUSER attribute
runuser -u postgres -- psql -X -At -c "SHOW max_connections" -c "SHOW superuser_reserved_connections"   # 40, dont 3 réservées
runuser -u postgres -- psql -X -c "SELECT usename, state, count(*), date_trunc('second', max(now() - state_change)) AS plus_ancienne FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1, 2 ORDER BY 3 DESC"
```

Sur 40 connexions, 3 sont réservées aux superutilisateurs : c'est par elles que le DBA entre. Les 37 autres sont toutes prises par le rôle `factures`, et toutes inactives. Le worker n'a rien à faire avec 37 connexions, il ne traite qu'une facture à la fois :

```bash
systemctl status export-factures --no-pager | head -4
grep -n -B3 -A4 'def connexion' /usr/local/bin/export-factures
```

Chaque lot ouvre une connexion et l'ajoute à une liste « pour les lots suivants ». Mais aucun lot ne reprend une connexion de la liste, et rien ne la vide. Python ne ferme une connexion que quand plus rien ne la référence, et la liste les référence toutes : elles restent ouvertes, inactives, jusqu'à occuper toutes les places ordinaires. `with c:` ne change rien : avec psycopg2, ce bloc valide la transaction, il ne ferme pas la connexion.

Le correctif du code arrive jeudi. D'ici là, deux réglages sur le rôle du worker, posés avant de le redémarrer pour que ses nouvelles sessions en héritent :

```bash
runuser -u postgres -- psql -X -c "ALTER ROLE factures CONNECTION LIMIT 10" -c "ALTER ROLE factures SET idle_session_timeout = '30s'"
systemctl restart export-factures
sleep 3
runuser -u postgres -- psql -X -c "SELECT usename, count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1"
journalctl -u export-factures -o cat -n 3   # des « too many connections for role », et les factures continuent
```

`CONNECTION LIMIT 10` est un plafond dur : quel que soit son bug, le worker ne prendra jamais plus de 10 places, et il en reste 27 pour la boutique. `idle_session_timeout` coupe une session restée inactive 30 secondes : les connexions abandonnées dans la liste disparaissent d'elles-mêmes, et le worker peut en rouvrir. Il exporte maintenant par à-coups, plus lentement, mais il exporte, et la clôture de ce soir aura ses factures.

Dernière étape, hors du serveur : envoyer à l'équipe facturation la ligne fautive, et l'explication sur `with c:`. Une seule connexion réutilisée, ou un vrai pool de connexions, et les deux réglages ne serviront plus que de filet.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Passer `max_connections` à 500** : il faut redémarrer la base, et chaque connexion peut consommer `work_mem` plusieurs fois. Le serveur risque de manquer de mémoire au premier pic, et la fuite remplit 500 places comme elle a rempli 37 : juste plus tard.
- **Redémarrer PostgreSQL** : tout se libère, la boutique tombe pendant le redémarrage, et la fuite recommence aussitôt.
- **Redémarrer seulement le worker, ou couper ses sessions avec `pg_terminate_backend`** : la boutique respire quelques secondes. Ici, la fuite reprend les 37 places en moins de 10 secondes.
- **Poser les deux réglages sans redémarrer le worker** : rien ne change. Un réglage de rôle s'applique à l'ouverture d'une session, et les 37 sessions de la fuite sont déjà ouvertes.
- **`CONNECTION LIMIT` seul** : la boutique est protégée, mais le worker reste coincé avec ses 10 connexions inactives, qu'il ne réutilise jamais. L'export s'arrête jusqu'à jeudi.
- **`idle_session_timeout` seul** : en temps normal, les connexions abandonnées sont coupées assez vite. Mais une rafale de factures en ouvre des dizaines en quelques secondes, bien avant que le délai ne passe, et la boutique retombe.
- **Arrêter le worker jusqu'à jeudi** : la boutique repart, et la clôture comptable n'a pas ses factures.
- **Un plafond et un délai d'inactivité sur le rôle du worker** : la boutique garde ses places quoi que fasse le worker, et l'export continue, plus lentement, jusqu'au correctif.

</details>

## En prod

- Un rôle par application et par worker, avec un `CONNECTION LIMIT`. Une fuite dans un composant ne doit pas pouvoir priver les autres.
- Superviser les connexions par rôle et par état, contre `max_connections`. Des dizaines de sessions `idle` pour un worker qui traite une chose à la fois, c'est une fuite.
- `idle_session_timeout` pour les rôles des batchs et des workers. Pas pour les rôles d'un pool de connexions, qui garde exprès ses sessions ouvertes.
- Devant une application qui ouvre beaucoup de connexions courtes, un pooler comme PgBouncer.
- Garder `superuser_reserved_connections` : ce sont ces places qui ont permis de diagnostiquer.
