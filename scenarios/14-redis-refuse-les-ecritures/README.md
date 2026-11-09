# 14. Redis refuse les écritures

## Le ticket

> **Ticket #4790, priorité critique**
> Depuis ce matin, par vagues de quelques dizaines de secondes, les clients ne peuvent plus ajouter d'article à leur panier : l'API renvoie `MISCONF Redis is configured to save RDB snapshots, but it's currently unable to persist to disk`. Les lectures marchent toujours, et entre deux vagues tout semble normal.
> Le disque de Redis est à moitié vide. Une première analyse soupçonne `vm.overcommit_memory`.
> Contraintes : Redis porte les paniers, qui doivent survivre à un redémarrage : la persistance reste active. Redis a droit à 400 Mo de mémoire sur ce serveur (`MemoryMax` de son unité), un chiffre validé par l'équipe système. Règle métier : un panier vit 7 jours après sa dernière modification. Si la place manque, les plus anciens partent en premier, jamais ceux qu'on vient de modifier.
> L'unité `lab-paniers` simule l'application : n'y touche pas.

## Impact business

À chaque vague, les clients ne peuvent plus remplir leur panier : ceux qui insistent tombent sur une erreur, les autres partent. Comme tout revient seul au bout de quelques dizaines de secondes, l'incident ressemble à un problème réseau passager, et personne ne cherche. Et la solution qu'on trouve en ligne, désactiver le contrôle des sauvegardes, ferait disparaître les erreurs en laissant les paniers sans sauvegarde : au prochain redémarrage, ils seraient perdus.

## Les enjeux

- Comprendre pourquoi une sauvegarde échoue sur un disque à moitié vide.
- Écarter une fausse piste qui demanderait de changer un réglage de toute la machine.
- Garder la persistance, tout en rendant la place qu'il faut à une sauvegarde.
- Choisir ce que Redis jette quand la place manque, selon la règle métier.

## Ce qui est vérifié

- Redis garde sa limite de 400 Mo, sans swap
- la persistance reste active, et protège toujours les écritures
- Redis accepte les écritures
- `maxmemory` laisse la place d'une copie complète pendant la sauvegarde

Si c'est bon, le check lance une sauvegarde en pleine pointe d'écriture, et vérifie :

- la sauvegarde aboutit, sans processus tué
- les paniers qu'on vient de modifier sont toujours là, après une nouvelle pointe
- les données et la configuration survivent au redémarrage de Redis

## Indices

<details><summary>Indice 1</summary>

`journalctl -u redis-server` : que devient la sauvegarde en arrière-plan ? Puis `memory.events` dans le cgroup de l'unité, sous /sys/fs/cgroup.

</details>

<details><summary>Indice 2</summary>

Pour sauvegarder, Redis crée un processus fils avec `fork()`. Que se passe-t-il pour la mémoire quand le père modifie ses données pendant que le fils les écrit sur disque ? `rdb_last_cow_size` dans `INFO persistence`.

</details>

<details><summary>Indice 3</summary>

