# 17. Une commande sur trois échoue, et tous les serveurs sont verts

## Le ticket

> **Ticket #4823, priorité critique**
> Depuis 10 h, environ une commande sur trois échoue : le client reçoit « erreur interne » (500), il réessaie, et ça passe en général au deuxième ou au troisième essai. Les trois serveurs d'application sont verts dans les stats de HAProxy, et la base répond.
> Le dev de garde a vu des erreurs « pool de connexions épuisé » dans les logs d'app2. Il enquête et demande qu'on n'arrête ni ne redémarre app2 : il veut garder son état pour comprendre.
> Pour tester : `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost/api/commande`, plusieurs fois.
> Contraintes : HAProxy se recharge, il ne redémarre pas. Ce soir, personne n'est d'astreinte : un serveur qui tombe malade doit sortir du pool en moins de 10 secondes, et y revenir seul une fois réparé.
> Les unités `lab-app@1`, `lab-app@2` et `lab-app@3` simulent les serveurs d'application, et leur état est dans `/run/labo` : n'y touche pas.

## Impact business

Une commande sur trois échoue au premier essai. Une partie des clients réessaie, les autres abandonnent leur panier, et chaque échec pèse sur le taux de conversion du jour. Le support reçoit des captures d'écran d'« erreur interne » sans pouvoir rien en faire. Et comme les stats de HAProxy sont vertes, l'équipe système renvoie le ticket aux devs, qui le renvoient à l'équipe système.

## Les enjeux

- Comprendre pourquoi HAProxy envoie du trafic à un serveur qui ne sait plus le traiter.
- Soulager les clients tout de suite, sans arrêter app2.
- Faire décider HAProxy sur ce qui compte vraiment : un serveur capable de servir, pas un port ouvert.
- Tenir la nuit sans personne : sortir un serveur malade, et le faire revenir, sans intervention.

## Ce qui est vérifié

- HAProxy a été rechargé, pas redémarré
- app2 tourne toujours, pour l'enquête des devs
- 60 commandes de suite, sans une erreur
- app2, malade, ne reçoit plus aucune commande

Si c'est bon, le check fait perdre sa base à app3, puis répare celle d'app2, et vérifie :

- 10 s plus tard, 60 commandes passent sans erreur
- app3, malade, ne reçoit plus aucune commande
- 10 s plus tard, app2 reçoit de nouveau des commandes

## Indices

<details><summary>Indice 1</summary>

Les logs de HAProxy disent quel serveur a répondu à chaque requête : `journalctl -u haproxy`. Et son API runtime dit comment il juge chaque serveur : `echo "show stat" | socat stdio /run/haproxy/admin.sock`, colonnes `status` et `check_status`.

</details>

<details><summary>Indice 2</summary>

Un check `L4OK` prouve qu'une connexion TCP s'ouvre. Qu'est-ce qu'app2 sait encore faire ? Les devs ont laissé un mode d'emploi : `/srv/app/LISEZMOI`.

</details>

<details><summary>Indice 3</summary>

L'API runtime agit tout de suite, sans rechargement : `set server <backend>/<serveur> state ...`. Mais elle ne survit pas au prochain rechargement, et ne fait rien revenir toute seule.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
for i in $(seq 9); do curl -s -o /dev/null -w '%{http_code} ' -X POST http://localhost/api/commande; done; echo   # 201 201 500 201 201 500...
journalctl -u haproxy -o cat | grep ' 500 ' | tail -2       # app/app2 à chaque 500
```

Une commande sur trois, toujours la même : la répartition tourne entre app1, app2 et app3, et chaque passage par app2 échoue. Ce qu'en pense HAProxy :

```bash
echo "show stat" | socat stdio /run/haproxy/admin.sock | awk -F, 'NR == 1 {for (i = 1; i <= NF; i++) c[$i] = i; next} $1 == "app" {print $2, $c["status"], $c["check_status"], $c["hrsp_5xx"]}'
```

app2 est `UP`, avec un check `L4OK` : HAProxy ouvre une connexion TCP, elle s'établit, il en conclut que le serveur va bien. Pendant ce temps, app2 a déjà renvoyé des dizaines de 500. Ce qu'app2 sait encore faire :

```bash
cat /srv/app/LISEZMOI
curl -s http://127.0.0.1:8082/sante                          # {"processus": "ok"}
curl -s http://127.0.0.1:8082/pret                           # {"base": "pool de connexions épuisé"}, en 503
journalctl -u lab-app@2 -o cat | tail -1                     # ERREUR base : pool de connexions épuisé
```

Le processus répond, sa base non. Deux URL de santé, deux questions différentes : `/sante` demande si le processus est vivant (« liveness »), `/pret` s'il peut servir (« readiness »). Un répartiteur de charge a besoin de la seconde. Un check HTTP sur `/sante` mentirait autant que le check TCP.

D'abord, soulager les clients, sans arrêter app2 et sans recharger : l'API runtime retire app2 du pool. En `drain`, il ne reçoit plus de nouvelles requêtes, et celles en cours se terminent.

```bash
echo "set server app/app2 state drain" | socat stdio /run/haproxy/admin.sock
for i in $(seq 9); do curl -s -o /dev/null -w '%{http_code} ' -X POST http://localhost/api/commande; done; echo   # que des 201
```

Ce n'est qu'un pansement. L'état posé par l'API runtime est oublié au prochain rechargement, il ne fait rien revenir quand app2 sera réparé, et ce soir, quand un autre serveur tombera, personne ne sera là pour le poser. Le check doit juger chaque serveur sur `/pret` :

```bash
cat > /etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 2s
    timeout client  30s
    timeout server  30s

