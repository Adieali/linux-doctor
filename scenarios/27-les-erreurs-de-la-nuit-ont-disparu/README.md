# 27. Les erreurs de la nuit ont disparu

## Le ticket

> **Ticket #4921, priorité haute**
> La banque n'a pas reçu l'export comptable de cette nuit. Dans le fichier produit (`/srv/exports`), il manque près d'un tiers des factures du mois, et la comptabilité veut savoir lesquelles, et pourquoi. Le journal du serveur ne dit rien de l'export : le serveur a redémarré juste après, pour les correctifs du mois.
> Pour regarder : `systemctl status export-compta`, `journalctl -u export-compta`. L'export peut être relancé sans risque : tant qu'il échoue, il n'envoie rien à la banque.
> Contraintes : le code de l'export appartient à l'équipe Finance-IT, on ne le modifie pas. La protection contre les tempêtes de logs (ticket #4651, après le disque plein de septembre) reste en place, telle quelle, pour tous les autres services. Les journaux doivent survivre aux redémarrages.

## Impact business

Sans fichier, la banque ne passe pas les écritures du mois, et la clôture comptable a lieu dans deux jours. La comptabilité ne peut rien corriger tant qu'elle ne sait pas quelles factures posent problème. Et chaque nuit où l'export échoue sans laisser de trace, l'équipe d'astreinte ne peut que constater, sans pouvoir expliquer.

## Les enjeux

- Retrouver une information que le serveur a jetée, deux fois.
- Faire en sorte que les lignes du batch soient toutes gardées, sans rouvrir la porte aux tempêtes de logs.
- Un journal qui survit au redémarrage, sans refaire le disque plein de septembre.

## Ce qui est vérifié

- un service qui s'emballe (5000 lignes d'un coup) est toujours limité
- l'export, relancé, garde toutes ses lignes dans le journal : les 1312 rejets et le bilan

Si c'est bon, le check redémarre le serveur, puis vérifie :

- l'export lancé avant le redémarrage est toujours dans le journal, en entier

## Indices

<details><summary>Indice 1</summary>

Combien de factures manquent, d'après les factures du mois (`/var/lib/compta/factures.csv`) et le fichier exporté ? Relance l'export : combien de lignes de rejet arrivent dans le journal ?

</details>

<details><summary>Indice 2</summary>

Où journald garde-t-il ses fichiers ? `journalctl --header | grep 'File path'`, et sa configuration : `/etc/systemd/journald.conf.d/`.

</details>

<details><summary>Indice 3</summary>

