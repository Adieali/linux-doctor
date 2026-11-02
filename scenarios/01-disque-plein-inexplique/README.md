# 01. Le disque est plein, et rien ne l'explique

## Le ticket

> **Ticket #4512, priorité haute**
> La supervision signale /srv à plus de 90 %. `du -xsh /srv` ne trouve que 6 Mo. L'astreinte a cherché un fichier supprimé encore ouvert, en a trouvé un, a redémarré le service concerné : rien n'a bougé.
> **Ticket #4515, ouvert le même jour par la comptabilité** : les archives du 19, 20 et 21 octobre sont introuvables. Le job d'archivage n'a signalé aucune erreur.
> Contexte : maintenance avec redémarrage le 19 octobre. Le disque d'archives ne remontait pas, il a été remonté à la main le 22.
> Libère l'espace sans perdre une seule archive, et fais en sorte que ça ne se reproduise pas.

## Impact business

Deux équipes voient deux problèmes sans rapport : l'infra un disque plein, la comptabilité des archives perdues. Tant que personne ne relie les deux, chacune cherche de son côté. Côté infra, /srv va finir par se remplir et faire tomber l'application. Côté comptabilité, des pièces que la loi impose de conserver dix ans (Code de commerce, article L123-22) semblent avoir disparu. En cas de contrôle fiscal, ne pas pouvoir les produire coûte bien plus cher qu'un disque.

## Les enjeux

- Relier les deux tickets : c'est la clé du diagnostic, et aucun outil ne le fera à ta place.
- Ne supprimer aucun fichier : ce qui occupe /srv, ce sont peut-être justement les archives recherchées.
- Ne pas couper l'accès au disque d'archives, que la comptabilité consulte en journée.
- Empêcher le job d'écrire « à côté » du disque la prochaine fois qu'il manquera. Une tâche qui réussit en écrivant au mauvais endroit est pire qu'une tâche qui échoue.

## Ce qui est vérifié

- /srv est utilisé à moins de 30 %
- le disque d'archives est toujours monté sur /srv/data/archive
- les 16 archives du 12 au 27 octobre sont sur le disque d'archives, intactes

Si tout ça est bon, le check démonte lui-même le disque d'archives et lance le job pour de vrai, puis vérifie :

- sans son disque, le job d'archivage échoue de façon visible ou remonte le disque

## Indices

<details><summary>Indice 1</summary>

`df` compte les blocs utilisés par le système de fichiers. `du` additionne les fichiers qu'il arrive à atteindre en parcourant l'arborescence. Qu'est-ce qui pourrait occuper des blocs sans être atteignable ?

</details>

<details><summary>Indice 2</summary>

`findmnt -R /srv`. Un point de montage est un répertoire comme un autre, et il peut contenir des fichiers. Qu'arrive-t-il à ces fichiers quand on monte un disque par-dessus ?

</details>

<details><summary>Indice 3</summary>

On peut voir un système de fichiers « nu », sans ce qui est monté dessus, sans rien démonter : `mount --bind`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
df -h /srv                       # 92 % utilisé
du -xsh /srv                     # 6 Mo : il manque presque tout
lsof +L1 /srv                    # un fichier supprimé ouvert, 2 Mo : vrai, mais ce n'est pas l'explication
findmnt -R -o TARGET,SOURCE /srv # /srv/data/archive est un autre système de fichiers, monté sur /srv
tail -20 /var/log/archive-compta.log   # le job a bien écrit les archives du 19 au 21... pendant que le disque était absent

mkdir -p /mnt/srv-nu
mount --bind /srv /mnt/srv-nu    # /srv sans ce qui est monté dessus
du -sh /mnt/srv-nu/data/archive  # 36 Mo cachés sous le point de montage
ls -l /mnt/srv-nu/data/archive   # compta-2026-10-19.tar, 20, 21 : les archives « perdues »

cp -a /mnt/srv-nu/data/archive/compta-2026-10-*.tar /srv/data/archive/
for f in /mnt/srv-nu/data/archive/*.tar; do cmp "$f" "/srv/data/archive/${f##*/}" && rm "$f"; done
umount /mnt/srv-nu
df -h /srv                       # l'espace est revenu

mkdir -p /etc/systemd/system/archive-compta.service.d
printf '[Unit]\nAssertPathIsMountPoint=/srv/data/archive\n' > /etc/systemd/system/archive-compta.service.d/disque.conf
systemctl daemon-reload
```

Le piège de la dernière étape : `RequiresMountsFor=/srv/data/archive` semble être la bonne directive, mais elle ne protège rien ici. systemd ne connaît que les montages déclarés dans /etc/fstab ou dans une unité `.mount`. Ce disque a été remonté à la main : la dépendance ne trouve aucune unité, et elle est ignorée sans un mot. `AssertPathIsMountPoint=` vérifie le chemin lui-même et fait échouer le job. La correction complète déclare aussi le disque dans /etc/fstab, avec `nofail`. `RequiresMountsFor=` devient alors utile : systemd remonte le disque avant de lancer le job.

Le bind mount d'un système de fichiers ne reprend pas ce qui est monté dessus : sous /mnt/srv-nu, data/archive redevient le simple répertoire de /srv, avec ce qui y a été écrit pendant l'absence du disque.

La copie est vérifiée fichier par fichier avec `cmp` avant suppression. Sur des pièces comptables, un `mv` entre deux systèmes de fichiers fait la même chose, mais rien ne prouve après coup que la copie était complète.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Supprimer ce qu'on trouve sous le montage** : l'espace revient, et les archives comptables disparaissent pour de bon. Le ticket de la comptabilité devient impossible à résoudre.
- **Démonter le disque d'archives pour regarder dessous** : ça marche, mais coupe l'accès aux archives pendant l'opération. Le démontage peut aussi échouer (`target is busy`), et si le job tourne à ce moment-là, il recrée exactement la panne.
- **Agrandir /srv** : traite le symptôme, et les archives restent introuvables.
- **Redémarrer le service qui tient un fichier supprimé** : piste légitime, mais elle ne pèse que 2 Mo sur les 45 occupés. Quand un suspect n'explique qu'une fraction du symptôme, l'enquête continue.
- **`ConditionPathIsMountPoint=` dans l'unité** : le job ne tourne plus sans son disque, mais en silence. systemd considère une condition non remplie comme normale, et personne n'est alerté.
- **`RequiresMountsFor=` seul, sans entrée dans /etc/fstab** : la directive ne trouve aucun montage déclaré, et le job continue d'écrire sous le point de montage. C'est la correction qui a l'air juste et qui ne protège rien.

</details>

## En prod

- Tout job qui écrit sur un disque monté déclare ce disque : `RequiresMountsFor=` dans l'unité systemd, ou `mountpoint -q` en tête de script.
- Un disque de données monté à la main après une panne de boot doit être corrigé dans /etc/fstab dans la foulée, avec `nofail` si le serveur doit pouvoir démarrer sans lui.
- Superviser le résultat du job (l'archive du jour existe-t-elle sur le bon disque ?), pas seulement son code de retour.
