# 02. Chaque rotation de logs remplit un peu plus le disque

## Le ticket

> **Ticket #4519, priorité haute**
> /var/log/app est passé de 15 % à plus de 60 % en deux nuits, alors que le trafic de l'API est stable. Chaque rotation de logs ajoute un palier. À ce rythme, la rotation de cette nuit va saturer la partition, et l'API qui écrit son journal dedans.
> Remontée de l'équipe sauvegarde : leur outil voit un app.log de 120 Mo, alors que `du` n'en annonce que 40.
> Contraintes : le SIEM lit /var/log/app/app.log, le fichier doit rester à cet endroit. Les journaux tournés se conservent (audit). Pas de redémarrage nocturne de l'API.

## Impact business

L'API va tomber cette nuit, à l'heure de la rotation, sans autre signe avant-coureur qu'une courbe de disque en escalier. Une partition de logs pleine bloque ou fait planter une application, selon la façon dont elle gère l'erreur d'écriture. Les coûts ont déjà commencé : l'outil de sauvegarde copie chaque nuit des dizaines de Mo de zéros, les fenêtres de sauvegarde s'allongent, et le stockage de sauvegarde grossit pour rien.

## Les enjeux

- Comprendre pourquoi `ls` et `du` divergent sur un même fichier, alors que rien n'est supprimé ni caché.
- Trouver une cause qui vient de deux réglages corrects pris séparément : la rotation, et la façon dont systemd ouvre le fichier.
- Récupérer l'espace sans perdre une ligne de journal, et sans redémarrer l'API la nuit.
- Désamorcer aussi le fichier actuel. Corriger la cause ne retire pas le trou déjà présent dans app.log : la prochaine copie l'écrirait encore.

## Ce qui est vérifié

- app-api tourne
- app-api écrit dans /var/log/app/app.log en mode ajout (O_APPEND)
- les journaux sont conservés, de la première à la dernière heure de pointe

Si tout ça est bon, le check lance lui-même une rotation, comme celle de cette nuit, puis vérifie :

- après la rotation, app.log reprend sans trou
- après la rotation, /var/log/app est utilisé à moins de 70 %

## Indices

<details><summary>Indice 1</summary>

`ls -ls` affiche à gauche les blocs réellement occupés. Compare-les à la taille apparente. Un fichier peut être plus « grand » que ce qu'il occupe : c'est un fichier creux.

</details>

<details><summary>Indice 2</summary>

Après un `copytruncate`, le fichier repart à zéro octet. Mais où le processus écrit-il ensuite ? Regarde les champs `pos` et `flags` de `/proc/<PID>/fdinfo/1`, puis `systemctl cat app-api`.

</details>

<details><summary>Indice 3</summary>

`man systemd.exec` : la différence entre `file:` et `append:`. Puis `man fallocate`, option `--dig-holes`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
df -h /var/log/app                         # plus de 60 %
ls -lsh /var/log/app                       # app.log : 120 Mo apparents, 40 Mo réels. app.log.1 : 80 Mo réels pour 40 Mo de journal
pid=$(systemctl show -p MainPID --value app-api)
grep -E 'pos|flags' /proc/$pid/fdinfo/1    # pos : 120 Mo. flags : 0100001, sans O_APPEND (02000)
systemctl cat app-api                      # StandardOutput=file:/var/log/app/app.log
cat /etc/logrotate.d/app                   # copytruncate
```

Le mécanisme : `copytruncate` copie app.log puis le vide. L'API garde sa position d'écriture, 120 Mo, et écrit là, dans un fichier de 0 octet. Le noyau ne stocke pas l'espace sauté : app.log devient creux. À la rotation suivante, logrotate lit ce trou comme des zéros et les écrit pour de vrai dans app.log.1. D'où un palier de plus chaque nuit.

`StandardOutput=file:` ouvre le fichier sans `O_APPEND`. `append:` l'ouvre en mode ajout : chaque écriture va à la fin réelle du fichier, même juste après une troncature.

```bash
mkdir -p /etc/systemd/system/app-api.service.d
printf '[Service]\nStandardOutput=append:/var/log/app/app.log\n' > /etc/systemd/system/app-api.service.d/append.conf
systemctl daemon-reload
fallocate --dig-holes /var/log/app/app.log.1   # rend creux les zéros recopiés : 40 Mo libérés, contenu identique
systemctl restart app-api                      # une seconde de coupure, en journée, annoncée
logrotate -f /etc/logrotate.d/app              # sort l'app.log creux de la circulation
fallocate --dig-holes /var/log/app/app.log.1
df -h /var/log/app
```

L'ordre compte. La rotation forcée recopie une dernière fois les 120 Mo de l'ancien app.log, zéros compris. Si on la lance avant d'avoir récupéré de la place, la copie peut elle-même saturer la partition.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Supprimer les vieux journaux tournés** : l'espace revient, mais ce sont des traces d'audit qu'on doit garder. Et la cause reste : le palier revient à la rotation suivante.
- **`truncate -s 0 app.log`** : efface le journal de la journée, que l'audit réclame. Et l'API écrit toujours à son ancienne position : le trou réapparaît à la ligne suivante.
- **Remplacer `copytruncate` par `create` avec un redémarrage nocturne** : plus de trou, mais une coupure de l'API chaque nuit, et les requêtes en cours perdues à chaque redémarrage.
- **Passer le journal dans journald** : plus propre à terme, mais le SIEM lit app.log. C'est un chantier à mener avec l'équipe sécurité, pas une correction d'incident.
- **`append:` puis `--dig-holes`** : corrige la cause avec une seule coupure d'une seconde, choisie, et récupère l'espace des zéros sans toucher au contenu des journaux.

</details>

## En prod

- Avec `copytruncate`, l'application doit écrire en mode ajout. Côté systemd, c'est `append:`, jamais `file:`.
- Superviser l'écart entre taille apparente et taille réelle des logs (`du --apparent-size` contre `du`) : un écart qui grandit annonce ce problème plusieurs jours à l'avance.
- Les outils de sauvegarde doivent gérer les fichiers creux (`tar -S`, `rsync -S`), sinon ils copient les zéros.
