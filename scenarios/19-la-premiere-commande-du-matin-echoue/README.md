# 19. La première commande du matin échoue

## Le ticket

> **Ticket #4851, priorité haute**
> Chaque matin, la première consultation des commandes de la journée échoue : « base injoignable », au bout de 5 secondes. La suivante passe, et tout va bien jusqu'au lendemain. Même chose après une pause déjeuner un peu calme. La base va bien, le ping passe, et le service des commandes n'a pas changé depuis des mois.
> Le service garde une connexion ouverte vers PostgreSQL, de l'autre côté d'un pare-feu de l'équipe réseau. Celle-ci a vérifié ses équipements : rien d'anormal. Elle rappelle sa politique : le pare-feu oublie une connexion TCP inactive au bout d'une heure, et ça ne changera pas.
> Le labo accélère le temps : le pare-feu oublie une connexion inactive au bout de 20 s, et une « nuit » dure 25 s.
> Pour tester : `curl http://localhost:8000/commandes`.
> Contraintes : le service garde sa connexion ouverte entre les requêtes (la base limite le nombre de connexions, et en ouvrir une coûte cher). Le pare-feu ne change pas. Tout doit tenir au redémarrage.
> Les netns `pare-feu` et `base`, et l'unité `lab-base`, simulent le reste : n'y touche pas.

## Impact business

Le premier préparateur du matin voit une erreur, recharge, et ça passe : personne ne remonte le problème, il dure depuis des mois. Mais les traitements automatiques du matin (export vers le transporteur, relances) tombent sur la même erreur, et ceux qui ne réessaient pas perdent une journée. Le ticket finit renvoyé entre l'équipe réseau, l'équipe base et les développeurs, chacun ayant vérifié que tout va bien chez lui.

## Les enjeux

- Comprendre ce qu'il advient, la nuit, d'une connexion TCP que personne n'utilise.
- Trouver pourquoi un mécanisme prévu pour ce cas, et activé, ne protège pas cette connexion.
- Réparer sans toucher au pare-feu et sans renoncer à la connexion gardée ouverte.
- Vérifier que la réparation s'applique aux connexions existantes, pas seulement aux prochaines.

## Ce qui est vérifié

Le check rejoue d'abord un démarrage : réglages du noyau remis à leurs valeurs par défaut puis relus depuis `/etc/sysctl.d`, service des commandes relancé. Puis il vérifie :

- le pare-feu oublie toujours une connexion inactive au bout de 20 s
- le service des commandes répond

Ensuite, il laisse passer une nuit, 30 s sans une commande, et vérifie :

- la première commande du matin passe, en moins de 2 s
- par la connexion de la veille, sans en ouvrir une nouvelle

## Indices

<details><summary>Indice 1</summary>

Laisse passer une nuit, puis regarde ce qui part vers la base pendant la commande qui échoue : `tcpdump -ni eth1 'tcp port 5432'`. Qu'est-ce qui revient ?

</details>

<details><summary>Indice 2</summary>

Un pare-feu à état ne laisse passer que les paquets d'une connexion qu'il connaît encore. Qu'est-ce qui pourrait lui rappeler, pendant la nuit, qu'elle existe ? `ss -tno` montre les minuteurs de chaque connexion.

</details>

<details><summary>Indice 3</summary>