`maxmemory`, et les politiques `maxmemory-policy`. Laquelle colle à « 7 jours après la dernière modification » ? Et après avoir libéré de la mémoire, que montre `used_memory_rss` ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
redis-cli set essai 1                     # MISCONF, ou OK entre deux vagues
journalctl -u redis-server -o cat --no-pager | grep -E 'Background saving|DB saved' | tail -6
redis-cli info persistence | grep -E '^rdb_(last_bgsave_status|last_cow_size)'
df -h /var/lib/redis                      # de la place à revendre
```

Les sauvegardes alternent : `Background saving terminated by signal 9`, puis `DB saved on disk`. Un processus tué par le signal 9, avec de la place sur le disque : ce n'est pas l'écriture du fichier qui échoue. Côté mémoire :

```bash
systemctl show redis-server -p MemoryMax -p MemorySwapMax -p OOMPolicy
grep oom_kill /sys/fs/cgroup/system.slice/redis-server.service/memory.events
redis-cli info memory | grep -E '^(used_memory_human|used_memory_rss_human|maxmemory_human|maxmemory_policy)'
```

Pour sauvegarder sans s'arrêter, Redis crée un processus fils avec `fork()`. Le fils partage la mémoire du père et l'écrit sur disque. Mais chaque page que le père modifie pendant ce temps est d'abord copiée, pour que le fils voie toujours l'état du début : c'est la copie à l'écriture, le copy-on-write. Sous les écritures des clients, les copies s'ajoutent aux presque 380 Mo de Redis et dépassent les 400 Mo de l'unité. Le noyau tue un processus de la tranche, le fils, que `oom-score-adj` désigne en premier, et `OOMPolicy=continue` laisse Redis tourner. Redis voit sa sauvegarde échouer et refuse les écritures (`stop-writes-on-bgsave-error`), pour ne pas accepter des données qu'il ne sait pas sauvegarder.

Les vagues viennent de là. Écritures refusées, plus aucune page n'est modifiée : la sauvegarde que Redis retente quelques secondes plus tard ne copie presque rien, et passe. Les écritures reprennent, et la sauvegarde suivante, sous la charge, échoue de nouveau.

`vm.overcommit_memory` concerne un `fork()` refusé par le noyau. Ici, le `fork()` réussit (`Background saving started by pid ...`). C'est la limite du cgroup qui tue le fils, et ce réglage, valable pour toute la machine, n'y changerait rien.

Le fond du problème : `maxmemory` vaut 0, Redis grossit sans limite, et rien ne garantit qu'une sauvegarde tienne dans 400 Mo. Il faut assez de place pour les données et, dans le pire des cas, une copie complète : 150 Mo de données, 150 de copie, et de la marge. Pour la règle métier, chaque modification d'un panier repart pour 7 jours : le panier modifié il y a le plus longtemps est celui qui expire le plus tôt. C'est exactement ce que choisit `volatile-ttl` :

```bash
redis-cli config set maxmemory-policy volatile-ttl
redis-cli config set maxmemory 150mb
until (( $(redis-cli info memory | tr -d '\r' | sed -n 's/^used_memory://p') <= 150 * 1024 * 1024 )); do sleep 1; done
redis-cli info memory | grep -E '^(used_memory_human|used_memory_rss_human)'
```

Les données sont à 150 Mo, mais Redis occupe toujours près de 300 Mo pour le système. L'allocateur garde la mémoire libérée, morcelée entre les pages encore utilisées, et ne la rend pas : une sauvegarde en arrière-plan risquerait encore de dépasser la limite. Pour sortir de là, une sauvegarde synchrone, `SAVE` : Redis s'arrête deux ou trois secondes, mais ne forke pas, donc ne copie rien. Les écritures sont de nouveau acceptées. Puis `CONFIG REWRITE` écrit les deux réglages dans redis.conf, et un redémarrage recharge les données depuis ce fichier tout neuf, dans une mémoire compacte :

```bash
redis-cli save
redis-cli config rewrite
systemctl restart redis-server
until [[ $(redis-cli ping 2>/dev/null) == PONG ]]; do sleep 0.5; done
redis-cli info memory | grep -E '^(used_memory_human|used_memory_rss_human)'
redis-cli set essai 1
```

Dernière étape, hors du serveur : dire à l'équipe produit que, faute de place, des paniers anciens disparaissent maintenant avant leurs 7 jours, et suivre `evicted_keys` dans `INFO stats` : s'il grimpe, Redis a besoin de plus de mémoire, et c'est un arbitrage à faire avec l'équipe système.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **`vm.overcommit_memory = 1`** : un réglage de toute la machine, pour un `fork()` qui réussit déjà. La limite du cgroup tue toujours le fils.
- **`stop-writes-on-bgsave-error no`** : les erreurs disparaissent, et les sauvegardes continuent d'échouer sans que personne ne le voie. Au prochain redémarrage, tous les paniers modifiés depuis la dernière sauvegarde réussie sont perdus.
- **`save ""`, plus de persistance** : plus de sauvegarde, donc plus d'échec. Et plus de paniers après un redémarrage.
- **Monter `MemoryMax`** : contraire à la décision de l'équipe système, et sans `maxmemory`, Redis grossira jusqu'à la nouvelle limite.
- **Passer à l'AOF** : la réécriture du fichier AOF passe aussi par un `fork()`, avec la même copie à l'écriture.
- **`maxmemory` sans redémarrage** : les données diminuent, pas la mémoire occupée. Les sauvegardes en arrière-plan risquent encore de dépasser la limite.
- **`noeviction`** : une fois `maxmemory` atteint, les écritures sont refusées avec une autre erreur, `OOM command not allowed`. Même panne pour les clients.
- **`allkeys-random` ou `volatile-random`** : un panier qu'on vient de modifier peut disparaître.
- **`maxmemory` dimensionné pour une copie complète, `volatile-ttl`, un `SAVE` puis un redémarrage** : la persistance tient sous la charge, les paniers anciens partent en premier, et Redis reste dans sa limite.

</details>

## En prod

- Un Redis persistant doit pouvoir doubler sa mémoire pendant une sauvegarde, dans le pire des cas. Le prévoir dans sa limite, et suivre `rdb_last_cow_size`.
- Toujours régler `maxmemory`, et une `maxmemory-policy` qui colle au sens des données.
- Superviser `rdb_last_bgsave_status`, `evicted_keys`, et le `memory.events` de l'unité.
- Après avoir réduit `maxmemory`, regarder `used_memory_rss`, pas seulement `used_memory`. `activedefrag` peut compacter sans redémarrage, plus lentement.
- `oom-score-adj` et `OOMPolicy=continue` vont ensemble : sans le second, systemd arrête tout Redis dès que le noyau tue le fils.