frontend boutique
    bind :80
    default_backend app

backend app
    balance roundrobin
    # Ticket #4823 : un serveur reçoit du trafic s'il peut servir (base comprise), pas seulement s'il écoute.
    # /pret (readiness) répond 503 quand la base manque ; /sante (liveness) ne regarde que le processus.
    option httpchk GET /pret
    http-check expect status 200
    # Un check toutes les 2 s : sorti du pool après 2 échecs (4 s), revenu après 2 succès.
    default-server inter 2s fall 2 rise 2
    server app1 127.0.0.1:8081 check
    server app2 127.0.0.1:8082 check
    server app3 127.0.0.1:8083 check
EOF
haproxy -c -q -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
timeout 15 bash -c 'until echo "show stat" | socat stdio /run/haproxy/admin.sock | grep -q "^app,app2,.*,DOWN,"; do sleep 0.5; done'
echo "show stat" | socat stdio /run/haproxy/admin.sock | awk -F, 'NR == 1 {for (i = 1; i <= NF; i++) c[$i] = i; next} $1 == "app" {print $2, $c["status"], $c["check_status"]}'
```

`haproxy -c` vérifie la configuration avant de la charger. Le rechargement garde le processus maître et les connexions en cours. Il oublie le `drain` posé à la main, et c'est désormais le check qui garde app2 hors du pool : `DOWN`, `L7STS` (le code HTTP ne convient pas). Quand les devs auront réparé sa base, `/pret` répondra 200, et app2 reviendra après deux checks réussis, sans intervention.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Redémarrer app2** : les devs perdent l'état qu'ils examinent, et app2 repart avec la même base injoignable.
- **Arrêter app2** : les erreurs cessent, l'enquête aussi. Et la prochaine panne de ce genre, sur un autre serveur, recommencera.
- **Retirer app2 de la configuration, ou le marquer `disabled`** : il ne reviendra pas tout seul une fois réparé.
- **`set server ... state drain` seul** : immédiat et sans rechargement, mais oublié au prochain rechargement, et rien ne revient tout seul.
- **Un check HTTP sur `/sante`** : le processus répond, la base non. Même mensonge que le check TCP.
- **`retry-on 500`** : le client ne voit plus d'erreur, mais HAProxy rejoue des commandes qui ont peut-être été à moitié traitées, et le serveur malade reçoit toujours une commande sur trois.
- **Le check sur `/pret`, avec un `drain` immédiat pour soulager** : HAProxy sort et fait revenir chaque serveur selon sa capacité à servir, de jour comme de nuit.

</details>

## En prod

- Un health check de répartiteur doit tester la capacité à servir (« readiness »), avec un endpoint fait pour ça. Un port ouvert ou un processus vivant ne prouvent rien.
- Un check TCP (`L4OK`) dit seulement qu'une connexion s'ouvre. À éviter devant une application HTTP.
- L'API runtime de HAProxy agit sans rechargement : `drain` (plus de nouvelles requêtes, celles en cours finissent), `maint` (plus rien), `weight`. Un rechargement l'oublie, sauf avec `server-state-file`.
- Ne jamais rejouer automatiquement une requête non idempotente (`POST`, paiement, commande) : un 500 ne dit pas si le travail a été fait.
- Regarder la colonne `hrsp_5xx` par serveur : un serveur `UP` qui accumule des 500 a un check qui ment.
