# 05. L'OOM killer tue la base chaque nuit

## Le ticket

> **Ticket #4630, priorité haute**
> Depuis trois semaines, la base PostgreSQL de la boutique tombe presque chaque nuit vers 2 h, et l'astreinte la relance au matin. Son journal dit `killed by the OOM killer`. Les commandes de la nuit échouent, l'export comptable de 2 h aussi, et l'ERP n'a rien à importer à 6 h.
> Le serveur a pourtant des gigaoctets de mémoire libre (`free -m`). Le DBA propose de baisser `shared_buffers`, l'équipe système d'ajouter de la RAM.
> Pour reproduire, l'astreinte vient de relancer l'export à la main (`systemctl start export-nuit`) : la base est retombée, elle l'a relancée.
> Historique : jusqu'en octobre, c'était l'export qui plantait certaines nuits (ticket #4120, résolu).
> Contraintes : base.slice (400 Mo, sans swap) est le budget mémoire validé par le DBA pour la base, il reste en place. L'ERP importe le fichier d'export tel quel : son contenu et son format ne changent pas. L'export tourne chaque nuit.

## Impact business

Chaque nuit, la boutique perd ses commandes pendant plusieurs heures, jusqu'à ce que l'astreinte relance la base. Au matin, la comptabilité n'a pas d'export et le stock de l'ERP n'est pas à jour. Les deux propositions sur la table coûtent cher sans rien régler : de la RAM pour une machine qui en a déjà de trop, ou un cache de base réduit qui ralentira la boutique toute la journée.

## Les enjeux

- Comprendre un manque de mémoire alors que `free` montre des gigaoctets libres.
- Lire qui a été tué, et pourquoi lui. L'OOM killer choisit sa victime, et ce choix a été faussé.
- Corriger la consommation de l'export à la source, sans changer le fichier que lit l'ERP.
- Séparer l'export de la base sans toucher au budget du DBA.

## Ce qui est vérifié

- la base tourne dans base.slice, avec le budget du DBA (400 Mo, sans swap)
- l'export n'est plus dans base.slice, et il a son propre plafond mémoire
- l'export n'est plus protégé de l'OOM killer
- l'export tourne toujours chaque nuit (timer actif)

Si c'est bon, le check rejoue la nuit et vérifie :

- l'export se termine, et une connexion ouverte sur la base pendant ce temps n'est pas coupée
- le fichier est complet, au format attendu par l'ERP
- rejoué une dernière fois, psql reste sous 64 Mo de mémoire : sa consommation ne dépend plus de la taille de la table

## Indices

<details><summary>Indice 1</summary>

`free` décrit la machine entière. `systemctl show postgresql@17-main -p Slice`, puis `cat /sys/fs/cgroup/<tranche>/memory.events` : quelle limite a vraiment été atteinte ?

</details>

<details><summary>Indice 2</summary>

Dans un cgroup plein, l'OOM killer tue le processus au plus gros score : sa mémoire, corrigée par `oom_score_adj`. `dmesg | grep 'Killed process'` donne la victime. `systemctl cat export-nuit` dit ce que le ticket #4120 a changé.

</details>

<details><summary>Indice 3</summary>