Le keepalive TCP est bien actif sur cette connexion. Dans combien de temps enverra-t-il sa première sonde ? Et un nouveau réglage s'applique-t-il à un minuteur déjà armé ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -o /dev/null http://localhost:8000/commandes                 # la connexion du service sert
sleep 25                                                              # une « nuit » du labo
timeout 8 tcpdump -lni eth1 -c 3 'tcp port 5432' &
sleep 0.5
curl -s -w ' (%{time_total} s)\n' http://localhost:8000/commandes     # {"erreur": "base injoignable"} (5.0 s)
wait
curl -s -w ' (%{time_total} s)\n' http://localhost:8000/commandes     # {"commandes": 1250} (0.0 s)
journalctl -u commandes -o cat | tail -1                              # ERREUR base après 5.0 s : ... Connection timed out
```

Après la nuit, le service envoie sa requête sur la connexion gardée ouverte la veille, la renvoie plusieurs fois, et rien ne revient. Au bout de 5 s (`tcp_user_timeout` dans sa configuration), il abandonne, renvoie l'erreur, puis ouvre une nouvelle connexion à la requête suivante : elle passe.

Pendant la nuit, personne n'a fermé cette connexion. Le serveur et la base la croient toujours ouverte. Mais le pare-feu, lui, l'a oubliée au bout de 20 s d'inactivité (une heure en prod). Pour lui, un paquet de données qui n'est pas un début de connexion (SYN) et qu'il ne rattache à rien est suspect : il le jette, sans prévenir personne. La connexion est morte en silence.

Le keepalive TCP existe pour ça : sur une connexion inactive, le noyau envoie de temps en temps une sonde, qui rappelle au pare-feu que la connexion vit. libpq l'active d'office. Mais quand ?

```bash
ss -tno state established '( dport = :5432 )'                         # timer:(keepalive,119min,0)
sysctl net.ipv4.tcp_keepalive_time                                    # 7200
```

Première sonde dans deux heures, la valeur par défaut de Linux : bien après l'oubli du pare-feu. Le keepalive doit parler avant lui. Ici, au niveau du noyau, pour toutes les connexions longues du serveur qui traversent ce pare-feu :

```bash
cat > /etc/sysctl.d/70-keepalive.conf <<'EOF'
# Ticket #4851 : le pare-feu entre les serveurs et la base oublie une connexion TCP inactive au bout
# d'une heure (20 s dans le labo). Les sondes keepalive partent avant : après 10 s d'inactivité, puis
# toutes les 5 s, et la connexion est déclarée morte après 3 sondes sans réponse.
net.ipv4.tcp_keepalive_time = 10
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3
EOF
sysctl -q -p /etc/sysctl.d/70-keepalive.conf
ss -tno state established '( dport = :5432 )'                         # toujours keepalive,119min
```

La connexion déjà ouverte n'en profite pas : son minuteur a été armé à son ouverture, pour deux heures, et le nouveau délai ne comptera qu'à son échéance. Il faut recréer la connexion, en relançant le service :

```bash
systemctl restart commandes
curl -s -o /dev/null http://localhost:8000/commandes
ss -tno state established '( dport = :5432 )'                         # timer:(keepalive,9.9sec,0)
sleep 25
curl -s -w ' (%{time_total} s)\n' http://localhost:8000/commandes     # {"commandes": 1250} (0.0 s), après la nuit
```

Pendant la nuit, une sonde part toutes les 10 s, la base y répond, et le pare-feu garde la connexion en mémoire. Le réglage est dans `/etc/sysctl.d`, il tient au redémarrage.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Demander à l'équipe réseau d'allonger le délai du pare-feu** : refusé, et le seuil serait seulement déplacé. Un week-end de trois jours le franchira.
- **Une connexion par requête** : plus de connexion morte, mais la base est limitée en connexions, et chaque ouverture coûte une authentification.
- **Réessayer la requête quand elle échoue** : la commande passe au deuxième essai, après 5 s d'attente, et chaque traitement doit savoir réessayer.
- **Réduire `tcp_user_timeout`** : l'échec arrive plus vite. Il arrive quand même.
- **Un « ping » applicatif, `SELECT 1` toutes les 10 s** : marche, mais à coder dans chaque application. Le keepalive TCP fait la même chose dans le noyau, pour toutes.
- **`keepalives_idle=10` dans la chaîne de connexion du service** : marche aussi, pour ce service seulement. Les autres connexions longues du serveur restent exposées.
- **Le nouveau réglage sans relancer le service** : la connexion déjà ouverte garde son minuteur de deux heures.
- **`tcp_keepalive_time` sous le délai du pare-feu, dans `/etc/sysctl.d`, puis connexions recréées** : chaque connexion longue du serveur se signale avant d'être oubliée, et le réglage tient au redémarrage.

</details>

## En prod

- Un pare-feu à état, un NAT ou un répartiteur de charge oublie les connexions inactives, souvent au bout d'une heure, parfois de quelques minutes. Toute connexion longue qui peut rester muette plus longtemps (pools de connexions, réplication, SSH) doit envoyer des keepalive avant.
- Sous Linux, le keepalive TCP ne part qu'au bout de 2 heures d'inactivité par défaut, et seulement si l'application l'active (`SO_KEEPALIVE`).
- `ss -tno` montre le minuteur keepalive de chaque connexion : la façon la plus rapide de vérifier qu'un réglage s'applique vraiment.
- Un nouveau `tcp_keepalive_time` ne touche que les minuteurs armés après lui : recycler les connexions existantes.
- « La première requête après une pause échoue, la suivante passe » : penser à une connexion morte en silence, quelque part sur le chemin.