La limitation de débit de journald se règle aussi service par service : `man systemd.exec`, cherche `LogRateLimit`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
systemctl status export-compta --no-pager | sed -n '3p'   # inactive (dead)
journalctl -u export-compta --no-pager                     # -- No entries --
wc -l /srv/exports/compta-*.csv                            # 2688 factures exportées
awk -F';' 'NR > 1' /var/lib/compta/factures.csv | wc -l    # 4000 factures dans le mois
journalctl --header | grep 'File path'                     # /run/log/journal/... : le journal est en mémoire
grep -hv '^#' /etc/systemd/journald.conf.d/*.conf          # RateLimitBurst=100 sur 30 s, Storage=volatile
ls -ld /var/log/journal                                    # n'existe pas
```

Le journal est dans `/run`, en mémoire : le redémarrage qui a suivi le batch l'a effacé, avec tout ce que l'export avait écrit. Après le disque plein de septembre, quelqu'un a choisi `Storage=volatile` et supprimé `/var/log/journal` pour libérer de la place. Ce qui s'est passé cette nuit est perdu. L'export, lui, se relance :

```bash
systemctl start export-compta
id=$(systemctl show -p InvocationID --value export-compta)
journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$id" | grep -c 'absent, rejetée'     # 249
journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$id" | tail -1
# facture F-2026-80761 (client C2854) : code TVA absent, rejetée
```

Deuxième perte, sans redémarrage cette fois : 249 rejets dans le journal (le nombre varie d'un serveur à l'autre), pour 1312 factures manquantes, et pas de bilan. La limitation de débit du ticket #4651 garde 100 messages par service sur 30 s, et journald module ce nombre selon l'espace disque libre. Au-delà, il jette sans prévenir. Il note « Suppressed N messages » seulement quand le service écrit de nouveau après la fenêtre : un batch qui s'arrête juste après ne laisse aucune trace.

Deux corrections, chacune à sa place. Pour l'export, chaque ligne compte, et leur nombre est borné par le nombre de factures du mois : il reçoit sa propre limite, large. Pour les autres services, la protection reste telle quelle. Attention, pour une unité, `LogRateLimitIntervalSec=0` ne désactive rien : 0 veut dire « pas de réglage propre », et c'est la limite de journald qui s'applique.

```bash
mkdir -p /etc/systemd/system/export-compta.service.d
cat > /etc/systemd/system/export-compta.service.d/journal.conf <<'EOF'
[Service]
# Ticket #4921 : une ligne par facture rejetée, puis le bilan. La comptabilité a besoin de toutes.
# Limite propre à ce batch, large : son volume est borné par le nombre de factures du mois (4000 aujourd'hui).
LogRateLimitIntervalSec=30s
LogRateLimitBurst=20000
EOF
systemctl daemon-reload
```

Pour le stockage : retirer `Storage=volatile` ne suffirait pas. La valeur par défaut, `auto`, n'écrit sur le disque que si `/var/log/journal` existe, et il a été supprimé. `Storage=persistent` le recrée. Contre le disque plein de septembre, la bonne protection est une taille maximale, pas un journal qui s'efface.

```bash
rm /etc/systemd/journald.conf.d/60-memoire.conf
cat > /etc/systemd/journald.conf.d/60-stockage.conf <<'EOF'
# Ticket #4921 : le journal reste sur le disque, pour survivre aux redémarrages.
# Contre le disque plein de septembre (#4651) : une taille maximale, et la limitation de débit à côté.
[Journal]
Storage=persistent
SystemMaxUse=2G
EOF
systemctl restart systemd-journald                         # relit sa configuration, crée /var/log/journal
journalctl --flush                                         # y verse ce qui était encore en mémoire
journalctl --header | grep 'File path'                     # /var/log/journal/...
```

L'export relancé donne enfin la réponse à la comptabilité :

```bash
systemctl start export-compta
id=$(systemctl show -p InvocationID --value export-compta)
journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$id" | grep -c 'absent, rejetée'     # 1312
journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$id" | tail -1
# ERREUR : export incomplet, 1312 factures rejetées sur 4000 (code TVA absent). Fichier NON transmis à la banque ...
```

La liste des 1312 factures part à la comptabilité : il leur manque un code TVA, à saisir avant de relancer l'export.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Retirer la limitation de débit de journald** : l'export garde ses lignes, et le prochain service en boucle d'erreurs remplit `/var` comme en septembre.
- **Monter `RateLimitBurst` pour tout le serveur** : la même chose en plus lent. Et la valeur qui convient à l'export (1312 ce mois-ci, davantage le mois prochain) n'est la bonne pour aucun autre service.
- **Retirer seulement `Storage=volatile`** : en `Storage=auto`, journald écrit sur le disque seulement si `/var/log/journal` existe. Rien ne change.
- **`Storage=persistent` sans redémarrer journald** : il lit sa configuration au démarrage. Jusque-là, tout reste en mémoire, et le prochain redémarrage efface encore tout.
- **Envoyer la sortie de l'export dans un fichier (`StandardOutput=append:`)** : les lignes survivent, mais hors du journal, sans rotation, et sans la supervision qui lit le journal.
- **`LogRateLimitIntervalSec=0` dans l'unité de l'export** : rien ne change. Pour une unité, 0 veut dire « valeur de journald ».
- **Une limite propre à l'export, large, et un journal persistant de taille bornée** : chaque ligne du batch est gardée, les autres services restent limités, et `SystemMaxUse=` empêche le journal de remplir `/var`.

</details>

## En prod

- La limitation de débit de journald jette sans bruit. « Suppressed N messages » n'apparaît que si le service écrit de nouveau après la fenêtre : un batch qui se termine juste après n'en laisse aucune trace.
- journald module `RateLimitBurst=` selon l'espace libre du disque : la même configuration garde plus de lignes sur un gros disque. Ne pas calibrer sur un serveur pour en déduire le comportement d'un autre.
- `Storage=auto`, la valeur par défaut, n'écrit sur le disque que si `/var/log/journal` existe. Un nettoyage qui le supprime rend le journal volatil sans que personne ne touche à la configuration. `Storage=persistent` le recrée.
- Contre le disque plein : `SystemMaxUse=` et `SystemKeepFree=`, et la limitation de débit. Pas un journal en mémoire, qui disparaît justement après l'incident qu'on voudrait comprendre.
- `LogRateLimitIntervalSec=` et `LogRateLimitBurst=` se règlent unité par unité (systemd 240 et plus) : les règles générales pour tout le monde, une exception pour ce qui doit tout garder. Dans une unité, 0 ne désactive pas la limite : donner une valeur explicite.
- Pour les journaux qui comptent (audit, comptabilité, sécurité), une copie hors du serveur (`systemd-journal-upload`, syslog distant) : un redémarrage ou un disque perdu ne les emporte pas.