`journalctl -u export-nuit` donne le pic de mémoire de l'export. Pourquoi un programme qui écrit un fichier ligne par ligne a-t-il besoin de 250 Mo ? Cherche `FETCH_COUNT` dans `man psql`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
free -m                                                    # des gigaoctets libres : la machine n'a manqué de rien
journalctl -u postgresql@17-main -o cat | grep -iE 'oom|failed'   # tuée par l'OOM killer, puis Failed with result 'oom-kill'
grep 'terminated by signal 9' /var/log/postgresql/postgresql-17-main.log | tail -1   # un processus de PostgreSQL, tué net
```

`free` ne voit que la machine. La limite atteinte est ailleurs :

```bash
systemctl show postgresql@17-main -p Slice                 # base.slice
systemctl show base.slice -p MemoryMax -p MemorySwapMax    # 400 Mo, sans swap
grep oom /sys/fs/cgroup/base.slice/memory.events           # oom_kill : c'est la tranche qui a débordé
dmesg | grep -E 'oom-kill:|Killed process' | tail -2       # CONSTRAINT_MEMCG ; victime : postgres, oom_score_adj:0
```

Une tranche systemd est un cgroup. Quand sa mémoire atteint `MemoryMax` et que le noyau ne peut plus rien récupérer (pas de swap, et la mémoire partagée de PostgreSQL ne se libère pas), l'OOM killer tue un processus de ce cgroup, même si la machine a encore des gigaoctets libres. Qui partage la tranche avec la base ?

```bash
systemctl cat export-nuit.service                          # Slice=base.slice, OOMScoreAdjust=-900 (#4120)
journalctl -u export-nuit -o cat | grep peak               # 248.7M memory peak
```

`psql` lit tout le résultat d'une requête en mémoire avant d'en écrire la première ligne. Un million de commandes, 250 Mo, dans une tranche de 400 Mo dont les `shared_buffers` occupent déjà 128 Mo : elle déborde, et l'export grossira avec la table.

Reste à savoir pourquoi la victime est la base. Dans un cgroup plein, l'OOM killer tue le processus au plus gros score : sa mémoire (mémoire partagée comprise), plus `oom_score_adj` multiplié par la limite du cgroup et divisé par 1000. `psql` occupe 250 Mo, mais -900 lui retire l'équivalent de 360 Mo : son score est négatif. En face, les processus de PostgreSQL qui ont parcouru les `shared_buffers` (celui qui sert l'export, le background writer) comptent chacun jusqu'à 130 Mo de mémoire partagée, avec un ajustement à 0. Le plus gros d'entre eux est tué : `dmesg` le montre avec son `shmem-rss`. Avant le ticket #4120, la victime était `psql`, et seul l'export échouait.

```bash
systemctl show postgresql@17-main -p OOMScoreAdjust -p OOMPolicy   # -900, stop
cat /proc/"$(pgrep -o -u postgres postgres)"/oom_score_adj          # -900 pour le processus principal
```

L'unité Debian protège le processus principal de PostgreSQL (-900) et remet ses processus enfants à 0. Un enfant tué, et PostgreSQL coupe toutes les connexions pour repartir en récupération. Puis systemd achève le travail : `OOMPolicy=stop` est sa valeur par défaut, l'unité entière est arrêtée, et rien ne la redémarre avant l'astreinte du matin. Si cet arrêt tombe pendant la réinitialisation qui suit le crash, PostgreSQL ne le traite plus, et systemd finit par tuer ce qui reste au bout de `TimeoutStopSec` : `Stopping timed out` dans le journal.

Corriger l'export d'abord. `FETCH_COUNT` fait lire le résultat par paquets de 10 000 lignes, écrits au fur et à mesure. La sortie est la même, octet pour octet :

```bash
sed -i 's/psql -X -At /psql -X -At -v FETCH_COUNT=10000 /' /usr/local/bin/export-compta
grep psql /usr/local/bin/export-compta
```

Puis le sortir du budget de la base. Le budget du DBA reste intact pour PostgreSQL seul, l'export reçoit son propre plafond, et il redevient une victime ordinaire : s'il déborde un jour, c'est lui qui s'arrête, pas la base.

```bash
cat > /etc/systemd/system/export-nuit.service <<'EOF'
[Unit]
Description=Export comptable de la nuit vers l'ERP
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/export-compta
# Ticket #4630 : hors de base.slice, avec son propre plafond. Si l'export déborde, c'est lui qui s'arrête.
# Plus de protection contre l'OOM killer (#4120 annulé) : un batch doit passer avant la base.
MemoryMax=256M
MemorySwapMax=0
EOF
systemctl daemon-reload
systemctl start export-nuit
systemctl is-active postgresql@17-main                       # active
tail -n 2 /var/log/postgresql/postgresql-17-main.log         # aucun signal 9
wc -l /srv/exports/commandes-"$(date +%F)".csv              # 1000000
```

Dernière étape, hors du serveur : expliquer au DBA pourquoi la demande #3982 est retirée. L'export compte maintenant à part, avec un plafond à lui, et le budget de 400 Mo reste réservé à la base.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Ajouter de la RAM** : la machine n'en manque pas. La limite est celle de base.slice, et la nouvelle RAM resterait inutilisée.
- **Baisser `shared_buffers`** : la tranche déborde un peu plus tard. L'export grossit avec la table et la rattrapera, et la boutique lit plus souvent sur le disque en attendant.
- **Monter `MemoryMax` de base.slice** : contraire au budget du DBA, et même chose : l'export finira par atteindre n'importe quelle limite.
- **Supprimer seulement `OOMScoreAdjust=-900`** : la victime redevient `psql`. La base survit, mais l'export échoue une nuit sur deux, comme avant octobre.
- **`OOMScoreAdjust=-1000` sur PostgreSQL** : la base devient intouchable dans sa tranche, et le noyau tue l'export quand il déborde. Mieux, mais l'export échoue toujours, et la base reste à la merci du prochain programme qu'on glissera dans sa tranche.
- **`OOMPolicy=continue` sur PostgreSQL** : PostgreSQL récupère seul en quelques secondes au lieu de rester arrêté jusqu'au matin. Une bonne idée à discuter avec le DBA, mais les connexions sont tout de même coupées à chaque débordement.
- **`COPY (...) TO STDOUT`** : lit aussi par flux, et donne le même fichier sur ces données. Mais son format diffère de `psql -At` dès qu'une valeur contient un `;`, un guillemet ou un NULL : l'ERP pourrait recevoir un fichier différent sans que personne le voie.
- **`FETCH_COUNT` et un export hors de la tranche, avec son propre plafond** : la consommation ne dépend plus de la taille de la table, la sortie ne change pas d'un octet, et un débordement futur ne peut plus atteindre la base.

</details>

## En prod

- Devant un « Killed » ou un `oom-kill`, regarder d'abord `CONSTRAINT_MEMCG` dans `dmesg` et `memory.events` du cgroup : sur une machine avec systemd, la limite atteinte est souvent celle d'une tranche, pas celle de la machine.
- Ne jamais protéger un batch de l'OOM killer. La victime désignée doit être ce qui se relance sans dommage, jamais la base.
- Un batch qui lit une table entière doit lire par flux (`FETCH_COUNT`, curseur côté serveur, `COPY`) : sa mémoire ne doit pas grandir avec les données.
- Superviser `memory.events` de chaque tranche importante. Un compteur `max` qui grimpe annonce un `oom_kill` avant qu'il n'arrive.
- `MemoryLow=` sur la base protège son cache quand la machine entière manque de mémoire, sans plafond dur.
